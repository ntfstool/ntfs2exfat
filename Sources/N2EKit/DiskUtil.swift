import Foundation

public struct DiskUtilError: Error, CustomStringConvertible {
    public var command: String
    public var status: Int32
    public var output: String
    public var description: String { "\(command) failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

/// diskutil 的最小封装（同步）。N2EKit 自带这部分，是为了能独立开源，不依赖 App 里的其它模块。
public enum DiskUtil {
    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 600) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        var timedOut = false
        let timer = DispatchWorkItem { timedOut = true; p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        p.waitUntilExit(); g.wait(); timer.cancel()
        let text = String(decoding: o, as: UTF8.self) + String(decoding: e, as: UTF8.self)
        if timedOut || p.terminationStatus != 0 { throw DiskUtilError(command: "diskutil " + args.joined(separator: " "), status: p.terminationStatus, output: timedOut ? "timed out" : text) }
        return text
    }

    public struct Info: Sendable, Equatable {
        public var identifier: String
        public var wholeDisk: String
        public var volumeName: String
        public var fileSystem: String      // 小写，如 ntfs / exfat
        public var mountPoint: String?
        public var totalSize: Int64
        /// 分区本身的字节数（diskutil 的 Size）。不随挂载驱动变化——totalSize 来自 statfs，换驱动重新挂载后会有细微差别，
        /// 不能拿来判断"是不是同一块盘"。
        public var partitionSize: Int64
        public var freeSpace: Int64?
        public var volumeUUID: String?
        public var diskUUID: String?
        public var isInternal: Bool
        public var isWritable: Bool
        public var isWholeDisk: Bool
        public var blockSize: Int64?
    }

    public static func info(_ id: String) throws -> Info {
        let text = try run(["info", "-plist", id], timeout: 30)
        guard let d = (try? PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)) as? [String: Any] else {
            throw DiskUtilError(command: "diskutil info", status: 0, output: "unparsable plist")
        }
        let fs = ((d["FilesystemType"] as? String) ?? (d["FilesystemName"] as? String) ?? "").lowercased()
        let mount = (d["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let partSize = (d["Size"] as? NSNumber)?.int64Value ?? (d["TotalSize"] as? NSNumber)?.int64Value ?? 0
        var total = (d["TotalSize"] as? NSNumber)?.int64Value ?? partSize
        var free: Int64? = fs == "apfs" ? (d["APFSContainerFree"] as? NSNumber)?.int64Value : (d["FreeSpace"] as? NSNumber)?.int64Value
        if let mount, let a = try? FileManager.default.attributesOfFileSystem(forPath: mount) {
            if let t = (a[.systemSize] as? NSNumber)?.int64Value, t > 0 { total = t }
            if let f = (a[.systemFreeSize] as? NSNumber)?.int64Value { free = f }
        }
        return Info(identifier: (d["DeviceIdentifier"] as? String) ?? id, wholeDisk: (d["ParentWholeDisk"] as? String) ?? id,
                    volumeName: (d["VolumeName"] as? String) ?? "", fileSystem: fs, mountPoint: mount, totalSize: total, partitionSize: partSize, freeSpace: free,
                    volumeUUID: d["VolumeUUID"] as? String, diskUUID: d["DiskUUID"] as? String,
                    isInternal: (d["Internal"] as? Bool) ?? false,
                    isWritable: (d["WritableVolume"] as? Bool) ?? (d["Writable"] as? Bool) ?? false,
                    isWholeDisk: (d["WholeDisk"] as? Bool) ?? false,
                    blockSize: (d["DeviceBlockSize"] as? NSNumber)?.int64Value)
    }

    /// 通过挂载点反查卷信息（用 `diskutil info -plist <mountpoint>`）。
    public static func info(mountPoint: String) throws -> Info { try info(mountPoint) }

    public static func unmountDisk(_ id: String, force: Bool) throws {
        try run(["unmountDisk"] + (force ? ["force"] : []) + [id], timeout: 120)
    }

    /// exFAT 卷标最多 11 个字符，且不能含 exFAT 非法字符。
    public static func sanitizedLabel(_ name: String) -> String {
        var s = ExFATName.sanitize(component: name.uppercased() == name ? name : name)
        if s.count > 11 { s = String(s.prefix(11)) }
        return s.isEmpty ? "EXFAT" : s
    }

    /// 以管理员权限执行 shell 命令的通道（由 App 注入，例如系统授权弹窗）。N2EKit 本身不依赖任何 UI。
    public typealias Elevator = @Sendable (_ shellCommand: String) async throws -> Void

    static func looksLikeAuthError(_ e: Error) -> Bool {
        let t = "\(e)".lowercased()
        return t.contains("privilege") || t.contains("authoriz") || t.contains("not permitted") || t.contains("permission") || t.contains("denied")
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// 把一个卷抹成 exFAT。分区 → eraseVolume（保留分区表和其它分区）；整盘直接格式化 → eraseDisk GPT。
    /// 先按普通用户权限尝试；失败且像是权限问题时，如果提供了 elevate，就用它以管理员权限重试。
    public static func eraseToExFAT(identifier id: String, label: String, elevate: Elevator? = nil) async throws {
        let isPartition = id.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil
        let args = isPartition ? ["eraseVolume", "ExFAT", label, id] : ["eraseDisk", "ExFAT", label, "GPT", id]
        func attempt(privileged: Bool) async throws {
            if privileged, let elevate { try await elevate("/usr/sbin/diskutil " + args.map(shellQuote).joined(separator: " ")) }
            else { try run(args, timeout: 1800) }
        }
        do { try await attempt(privileged: false) }
        catch {
            if looksLikeAuthError(error), elevate != nil { try await attempt(privileged: true); return }
            // 常见原因：卷被 Spotlight/Finder 占用。强制卸载整个磁盘后重试一次。
            let whole = id.replacingOccurrences(of: #"s\d+$"#, with: "", options: .regularExpression)
            try? unmountDisk(whole, force: true)
            do { try await attempt(privileged: false) }
            catch { if looksLikeAuthError(error), elevate != nil { try await attempt(privileged: true) } else { throw error } }
        }
    }
}

public extension DiskUtil {
    /// 任意路径所在卷的信息（先用 statfs 找到设备，再 diskutil info）。网络卷等没有设备节点的返回 nil。
    static func volumeInfo(forPath path: String) -> Info? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let from = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        guard from.hasPrefix("/dev/") else { return nil }
        return try? info(String(from.dropFirst(5)))
    }

    static func freeSpace(forPath path: String) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// 列出外置（含磁盘映像）分区/卷的信息。
    static func externalVolumes() throws -> [Info] {
        let text = try run(["list", "-plist", "external"], timeout: 30)
        guard let d = (try? PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)) as? [String: Any] else { return [] }
        var ids: [String] = []
        for disk in (d["AllDisksAndPartitions"] as? [[String: Any]]) ?? [] {
            let parts = (disk["Partitions"] as? [[String: Any]]) ?? []
            for p in parts { if let id = p["DeviceIdentifier"] as? String { ids.append(id) } }
            if parts.isEmpty, let id = disk["DeviceIdentifier"] as? String { ids.append(id) }
        }
        return ids.compactMap { try? info($0) }.filter { !$0.fileSystem.isEmpty }
    }
}

// MARK: 独占访问
// 同一块 NTFS 盘可能同时被多个驱动挂载（系统只读驱动 + NTFSTool/ntfs-3g 之类的读写驱动）。
// 2026-10 实测：另一个驱动写入后，系统挂载点仍是旧缓存，只能看到 2750 个文件里的 12 个。
// 如果按旧缓存扫描、备份、校验，再格式化，就会永久丢失没看到的文件。所以扫描前必须"卸掉所有挂载 → 自己只读重挂"，
// 格式化前再确认没有别的驱动挂回来。
public extension DiskUtil {
    struct MountEntry: Equatable, Sendable {
        public var source: String, mountPoint: String, type: String, readOnly: Bool
    }

    static func mountTable() -> [MountEntry] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        return text.split(separator: "\n").compactMap { line in
            // "<source> on <mountpoint> (<type>, opt, opt)"；挂载点可能含空格，以最后一个 " (" 为界
            guard let on = line.range(of: " on "), let paren = line.range(of: " (", options: .backwards), on.upperBound <= paren.lowerBound else { return nil }
            let opts = line[paren.upperBound...].dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return MountEntry(source: String(line[..<on.lowerBound]), mountPoint: String(line[on.upperBound..<paren.lowerBound]),
                              type: opts.first ?? "", readOnly: opts.contains("read-only"))
        }
    }

    /// 命令行里带着这个设备的进程（ntfs-3g / NTFSTool 的 ntfstool-4g 之类的用户态驱动）。
    static func userspaceDriverProcesses(_ id: String) -> [String] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axww", "-o", "command="]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        return text.split(separator: "\n").map(String.init).filter { $0.contains("/dev/\(id) ") || $0.contains("/dev/r\(id) ") || $0.hasSuffix("/dev/\(id)") }
    }

    /// 打开着这个设备的用户态驱动进程的挂载点。
    static func userspaceDriverMounts(_ id: String) -> [String] {
        let table = mountTable()
        var result: [String] = []
        for line in userspaceDriverProcesses(id) {
            for dev in ["/dev/\(id) ", "/dev/r\(id) "] {
                guard let r = line.range(of: dev) else { continue }
                // 设备参数之后就是挂载点（可能含空格）：在挂载表里找一个能匹配上的
                let rest = String(line[r.upperBound...])
                if let m = table.first(where: { rest.hasPrefix($0.mountPoint + " ") || rest == $0.mountPoint
                                                || ($0.mountPoint.hasPrefix("/private") && (rest.hasPrefix(String($0.mountPoint.dropFirst(8)) + " ") || rest == String($0.mountPoint.dropFirst(8)))) }) {
                    if !result.contains(m.mountPoint) { result.append(m.mountPoint) }
                }
            }
        }
        return result
    }

    /// 如果这块盘不是"只被系统挂载一次、而且只读"，返回原因；否则 nil。
    static func exclusivityProblem(_ id: String) -> String? {
        let fuse = userspaceDriverMounts(id)
        if !fuse.isEmpty { return "another NTFS driver is using this drive (\(fuse.joined(separator: ", ")))" }
        if let proc = userspaceDriverProcesses(id).first {
            return "a program still has the drive open (\((proc.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }) ?? "?"))"
        }
        let direct = mountTable().filter { $0.source == "/dev/\(id)" }
        if direct.count > 1 { return "the drive is mounted \(direct.count) times" }
        if let m = direct.first, !m.readOnly { return "the drive is mounted with write access (\(m.type)); it must be read-only while we work on it" }
        return nil
    }

    /// 卸掉这块盘的所有挂载（含其它驱动的），再以只读方式重新挂载，保证看到的是盘上的真实内容。返回新挂载点。
    static func remountExclusiveReadOnly(_ id: String, elevate: Elevator? = nil) async throws -> String {
        sync()
        for mp in userspaceDriverMounts(id) {
            do { try runTool("/sbin/umount", [mp]) }
            catch {
                guard let elevate else { throw error }
                try await elevate("/sbin/umount " + shellQuote(mp))
            }
        }
        for _ in 0..<20 where !userspaceDriverMounts(id).isEmpty { try await Task.sleep(nanoseconds: 300_000_000) }
        if !userspaceDriverMounts(id).isEmpty { throw DiskUtilError(command: "umount", status: 1, output: "another NTFS driver still holds the drive") }
        for m in mountTable() where m.source == "/dev/\(id)" {
            // 这里只会卸载只读挂载或刚才已经同步过的挂载；卸载失败（被 Finder/Spotlight 占用）再强制
            if (try? run(["unmount", id], timeout: 60)) == nil { _ = try? run(["unmount", "force", id], timeout: 60) }
            _ = m
        }
        try run(["mount", "readOnly", id], timeout: 120)
        guard let mp = try info(id).mountPoint else { throw DiskUtilError(command: "diskutil mount readOnly", status: 1, output: "not mounted") }
        if let p = exclusivityProblem(id) { throw DiskUtilError(command: "remount", status: 1, output: p) }
        return mp
    }

    @discardableResult
    static func runTool(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 { throw DiskUtilError(command: ([path] + args).joined(separator: " "), status: p.terminationStatus, output: text) }
        return text
    }
}
