import Foundation

public struct ScanOptions: Sendable {
    /// 默认跳过的系统/元数据目录：不属于用户数据，且常常无权限读取，macOS 会自动重建。
    public static let defaultSkippedNames: Set<String> = [
        "System Volume Information", "$RECYCLE.BIN", "$Recycle.Bin", "RECYCLER", "$WinREAgent",
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
    ]
    public var skippedNames: Set<String> = ScanOptions.defaultSkippedNames
    public init() {}
}

public struct ScanIssue: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case illegalCharacter, trailingDotOrSpace, tooLong, caseCollision, unreadable, unsupportedType, symlink }
    public var path: String
    public var kind: Kind
    public var detail: String?
}

public struct ScanReport: Codable, Equatable, Sendable {
    public var files = 0, dirs = 0, symlinks = 0
    public var totalBytes: Int64 = 0
    public var largestFile: Int64 = 0
    public var skipped: [String] = []
    public var issues: [ScanIssue] = []
    /// 对账：卷报告的已用空间 vs 我们看到的文件总量。差距过大说明可能有 macOS 读不到的数据。
    public var usedBytes: Int64 = 0
    public var unexplainedBytes: Int64 = 0
    public var possibleHiddenData = false
    public var renameCount: Int { issues.filter { [.illegalCharacter, .trailingDotOrSpace, .tooLong, .caseCollision].contains($0.kind) }.count }
    public var unreadableCount: Int { issues.filter { $0.kind == .unreadable }.count }
}

/// 用 POSIX readdir 列目录。不能用 FileManager.contentsOfDirectory：它会隐藏 "._*"（AppleDouble，
/// macOS 在 NTFS/exFAT 上用它存扩展属性、Finder 标签），而这些是盘上真实存在的数据，必须随文件一起迁移。
func listDirectory(_ path: String) throws -> [String] {
    guard let dir = opendir(path) else { throw CopyError.posix("opendir", errno) }
    defer { closedir(dir) }
    var out: [String] = []
    while let ent = readdir(dir) {
        let name = withUnsafePointer(to: &ent.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) } }
        if name == "." || name == ".." { continue }
        out.append(name)
    }
    return out
}

public enum Scanner {
    /// 只读遍历源盘，生成清单条目（尚未拷贝）和预检报告。遍历顺序：目录先于其内容。
    public static func scan(root: String, options: ScanOptions = .init(), into manifest: Manifest? = nil,
                            cancel: @Sendable () -> Bool = { false }) async throws -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        var stack: [String] = [""]                    // 待遍历的相对目录
        while let rel = stack.popLast() {
            if cancel() { throw CancellationError() }
            let abs = rel.isEmpty ? root : root + "/" + rel
            let names: [String]
            do { names = try listDirectory(abs) }
            catch { report.issues.append(.init(path: rel.isEmpty ? "/" : rel, kind: .unreadable, detail: "\(error)")); continue }
            var seenLower: [String: String] = [:]
            for name in names.sorted() {
                if rel.isEmpty && options.skippedNames.contains(name) { report.skipped.append(name); continue }
                let relPath = rel.isEmpty ? name : rel + "/" + name
                var st = stat()
                guard lstat(root + "/" + relPath, &st) == 0 else {
                    report.issues.append(.init(path: relPath, kind: .unreadable, detail: String(cString: strerror(errno)))); continue
                }
                for issue in ExFATName.issues(forComponent: name) {
                    let k: ScanIssue.Kind = issue == .illegalCharacter ? .illegalCharacter : issue == .trailingDotOrSpace ? .trailingDotOrSpace : .tooLong
                    report.issues.append(.init(path: relPath, kind: k, detail: nil))
                }
                let lower = name.lowercased()
                if let other = seenLower[lower] { report.issues.append(.init(path: relPath, kind: .caseCollision, detail: other)) }
                seenLower[lower] = name

                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    report.dirs += 1; stack.append(relPath)
                    await manifest?.upsert(ManifestEntry(path: relPath, kind: .dir, mtime: mtime))
                case S_IFREG:
                    report.files += 1; report.totalBytes += Int64(st.st_size); report.largestFile = max(report.largestFile, Int64(st.st_size))
                    await manifest?.upsert(ManifestEntry(path: relPath, kind: .file, size: Int64(st.st_size), mtime: mtime))
                case S_IFLNK:
                    report.symlinks += 1
                    let target = (try? fm.destinationOfSymbolicLink(atPath: root + "/" + relPath)) ?? ""
                    report.issues.append(.init(path: relPath, kind: .symlink, detail: target))
                    await manifest?.upsert(ManifestEntry(path: relPath, kind: .symlink, mtime: mtime, linkTarget: target, backup: .skipped, restore: .skipped))
                default:
                    report.issues.append(.init(path: relPath, kind: .unsupportedType, detail: nil))
                }
            }
        }
        await manifest?.flush()
        return report
    }
}
