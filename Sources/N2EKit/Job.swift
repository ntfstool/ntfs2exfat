import Foundation

public enum Phase: String, Codable, Sendable, CaseIterable {
    case created, scanned, backedUp, backupVerified, formatted, restored, completed
}

public struct SourceSnapshot: Codable, Equatable, Sendable {
    public var identifier: String
    public var wholeDisk: String
    public var volumeName: String
    public var volumeUUID: String?
    public var diskUUID: String?
    public var totalSize: Int64
    public var mountPoint: String
}

/// 一次迁移任务的持久状态（job.json）。
public struct JobState: Codable, Sendable {
    public var id: String
    public var createdAt: Date
    public var phase: Phase
    public var source: SourceSnapshot
    public var sourceRoot: String
    public var backupRoot: String          // 备份根目录（任务目录在其下）
    public var targetRoot: String?         // 格式化后新 exFAT 卷的挂载点
    public var newLabel: String?
    public var renamedOnRestore: Int
    public var note: String?
    public var eraseStarted: Bool?         // 先落盘再格式化：崩溃/断电后据此判断磁盘是否可能已被擦除
    public var targetIdentifier: String?   // 格式化后新卷的标识符（整盘格式化会从 disk4 变成 disk4s1 之类）
}

public enum MigrationError: Error, CustomStringConvertible, Equatable {
    case notNTFS(String), systemOrInternalDisk, notMounted
    case backupOnSameDisk, notEnoughBackupSpace(needed: Int64, available: Int64)
    case wrongPhase(expected: String, actual: String)
    case backupNotVerified(failed: Int, pending: Int)
    case backupModified([String])
    case diskChanged(String)
    case confirmationMismatch
    case targetNotMounted
    case targetTooSmall(needed: Int64, available: Int64)
    case restoreIncomplete(failed: Int)

    public var description: String {
        switch self {
        case .notNTFS(let fs): return "source volume is not NTFS (found: \(fs.isEmpty ? "unknown" : fs))"
        case .systemOrInternalDisk: return "refusing to touch an internal or system disk"
        case .notMounted: return "source volume is not mounted"
        case .backupOnSameDisk: return "the backup location is on the same physical disk that would be erased"
        case .notEnoughBackupSpace(let n, let a): return "not enough space for the backup (need \(n) bytes, have \(a))"
        case .wrongPhase(let e, let a): return "this step needs phase '\(e)', but the job is at '\(a)'"
        case .backupNotVerified(let f, let p): return "backup is not fully verified (\(f) failed, \(p) pending)"
        case .backupModified(let p): return "backup files changed or went missing since verification (\(p.count) files, e.g. \(p.first ?? ""))"
        case .diskChanged(let why): return "the disk is not the one the backup was made from (\(why))"
        case .confirmationMismatch: return "the typed volume name does not match"
        case .targetNotMounted: return "the new exFAT volume did not mount"
        case .targetTooSmall(let n, let a): return "new volume is too small (need about \(n) bytes, have \(a))"
        case .restoreIncomplete(let f): return "restore finished with \(f) failed files"
        }
    }
}

/// 迁移任务编排：把 扫描 → 备份 → 校验 → 格式化 → 拷回 → 校验 串成有前置条件检查的流程。
/// 危险步骤（erase）的所有前置条件都在这里强制检查，界面只负责收集用户确认。
public final class MigrationJob: @unchecked Sendable {
    public private(set) var state: JobState
    public let directory: URL
    public let manifest: Manifest
    public let engine: CopyEngine

    public var dataRoot: String { directory.appendingPathComponent("data").path }
    var stateURL: URL { directory.appendingPathComponent("job.json") }

    init(state: JobState, directory: URL, manifest: Manifest, concurrency: Int) {
        self.state = state; self.directory = directory; self.manifest = manifest
        self.engine = CopyEngine(manifest: manifest, concurrency: concurrency)
    }

    // MARK: 创建 / 恢复

    /// 创建任务。会做全部"开始前"检查：NTFS、外置、已装载、备份不在同一块盘、备份空间足够。
    public static func create(sourceVolume id: String, backupRoot: String, concurrency: Int = 4) throws -> MigrationJob {
        let info = try DiskUtil.info(id)
        guard info.fileSystem.contains("ntfs") else { throw MigrationError.notNTFS(info.fileSystem) }
        guard !info.isInternal else { throw MigrationError.systemOrInternalDisk }
        guard let mount = info.mountPoint else { throw MigrationError.notMounted }
        // 备份位置：不能在即将被擦除的那块物理盘上；空间必须足够（已用空间 ×1.05 + 64MB）
        if let b = DiskUtil.volumeInfo(forPath: backupRoot), b.wholeDisk == info.wholeDisk { throw MigrationError.backupOnSameDisk }
        let used = max(0, info.totalSize - (info.freeSpace ?? 0))
        let needed = Int64(Double(used) * 1.05) + 64 * 1024 * 1024
        if let free = DiskUtil.freeSpace(forPath: backupRoot), free < needed { throw MigrationError.notEnoughBackupSpace(needed: needed, available: free) }
        let jobID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "") + "-" + UUID().uuidString.prefix(6).lowercased()
        let dir = URL(fileURLWithPath: backupRoot).appendingPathComponent("NTFS2exFAT-\(jobID)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("data"), withIntermediateDirectories: true)
        let manifest = try Manifest(url: dir.appendingPathComponent("manifest.jsonl"))
        let state = JobState(id: jobID, createdAt: Date(), phase: .created,
                             source: SourceSnapshot(identifier: info.identifier, wholeDisk: info.wholeDisk, volumeName: info.volumeName,
                                                    volumeUUID: info.volumeUUID, diskUUID: info.diskUUID, totalSize: info.totalSize, mountPoint: mount),
                             sourceRoot: mount, backupRoot: backupRoot, targetRoot: nil, newLabel: nil, renamedOnRestore: 0, note: nil, eraseStarted: nil, targetIdentifier: nil)
        let job = MigrationJob(state: state, directory: dir, manifest: manifest, concurrency: concurrency)
        try job.save()
        return job
    }

    /// 从任务目录恢复（程序重启 / 断点续传）。
    public static func resume(directory: URL, concurrency: Int = 4) throws -> MigrationJob {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let state = try dec.decode(JobState.self, from: Data(contentsOf: directory.appendingPathComponent("job.json")))
        let manifest = try Manifest(url: directory.appendingPathComponent("manifest.jsonl"))
        return MigrationJob(state: state, directory: directory, manifest: manifest, concurrency: concurrency)
    }

    func save() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: stateURL, options: .atomic)
    }

    func advance(to phase: Phase) throws { state.phase = phase; try save() }

    private func require(_ phases: [Phase]) throws {
        guard phases.contains(state.phase) else { throw MigrationError.wrongPhase(expected: phases.map(\.rawValue).joined(separator: "|"), actual: state.phase.rawValue) }
    }

    // MARK: 步骤

    public func scan(options: ScanOptions = .init()) async throws -> ScanReport {
        try require([.created, .scanned])
        var report = try await Scanner.scan(root: state.sourceRoot, options: options, into: manifest, cancel: { self.engine.isCancelled })
        // 对账：卷的已用空间减去我们看到的文件，剩余应只是 NTFS 元数据（$MFT、日志、簇内碎片）。
        if let info = try? DiskUtil.info(state.source.identifier), let free = info.freeSpace {
            let used = max(0, info.totalSize - free)
            let overhead = Int64(256 * 1024 * 1024) + Int64(report.files + report.dirs) * 2048 + Int64(Double(used) * 0.03)
            report.usedBytes = used
            report.unexplainedBytes = used - report.totalBytes
            report.possibleHiddenData = report.unexplainedBytes > overhead
        }
        try advance(to: .scanned)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(report).write(to: directory.appendingPathComponent("scan.json"), options: .atomic)
        return report
    }

    public func backup(progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> PhaseResult {
        try require([.scanned, .created])
        let r = try await engine.backup(sourceRoot: state.sourceRoot, dataRoot: dataRoot, progress: progress)
        if !r.cancelled { try advance(to: .backedUp) }
        return r
    }

    /// 校验备份。全部通过时进入 backupVerified——这是"允许格式化"的唯一入口条件。
    public func verifyBackup(progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> PhaseResult {
        try require([.backedUp, .backupVerified])
        let r = try await engine.verifyBackup(dataRoot: dataRoot, progress: progress)
        await manifest.compact()
        let s = await manifest.summary()
        if !r.cancelled && s.backupFailed == 0 && s.backupPending == 0 { try advance(to: .backupVerified) }
        return r
    }

    public func summary() async -> Manifest.Summary { await manifest.summary() }

    /// 格式化前必须满足的全部条件。界面应在显示"格式化"按钮之前先调用它。
    public func eraseReadiness() async -> [MigrationError] {
        var problems: [MigrationError] = []
        if state.phase != .backupVerified { problems.append(.wrongPhase(expected: Phase.backupVerified.rawValue, actual: state.phase.rawValue)) }
        let s = await manifest.summary()
        if s.backupFailed > 0 || s.backupPending > 0 { problems.append(.backupNotVerified(failed: s.backupFailed, pending: s.backupPending)) }
        let bad = await engine.quickCheckBackup(dataRoot: dataRoot)
        if !bad.isEmpty { problems.append(.backupModified(bad)) }
        if let cur = try? DiskUtil.info(state.source.identifier) {
            if cur.volumeUUID != state.source.volumeUUID || cur.diskUUID != state.source.diskUUID { problems.append(.diskChanged("volume identity differs")) }
            if cur.totalSize != state.source.totalSize { problems.append(.diskChanged("size differs")) }
            if cur.isInternal { problems.append(.systemOrInternalDisk) }
        } else { problems.append(.diskChanged("the disk is no longer connected")) }
        return problems
    }

    /// 格式化为 exFAT。用户必须输入与当前卷名完全一致的文字。成功后任务进入 formatted，并记录新卷挂载点。
    public func erase(confirmedName typed: String, newLabel: String? = nil, elevate: DiskUtil.Elevator? = nil) async throws {
        let problems = await eraseReadiness()
        if let first = problems.first { throw first }
        guard typed == state.source.volumeName else { throw MigrationError.confirmationMismatch }
        let label = DiskUtil.sanitizedLabel(newLabel ?? state.source.volumeName)
        state.eraseStarted = true; state.newLabel = label; try save()      // 先落盘，再动磁盘
        try await DiskUtil.eraseToExFAT(identifier: state.source.identifier, label: label, elevate: elevate)
        guard try await locateFormattedVolume() else { throw MigrationError.targetNotMounted }
    }

    /// 找到格式化后的新 exFAT 卷（同一块物理盘上、已装载的 exFAT）。整盘格式化后标识符会变，所以不能只看原标识符。
    @discardableResult
    func locateFormattedVolume() async throws -> Bool {
        for _ in 0..<40 {
            if let v = (try? DiskUtil.externalVolumes())?.first(where: { $0.wholeDisk == state.source.wholeDisk && $0.fileSystem == "exfat" && $0.mountPoint != nil }) {
                state.targetRoot = v.mountPoint; state.targetIdentifier = v.identifier
                try advance(to: .formatted)
                return true
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// 断点恢复：如果上次在格式化过程中被打断（崩溃、断电、关闭程序），检查磁盘是否已经变成 exFAT。
    /// 返回 true 表示已确认格式化完成并进入 formatted；false 表示磁盘仍是原样（可以重新格式化）。
    public func recoverInterruptedErase() async throws -> Bool {
        guard state.phase == .backupVerified, state.eraseStarted == true else { return state.phase == .formatted }
        return try await locateFormattedVolume()
    }

    /// 拷回。如果中断，重新调用即可续传。
    public func restore(progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> PhaseResult {
        if state.phase == .backupVerified { _ = try await recoverInterruptedErase() }
        try require([.formatted, .restored])
        guard let target = state.targetRoot else { throw MigrationError.targetNotMounted }
        let s = await manifest.summary()
        if let info = try? DiskUtil.info(mountPoint: target), let free = info.freeSpace {
            // exFAT 簇会浪费一些空间：按 128KB 簇估算
            let needed = Int64(Double(s.bytes) * 1.02)
            if free < needed { throw MigrationError.targetTooSmall(needed: needed, available: free) }
        }
        state.renamedOnRestore = await engine.planRestorePaths(); try save()
        var r = try await engine.restore(dataRoot: dataRoot, targetRoot: target, progress: progress)
        if r.cancelled { return r }
        let v = try await engine.verifyRestore(targetRoot: target, progress: progress)
        r.failed += v.failed; r.cancelled = v.cancelled
        await manifest.compact()
        let after = await manifest.summary()
        if !r.cancelled && after.restoreFailed == 0 && after.restorePending == 0 { try advance(to: .restored) }
        return r
    }

    /// 生成最终报告（report.json + report.txt），并把任务标记为完成。
    public func finish() async throws -> String {
        try require([.restored, .completed])
        let s = await manifest.summary()
        if s.restoreFailed > 0 { throw MigrationError.restoreIncomplete(failed: s.restoreFailed) }
        var lines = ["NTFS2exFAT report", "Job: \(state.id)", "Source: \(state.source.volumeName) (\(state.source.identifier))",
                     "Files: \(s.files)  Folders: \(s.dirs)  Bytes: \(s.bytes)", "Backup verified: \(s.backupVerified)/\(s.files)",
                     "Restore verified: \(s.restoreVerified)/\(s.files)", "Renamed for exFAT: \(state.renamedOnRestore)",
                     "Skipped (links etc.): \(s.skipped)",
                     "Metadata sidecars (._*): \(s.sidecars) (applied by macOS as extended attributes; not byte-verified)", "New volume: \(state.newLabel ?? "?") at \(state.targetRoot ?? "?")"]
        for e in await manifest.all where e.restoredPath != nil { lines.append("renamed: \(e.path) -> \(e.restoredPath!)") }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try advance(to: .completed)
        return text
    }

    /// 备份是否可以删除：只有任务完成且全部校验通过才返回 true。删除由用户决定，库不会自动删。
    public func canDeleteBackup() async -> Bool {
        let s = await manifest.summary()
        return state.phase == .completed && s.restoreFailed == 0 && s.restorePending == 0
    }
}
