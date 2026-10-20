import Foundation
import CryptoKit

public enum CopyError: Error, Equatable, CustomStringConvertible {
    case posix(String, Int32)          // 操作, errno
    case diskFull
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch(expected: String, actual: String)
    public var description: String {
        switch self {
        case .posix(let op, let e): return "\(op): \(String(cString: strerror(e))) (\(e))"
        case .diskFull: return "disk full"
        case .sizeMismatch(let a, let b): return "size mismatch (expected \(a), got \(b))"
        case .hashMismatch(let a, let b): return "checksum mismatch (expected \(a.prefix(12))…, got \(b.prefix(12))…)"
        }
    }
}

/// 底层的单文件拷贝与哈希。读写都用 F_NOCACHE，避免"校验读到的是缓存而不是盘上的数据"。
public enum FileCopier {
    static let bufferSize = 4 * 1024 * 1024

    static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// 拷贝 src → dst（先写同目录下的短临时文件，成功后原子改名），边拷边算源内容的 SHA-256。
    @discardableResult
    public static func copy(from src: String, to dst: String, mtime: Double? = nil,
                            cancel: @Sendable () -> Bool = { false }, progress: (Int64) -> Void = { _ in }) throws -> (sha256: String, bytes: Int64) {
        let inFD = open(src, O_RDONLY)
        guard inFD >= 0 else { throw CopyError.posix("open source", errno) }
        defer { close(inFD) }
        _ = fcntl(inFD, F_NOCACHE, 1)

        let parent = (dst as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        // 临时文件名要短：原名已接近 255 字符上限时，"原名.n2etmp" 会超长导致每次都失败
        let tmp = parent + "/.n2etmp-" + String(UInt32.random(in: 0...UInt32.max), radix: 16)
        let outFD = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFD >= 0 else { throw CopyError.posix("open destination", errno) }
        var outOpen = true
        defer { if outOpen { close(outFD) } }
        _ = fcntl(outFD, F_NOCACHE, 1)

        var hasher = SHA256()
        var total: Int64 = 0
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buf.deallocate() }
        do {
            while true {
                if cancel() { throw CancellationError() }
                let n = read(inFD, buf, bufferSize)
                if n < 0 { if errno == EINTR { continue }; throw CopyError.posix("read", errno) }
                if n == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                var off = 0
                while off < n {
                    let w = write(outFD, buf + off, n - off)
                    if w < 0 { if errno == EINTR { continue }; throw errno == ENOSPC ? CopyError.diskFull : CopyError.posix("write", errno) }
                    off += w
                }
                total += Int64(n); progress(Int64(n))
            }
            if fsync(outFD) != 0 { throw errno == ENOSPC ? CopyError.diskFull : CopyError.posix("fsync", errno) }
        } catch {
            close(outFD); outOpen = false
            unlink(tmp)
            throw error
        }
        if let mtime {
            var ts = [timespec(tv_sec: Int(mtime), tv_nsec: Int((mtime - floor(mtime)) * 1e9)),
                      timespec(tv_sec: Int(mtime), tv_nsec: Int((mtime - floor(mtime)) * 1e9))]
            _ = futimens(outFD, &ts)
        }
        close(outFD); outOpen = false
        if rename(tmp, dst) != 0 { let e = errno; unlink(tmp); throw CopyError.posix("rename", e) }
        return (hex(hasher.finalize()), total)
    }

    /// 重新读取磁盘上的文件并计算 SHA-256（F_NOCACHE，尽量绕过系统缓存）。
    public static func hash(path: String, cancel: @Sendable () -> Bool = { false }, progress: (Int64) -> Void = { _ in }) throws -> (sha256: String, bytes: Int64) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw CopyError.posix("open", errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256(); var total: Int64 = 0
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buf.deallocate() }
        while true {
            if cancel() { throw CancellationError() }
            let n = read(fd, buf, bufferSize)
            if n < 0 { if errno == EINTR { continue }; throw CopyError.posix("read", errno) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            total += Int64(n); progress(Int64(n))
        }
        return (hex(hasher.finalize()), total)
    }
}
