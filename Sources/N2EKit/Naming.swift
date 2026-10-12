import Foundation

/// exFAT 的文件名规则与处理。
public enum ExFATName {
    /// exFAT 不允许的字符：控制字符 0x00–0x1F 以及 " * / : < > ? \ |
    static let illegal: Set<Character> = ["\"", "*", ":", "<", ">", "?", "\\", "|"]
    public static let maxComponentUTF16 = 255

    public enum Issue: String, Codable, Sendable { case illegalCharacter, trailingDotOrSpace, tooLong }

    public static func issues(forComponent name: String) -> [Issue] {
        var out: [Issue] = []
        if name.contains(where: { illegal.contains($0) || ($0.asciiValue.map { $0 < 0x20 } ?? false) }) { out.append(.illegalCharacter) }
        if name.hasSuffix(".") || name.hasSuffix(" ") { out.append(.trailingDotOrSpace) }
        if name.utf16.count > maxComponentUTF16 { out.append(.tooLong) }
        return out
    }

    /// 把一个路径分量改成 exFAT 合法名字：非法字符换成 "_"，去掉结尾的点和空格，过长则截断（保留扩展名）。
    public static func sanitize(component name: String) -> String {
        var s = String(name.map { (illegal.contains($0) || ($0.asciiValue.map { $0 < 0x20 } ?? false)) ? "_" : $0 })
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        if s.isEmpty { s = "_" }
        if s.utf16.count > maxComponentUTF16 {
            let ext = (s as NSString).pathExtension
            let keepExt = ext.isEmpty || ext.utf16.count > 20 ? "" : "." + ext
            var base = String(s.dropLast(keepExt.count))
            while (base + keepExt).utf16.count > maxComponentUTF16 { base.removeLast() }
            s = base + keepExt
        }
        return s
    }

    /// 处理整条相对路径，并保证同一目录下（不区分大小写）不重名；used 记录每个目录已占用的小写名字。
    public static func restorePath(for path: String, used: inout [String: Set<String>]) -> String {
        let parts = path.split(separator: "/").map(String.init)
        var outParts: [String] = []
        for (i, comp) in parts.enumerated() {
            var name = issues(forComponent: comp).isEmpty ? comp : sanitize(component: comp)
            let dirKey = outParts.joined(separator: "/").lowercased()      // 目录也不区分大小写
            var set = used[dirKey] ?? []
            // 目录分量允许重复出现（同一个目录被多个文件经过），只有最后一个分量需要去重
            let isLast = i == parts.count - 1
            if isLast {
                var candidate = name, n = 2
                while set.contains(candidate.lowercased()) {
                    let ext = (name as NSString).pathExtension
                    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                    candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                    n += 1
                }
                name = candidate
                set.insert(name.lowercased()); used[dirKey] = set
            }
            outParts.append(name)
        }
        return outParts.joined(separator: "/")
    }
}
