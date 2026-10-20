import Foundation

public struct JobProgress: Sendable, Equatable {
    public var phase: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var filesDone: Int
    public var filesTotal: Int
    public var currentPath: String
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : (filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 1) }
}

/// 进度汇总，最多每 100ms 回调一次。
actor JobProgressBox {
    private var p: JobProgress
    private let report: @Sendable (JobProgress) -> Void
    private var last = Date.distantPast
    init(phase: String, bytesTotal: Int64, filesTotal: Int, report: @escaping @Sendable (JobProgress) -> Void) {
        p = JobProgress(phase: phase, bytesDone: 0, bytesTotal: bytesTotal, filesDone: 0, filesTotal: filesTotal, currentPath: "")
        self.report = report
    }
    func add(bytes: Int64) { p.bytesDone += bytes; emit() }
    func file(done path: String) { p.filesDone += 1; p.currentPath = path; emit(force: p.filesDone == p.filesTotal) }
    func current(_ path: String) { p.currentPath = path }
    private func emit(force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(last) > 0.1 { last = now; report(p) }
    }
    func finish() { report(p) }
}

public struct PhaseResult: Sendable, Equatable {
    public var done = 0, failed = 0, skipped = 0
    public var cancelled = false
}

/// 清单驱动的拷贝与校验引擎。每个阶段都可中断、可重入：重启后读清单，跳过已完成的条目。
public final class CopyEngine: @unchecked Sendable {
    public let manifest: Manifest
    public let concurrency: Int
    private let lock = NSLock()
    private var cancelled = false

    public init(manifest: Manifest, concurrency: Int = 4) {
        self.manifest = manifest; self.concurrency = max(1, concurrency)
    }

    /// 备份目录里的实际路径。
    static func bpath(_ e: ManifestEntry) -> String { e.backupPath ?? e.path }
    static func rpath(_ e: ManifestEntry) -> String { e.restoredPath ?? e.path }

    /// 为备份规划路径：备份卷常常不区分大小写（APFS、exFAT），NTFS 里仅大小写不同的文件会互相覆盖，
    /// 所以和拷回 exFAT 时一样做改名去重。结果记入清单，可重复调用（结果一致）。
    public func planBackupPaths() async {
        var used: [String: Set<String>] = [:]
        for e in await manifest.all where e.kind != .symlink {
            let target = ExFATName.restorePath(for: e.path, used: &used)
            let newValue: String? = target == e.path ? nil : target
            if e.backupPath != newValue { var u = e; u.backupPath = newValue; await manifest.upsert(u) }
        }
    }

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func reset() { lock.lock(); cancelled = false; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    // MARK: 阶段 1：备份（源盘 → 备份目录），边拷边算源内容哈希
    public func backup(sourceRoot: String, dataRoot: String, progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> PhaseResult {
        await planBackupPaths()
        let all = await manifest.all
        // 目录先建好
        for e in all where e.kind == .dir && e.backup != .verified {
            try FileManager.default.createDirectory(atPath: dataRoot + "/" + Self.bpath(e), withIntermediateDirectories: true)
            var d = e; d.backup = .verified; await manifest.upsert(d)
        }
        let todo = all.filter { $0.kind == .file && ($0.backup == .pending || $0.backup == .failed) }
        let box = JobProgressBox(phase: "backup", bytesTotal: todo.reduce(0) { $0 + $1.size }, filesTotal: todo.count, report: progress)
        return try await runPool(todo, box: box) { e in
            do {
                let r = try FileCopier.copy(from: sourceRoot + "/" + e.path, to: dataRoot + "/" + Self.bpath(e), mtime: e.mtime,
                                            cancel: { self.isCancelled }, progress: { n in Task { await box.add(bytes: n) } })
                var u = e; u.sha256 = r.sha256; u.size = r.bytes; u.backup = .copied; u.error = nil
                await self.manifest.upsert(u)
                return .done
            } catch is CancellationError { throw CancellationError() }
            catch CopyError.diskFull { var u = e; u.backup = .failed; u.error = "disk full"; await self.manifest.upsert(u); throw CopyError.diskFull }
            catch { var u = e; u.backup = .failed; u.error = "\(error)"; await self.manifest.upsert(u); return .failed }
        }
    }

    // MARK: 阶段 2：校验备份（重新读取备份文件，与源哈希比对）
    public func verifyBackup(dataRoot: String, progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> PhaseResult {
        let todo = await manifest.all.filter { $0.kind == .file && $0.backup == .copied }
        let box = JobProgressBox(phase: "verifyBackup", bytesTotal: todo.reduce(0) { $0 + $1.size }, filesTotal: todo.count, report: progress)
        return try await runPool(todo, box: box) { e in
            do {
                let r = try FileCopier.hash(path: dataRoot + "/" + Self.bpath(e), cancel: { self.isCancelled }, progress: { n in Task { await box.add(bytes: n) } })
                var u = e
                if r.sha256 == e.sha256, r.bytes == e.size { u.backup = .verified; u.error = nil; await self.manifest.upsert(u); return .done }
                u.backup = .failed; u.error = "backup verify: \(CopyError.hashMismatch(expected: e.sha256 ?? "", actual: r.sha256))"
                await self.manifest.upsert(u); return .failed
            } catch is CancellationError { throw CancellationError() }
            catch { var u = e; u.backup = .failed; u.error = "backup verify: \(error)"; await self.manifest.upsert(u); return .failed }
        }
    }

    /// 格式化前的快速复查：所有备份文件仍然存在且大小一致（不重新计算哈希，很快）。返回有问题的路径。
    public func quickCheckBackup(dataRoot: String) async -> [String] {
        var bad: [String] = []
        for e in await manifest.all where e.kind == .file && e.backup != .skipped {
            var st = stat()
            if stat(dataRoot + "/" + Self.bpath(e), &st) != 0 || Int64(st.st_size) != e.size { bad.append(e.path) }
        }
        return bad
    }

    // MARK: 阶段 3：为拷回 exFAT 规划路径（不兼容名字自动改名并记录）
    public func planRestorePaths() async -> Int {
        var used: [String: Set<String>] = [:]
        var renamed = 0
        for e in await manifest.all where e.kind != .symlink {
            let target = ExFATName.restorePath(for: e.path, used: &used)
            if target != e.path { var u = e; u.restoredPath = target; await manifest.upsert(u); renamed += 1 }
        }
        return renamed
    }

    // MARK: 阶段 4：拷回（备份目录 → 新 exFAT 盘），同时核对备份哈希
    /// 分两轮：先拷普通文件，再把 "._*" 附属信息写回到对应文件上。
    /// 不能把 "._X" 当普通文件直接写到 exFAT：macOS 会把这个名字当成 X 的扩展属性处理，
    /// X 不存在或名字含非 ASCII 字符时 rename 直接报 ENOENT（2026-10 真实用户在这里卡住）。
    public func restore(dataRoot: String, targetRoot: String, progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> PhaseResult {
        let all = await manifest.all
        for e in all where e.kind == .dir && e.restore != .verified {
            try FileManager.default.createDirectory(atPath: targetRoot + "/" + (e.restoredPath ?? e.path), withIntermediateDirectories: true)
            var d = e; d.restore = .verified; await manifest.upsert(d)
        }
        let todo = all.filter { $0.kind == .file && !$0.isAppleDouble && $0.backup == .verified && ($0.restore == .pending || $0.restore == .failed) }
        let box = JobProgressBox(phase: "restore", bytesTotal: todo.reduce(0) { $0 + $1.size }, filesTotal: todo.count, report: progress)
        var result = try await runPool(todo, box: box) { e in
            let dst = targetRoot + "/" + (e.restoredPath ?? e.path)
            do {
                let r = try FileCopier.copy(from: dataRoot + "/" + Self.bpath(e), to: dst, mtime: e.mtime,
                                            cancel: { self.isCancelled }, progress: { n in Task { await box.add(bytes: n) } })
                var u = e
                if r.sha256 != e.sha256 {      // 备份文件在这期间被改动或损坏：不能把它当成好数据
                    try? FileManager.default.removeItem(atPath: dst)
                    u.restore = .failed; u.error = "backup changed before restore: \(CopyError.hashMismatch(expected: e.sha256 ?? "", actual: r.sha256))"
                    await self.manifest.upsert(u); return .failed
                }
                u.restore = .copied; u.error = nil; await self.manifest.upsert(u); return .done
            } catch is CancellationError { throw CancellationError() }
            catch CopyError.diskFull { var u = e; u.restore = .failed; u.error = "target disk full"; await self.manifest.upsert(u); throw CopyError.diskFull }
            catch { var u = e; u.restore = .failed; u.error = "restore: \(error)"; await self.manifest.upsert(u); return .failed }
        }
        if result.cancelled { await manifest.flush(); return result }
        let meta = await restoreSidecars(dataRoot: dataRoot, targetRoot: targetRoot)
        result.done += meta
        // 目录修改时间（深层先改，避免改完子项又被刷新）
        for e in all.filter({ $0.kind == .dir }).sorted(by: { $0.path.count > $1.path.count }) {
            var ts = [timespec(tv_sec: Int(e.mtime), tv_nsec: 0), timespec(tv_sec: Int(e.mtime), tv_nsec: 0)]
            utimensat(AT_FDCWD, targetRoot + "/" + (e.restoredPath ?? e.path), &ts, 0)
        }
        await manifest.flush()
        return result
    }

    /// 把 "._X" 里的扩展属性/资源分叉解包到新盘上的 X（copyfile COPYFILE_UNPACK）。
    /// 这些是 Finder 标签、隔离标记之类的附属信息，不是文件内容：写不回去时标记 skipped（写进报告），不算失败；
    /// 原始 "._X" 一直保留在备份里。返回成功写回的个数。
    func restoreSidecars(dataRoot: String, targetRoot: String) async -> Int {
        let all = await manifest.all
        var byPath: [String: ManifestEntry] = [:]
        for e in all { byPath[e.path] = e }
        var applied = 0
        for e in all where e.isAppleDouble && e.backup == .verified && e.restore != .verified && e.restore != .skipped {
            let name = (e.path as NSString).lastPathComponent
            let dir = (e.path as NSString).deletingLastPathComponent
            let ownerPath = dir.isEmpty ? String(name.dropFirst(2)) : dir + "/" + String(name.dropFirst(2))
            var u = e
            guard let owner = byPath[ownerPath], owner.kind != .symlink,
                  owner.kind == .dir || owner.restore == .copied || owner.restore == .verified else {
                u.restore = .skipped; u.error = "metadata: no matching file on the drive (kept in backup)"
                await manifest.upsert(u); continue
            }
            let dst = targetRoot + "/" + (owner.restoredPath ?? owner.path)
            let rc = copyfile(dataRoot + "/" + Self.bpath(e), dst, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_XATTR))
            if rc == 0 { u.restore = .verified; u.error = nil; applied += 1 }
            else { u.restore = .skipped; u.error = "metadata: not applied (\(String(cString: strerror(errno)))); kept in backup" }
            await manifest.upsert(u)
        }
        return applied
    }

    /// 拷回还需要的字节数（只算还没拷回成功的普通文件）。续传时盘上已有一部分，不能按总量算。
    public func remainingRestoreBytes() async -> Int64 {
        await manifest.all.filter { $0.kind == .file && !$0.isAppleDouble && $0.backup == .verified && ($0.restore == .pending || $0.restore == .failed) }
            .reduce(0) { $0 + $1.size }
    }

    // MARK: 阶段 5：校验拷回（重新读取新盘上的文件）
    public func verifyRestore(targetRoot: String, progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> PhaseResult {
        var todo = await manifest.all.filter { $0.kind == .file && $0.restore == .copied }
        // AppleDouble 附属文件已成功写入，但会被系统合并成扩展属性，无法按路径读回：只确认写入成功。
        for e in todo where e.isAppleDouble { var u = e; u.restore = .verified; u.error = nil; await manifest.upsert(u) }
        todo.removeAll { $0.isAppleDouble }
        let box = JobProgressBox(phase: "verifyRestore", bytesTotal: todo.reduce(0) { $0 + $1.size }, filesTotal: todo.count, report: progress)
        return try await runPool(todo, box: box) { e in
            let path = targetRoot + "/" + (e.restoredPath ?? e.path)
            do {
                let r = try FileCopier.hash(path: path, cancel: { self.isCancelled }, progress: { n in Task { await box.add(bytes: n) } })
                var u = e
                if r.sha256 == e.sha256, r.bytes == e.size { u.restore = .verified; u.error = nil; await self.manifest.upsert(u); return .done }
                u.restore = .failed; u.error = "restore verify: \(CopyError.hashMismatch(expected: e.sha256 ?? "", actual: r.sha256))"
                await self.manifest.upsert(u); return .failed
            } catch is CancellationError { throw CancellationError() }
            catch { var u = e; u.restore = .failed; u.error = "restore verify: \(error)"; await self.manifest.upsert(u); return .failed }
        }
    }

    // MARK: 线程池：最多 concurrency 个文件同时处理
    enum Outcome { case done, failed }

    private func runPool(_ items: [ManifestEntry], box: JobProgressBox, work: @escaping @Sendable (ManifestEntry) async throws -> Outcome) async throws -> PhaseResult {
        var result = PhaseResult()
        do {
            try await withThrowingTaskGroup(of: (Outcome, String).self) { group in
                var it = items.makeIterator()
                var inflight = 0
                func launch() {
                    guard let e = it.next() else { return }
                    inflight += 1
                    group.addTask { (try await work(e), e.path) }
                }
                for _ in 0..<concurrency { launch() }
                while inflight > 0 {
                    guard let (outcome, path) = try await group.next() else { break }
                    inflight -= 1
                    if outcome == .done { result.done += 1 } else { result.failed += 1 }
                    await box.file(done: path)
                    if isCancelled { throw CancellationError() }
                    launch()
                }
            }
        } catch is CancellationError {
            result.cancelled = true
        }
        await box.finish()
        await manifest.flush()
        return result
    }
}
