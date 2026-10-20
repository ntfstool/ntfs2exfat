import Foundation

public enum Stage: String, Codable, Sendable { case pending, copied, verified, failed, skipped }
public enum EntryKind: String, Codable, Sendable { case file, dir, symlink }

/// 清单里的一个条目。清单是整个迁移的"事实来源"：断点续传、失败报告、用户确认依据都来自它。
public struct ManifestEntry: Codable, Equatable, Sendable {
    public var path: String            // 相对源盘根的路径，"/" 分隔
    public var kind: EntryKind
    public var size: Int64
    public var mtime: Double           // 秒（1970 起）
    public var sha256: String?         // 源文件内容哈希（备份时边拷边算）
    public var linkTarget: String?
    public var backup: Stage
    public var restore: Stage
    public var backupPath: String?     // 备份目录里的实际相对路径（备份卷可能不区分大小写，撞名时会改名）
    public var restoredPath: String?   // 拷回 exFAT 时若被改名，记录新路径
    public var error: String?

    /// AppleDouble 附属文件（"._*"）：macOS 在不支持扩展属性的卷上用它保存 Finder 标签、隔离标记等。
    /// 写到 exFAT 后，系统会把它合并成原文件的扩展属性，无法再按路径读回，所以不能做逐字节校验。
    public var isAppleDouble: Bool { kind == .file && (path as NSString).lastPathComponent.hasPrefix("._") }

    public init(path: String, kind: EntryKind, size: Int64 = 0, mtime: Double = 0, sha256: String? = nil,
                linkTarget: String? = nil, backup: Stage = .pending, restore: Stage = .pending,
                backupPath: String? = nil, restoredPath: String? = nil, error: String? = nil) {
        self.path = path; self.kind = kind; self.size = size; self.mtime = mtime; self.sha256 = sha256
        self.linkTarget = linkTarget; self.backup = backup; self.restore = restore
        self.backupPath = backupPath; self.restoredPath = restoredPath; self.error = error
    }
}

/// 追加式 JSONL 清单：每次更新追加一行，加载时"后写覆盖先写"。进程被杀也不会损坏已写入的行。
public actor Manifest {
    public private(set) var entries: [String: ManifestEntry] = [:]
    public private(set) var order: [String] = []
    private let url: URL
    private var handle: FileHandle?
    private var buffer = Data()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                // 最后一行可能因崩溃只写了一半，直接忽略损坏行
                guard let e = try? decoder.decode(ManifestEntry.self, from: Data(line)) else { continue }
                if entries[e.path] == nil { order.append(e.path) }
                entries[e.path] = e
            }
        } else {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    public var count: Int { entries.count }
    public func entry(_ path: String) -> ManifestEntry? { entries[path] }
    public var all: [ManifestEntry] { order.compactMap { entries[$0] } }

    public func upsert(_ e: ManifestEntry) {
        if entries[e.path] == nil { order.append(e.path) }
        entries[e.path] = e
        if let line = try? encoder.encode(e) { buffer.append(line); buffer.append(0x0A) }
        if buffer.count > 256 * 1024 { flush() }
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        handle?.write(buffer); buffer.removeAll(keepingCapacity: true)
        try? handle?.synchronize()
    }

    /// 把"每个条目的最终状态"重写成一份紧凑清单（用于阶段结束）。
    public func compact() {
        flush()
        let tmp = url.appendingPathExtension("tmp")
        var out = Data()
        for e in all { if let l = try? encoder.encode(e) { out.append(l); out.append(0x0A) } }
        guard (try? out.write(to: tmp, options: .atomic)) != nil else { return }
        try? handle?.close()
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    public func close() { flush(); try? handle?.close(); handle = nil }

    // 统计（给界面和确认条件用）
    public struct Summary: Sendable, Equatable {
        public var files = 0, dirs = 0, symlinks = 0
        public var bytes: Int64 = 0
        public var backupVerified = 0, backupFailed = 0, backupPending = 0
        public var restoreVerified = 0, restoreFailed = 0, restorePending = 0
        public var skipped = 0
        public var sidecars = 0          // ._* 附属文件数（拷回后由 macOS 合并为扩展属性，不做字节校验）
        public var metadataSkipped = 0   // 没能写回新盘的 ._* 附属信息（孤立的或新盘不接受的）；原样留在备份里，不算失败
        public init() {}
    }

    public func summary() -> Summary {
        var s = Summary()
        for e in entries.values {
            switch e.kind {
            case .dir: s.dirs += 1; continue
            case .symlink: s.symlinks += 1; s.skipped += 1; continue
            case .file: s.files += 1; s.bytes += e.size; if e.isAppleDouble { s.sidecars += 1 }
            }
            if e.backup == .skipped { s.skipped += 1; continue }
            switch e.backup { case .verified: s.backupVerified += 1; case .failed: s.backupFailed += 1; default: s.backupPending += 1 }
            switch e.restore {
            case .verified: s.restoreVerified += 1
            case .failed: s.restoreFailed += 1
            case .skipped: s.metadataSkipped += 1
            default: s.restorePending += 1
            }
        }
        return s
    }
}
