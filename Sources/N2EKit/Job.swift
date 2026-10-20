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
    public var partitionSize: Int64?     // 分区字节数，用来认盘（旧任务没有这个字段）
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
    case sourceModified([String])
    case sourceShared(String)
    case diskChanged(String)
    case confirmationMismatch
    case targetNotMounted
    case targetTooSmall(needed: Int64, available: Int64)
    case restoreIncomplete(failed: Int)

    /// 不含文件名的简短错误类别，用于匿名上报。
    public var code: String {
        switch self {
        case .notNTFS: return "notNTFS"; case .systemOrInternalDisk: return "internalDisk"; case .notMounted: return "notMounted"
        case .backupOnSameDisk: return "sameDisk"; case .notEnoughBackupSpace: return "backupSpace"
        case .wrongPhase(let e, let a): return "wrongPhase:\(e)>\(a)"
        case .backupNotVerified: return "backupNotVerified"; case .backupModified: return "backupModified"
        case .sourceModified: return "sourceModified"; case .sourceShared: return "sourceShared"; case .diskChanged(let why): return "diskChanged:\(why)"
        case .confirmationMismatch: return "nameMismatch"; case .targetNotMounted: return "targetNotMounted"
        case .targetTooSmall: return "targetTooSmall"; case .restoreIncomplete: return "restoreIncomplete"
        }
    }

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
        case .sourceModified(let p): return "files on the drive changed after the backup (\(p.count) files, e.g. \(p.first ?? "")); back up again before formatting"
        case .sourceShared(let why): return "the drive must be used by NTFS2exFAT alone and read-only: \(why)"
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
        // 必须先 prepareSource：别的驱动同时挂着这块盘时，系统挂载点可能是旧缓存，扫描会漏掉文件
        if let p = DiskUtil.exclusivityProblem(info.identifier) { throw MigrationError.sourceShared(p) }
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
                                                    volumeUUID: info.volumeUUID, diskUUID: info.diskUUID, totalSize: info.totalSize, mountPoint: mount,
                                                    partitionSize: info.partitionSize),
                             sourceRoot: mount, backupRoot: backupRoot, targetRoot: nil, newLabel: nil, renamedOnRestore: 0, note: nil, eraseStarted: nil, targetIdentifier: nil)
        let job = MigrationJob(state: state, directory: dir, manifest: manifest, concurrency: concurrency)
        try job.save()
        return job
    }

    /// 开始之前调用：卸掉这块盘的所有挂载（包括 NTFSTool 等其它驱动的读写挂载），再以只读方式重新挂载。
    /// 需要卸载别的驱动的挂载时可能要管理员权限（elevate）。返回新的挂载点。
    public static func prepareSource(_ id: String, elevate: DiskUtil.Elevator? = nil) async throws -> String {
        try await DiskUtil.remountExclusiveReadOnly(id, elevate: elevate)
    }

    /// 读源盘之前确认：仍是独占、只读挂载；挂载点变了（拔插过）就更新。
    func ensureSourceReady() throws {
        let info = try DiskUtil.info(state.source.identifier)
        guard let mount = info.mountPoint else { throw MigrationError.notMounted }
        if info.volumeUUID != state.source.volumeUUID || info.diskUUID != state.source.diskUUID { throw MigrationError.diskChanged("volume identity differs") }
        if let p = DiskUtil.exclusivityProblem(state.source.identifier) { throw MigrationError.sourceShared(p) }
        if mount != state.sourceRoot { state.sourceRoot = mount; try save() }
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
        try ensureSourceReady()
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
        try ensureSourceReady()
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
            // 用分区字节数认盘：statfs 报的容量会随挂载驱动变化（例如被 NTFSTool 以读写方式重新挂载），会误判成"换了盘"
            if let ps = state.source.partitionSize { if cur.partitionSize != ps { problems.append(.diskChanged("size differs")) } }
            else if cur.totalSize != state.source.totalSize && cur.partitionSize != state.source.totalSize { problems.append(.diskChanged("size differs")) }
            if cur.isInternal { problems.append(.systemOrInternalDisk) }
            if let p = DiskUtil.exclusivityProblem(state.source.identifier) { problems.append(.sourceShared(p)) }
            // 备份之后盘可能被以读写方式重新挂载并被改动：改动过的文件不在备份里，格式化会丢掉它们
            if let mount = cur.mountPoint {
                let changed = await sourceChanges(root: mount)
                if !changed.isEmpty { problems.append(.sourceModified(changed)) }
            }
        } else { problems.append(.diskChanged("the disk is no longer connected")) }
        return problems
    }

    /// 快速核对源盘：备份过的每个文件仍在、大小和修改时间不变；也找出备份后新增的顶层条目。只用 stat，很快。
    func sourceChanges(root: String) async -> [String] {
        var out: [String] = []
        let all = await manifest.all
        for e in all where e.kind == .file && e.backup != .skipped {
            var st = stat()
            if lstat(root + "/" + e.path, &st) != 0 { out.append(e.path); continue }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if Int64(st.st_size) != e.size || abs(mtime - e.mtime) > 2 { out.append(e.path) }
            if out.count >= 50 { return out }
        }
        let known = Set(all.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
        let skippedTop = Set(ScanOptions().skippedNames)
        for name in (try? listDirectory(root)) ?? [] where !known.contains(name) && !skippedTop.contains(name) && !name.hasPrefix(".n2etmp") {
            // 列得出但 lstat 失败的是残缺目录项（扫描时已记为"读不出来"并由用户确认），不算新增
            var st = stat()
            guard lstat(root + "/" + name, &st) == 0 else { continue }
            out.append(name)
            if out.count >= 50 { break }
        }
        return out
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

    /// 重新定位格式化后的新卷：优先按记录的标识符，其次按"同一块物理盘上的 exFAT 卷"。找到则更新挂载点。
    func refreshTarget() async throws -> Bool {
        for _ in 0..<20 {
            var v: DiskUtil.Info?
            if let id = state.targetIdentifier, let i = try? DiskUtil.info(id), i.fileSystem == "exfat", i.mountPoint != nil { v = i }
            if v == nil { v = (try? DiskUtil.externalVolumes())?.first(where: { $0.wholeDisk == state.source.wholeDisk && $0.fileSystem == "exfat" && $0.mountPoint != nil }) }
            if let v, let mount = v.mountPoint, DiskUtil.volumeInfo(forPath: mount)?.identifier == v.identifier {
                if state.targetRoot != mount || state.targetIdentifier != v.identifier { state.targetRoot = mount; state.targetIdentifier = v.identifier; try save() }
                return true
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// 拷回没有全部成功的文件（给界面列出来）。
    public func failedRestores(limit: Int = 200) async -> [ManifestEntry] {
        Array(await manifest.all.filter { $0.kind == .file && $0.restore == .failed }.prefix(limit))
    }

    /// 没写回新盘的附属信息（"._*"），写进报告。
    public func skippedMetadata() async -> [ManifestEntry] {
        await manifest.all.filter { $0.kind == .file && $0.isAppleDouble && $0.restore == .skipped }
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
        // 续传时盘可能被拔插过，挂载点会变（"/Volumes/X 1"）。每次都重新确认目标是这块物理盘上已装载的 exFAT 卷，
        // 绝不往一个只是路径相同的目录里写。
        guard try await refreshTarget(), let target = state.targetRoot else { throw MigrationError.targetNotMounted }
        if let free = DiskUtil.freeSpace(forPath: target) {
            // 只算还没拷回的部分（续传时盘上已经有一部分了）；exFAT 簇会浪费一些空间，按 2% 估算
            let needed = Int64(Double(await engine.remainingRestoreBytes()) * 1.02)
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
        let s = await manifest.summary()
        if s.restoreFailed > 0 || (state.phase == .formatted && s.restorePending > 0) {
            throw MigrationError.restoreIncomplete(failed: s.restoreFailed + s.restorePending)
        }
        try require([.restored, .completed])
        var lines = ["NTFS2exFAT report", "Job: \(state.id)", "Source: \(state.source.volumeName) (\(state.source.identifier))",
                     "Files: \(s.files)  Folders: \(s.dirs)  Bytes: \(s.bytes)", "Backup verified: \(s.backupVerified)/\(s.files)",
                     "Restore verified: \(s.restoreVerified)/\(s.files - s.metadataSkipped)", "Renamed for exFAT: \(state.renamedOnRestore)",
                     "Skipped (links etc.): \(s.skipped)",
                     "Metadata sidecars (._*): \(s.sidecars) (applied as extended attributes; not byte-verified)",
                     "Metadata not applied: \(s.metadataSkipped) (Finder tags etc. only, file contents are fine; originals kept in the backup)",
                     "New volume: \(state.newLabel ?? "?") at \(state.targetRoot ?? "?")"]
        for e in await manifest.all where e.restoredPath != nil { lines.append("renamed: \(e.path) -> \(e.restoredPath!)") }
        for e in await skippedMetadata() { lines.append("metadata not applied: \(e.path) — \(e.error ?? "")") }
        if let t = state.targetRoot { removeTempLeftovers(root: t) }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try advance(to: .completed)
        return text
    }

    /// 清理中断后残留在新盘上的临时文件（.n2etmp-*）。
    func removeTempLeftovers(root: String) {
        guard let it = FileManager.default.enumerator(atPath: root) else { return }
        for case let rel as String in it where (rel as NSString).lastPathComponent.hasPrefix(".n2etmp") { unlink(root + "/" + rel) }
    }

    /// 备份是否可以删除：只有任务完成且全部校验通过才返回 true。删除由用户决定，库不会自动删。
    public func canDeleteBackup() async -> Bool {
        let s = await manifest.summary()
        return state.phase == .completed && s.restoreFailed == 0 && s.restorePending == 0
    }
}
