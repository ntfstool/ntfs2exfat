import XCTest
@testable import N2EKit

final class EngineTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("n2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // 造一棵源目录树：含空文件、大文件、深层目录、Unicode、非法字符、尾部点号、系统目录、符号链接
    func makeSource() throws -> String {
        let src = tmp.appendingPathComponent("src").path
        let fm = FileManager.default
        func w(_ rel: String, _ data: Data) throws {
            let p = src + "/" + rel
            try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: p))
        }
        try w("a.txt", Data("hello".utf8))
        try w("empty.bin", Data())
        try w("deep/er/er/file.dat", Data((0..<100_000).map { UInt8($0 % 251) }))
        try w("big.bin", Data(repeating: 0xAB, count: 9 * 1024 * 1024 + 7))       // 跨多个 4MiB 缓冲
        try w("中文/文件 名.txt", Data("unicode".utf8))
        try w("bad:name?.txt", Data("illegal".utf8))
        try w("trailing.", Data("dot".utf8))
        try w("System Volume Information/x.dat", Data("sys".utf8))
        try fm.createSymbolicLink(atPath: src + "/link", withDestinationPath: "a.txt")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: src + "/a.txt")
        return src
    }

    func makeEngine() async throws -> (CopyEngine, Manifest) {
        let m = try Manifest(url: tmp.appendingPathComponent("job/manifest.jsonl"))
        return (CopyEngine(manifest: m, concurrency: 3), m)
    }

    func testScanReportsIssuesAndSkips() async throws {
        let src = try makeSource()
        let report = try await Scanner.scan(root: src)
        XCTAssertEqual(report.files, 7)                          // 不含被跳过的 System Volume Information
        XCTAssertEqual(report.skipped, ["System Volume Information"])
        XCTAssertEqual(report.symlinks, 1)
        let kinds = Set(report.issues.map(\.kind))
        XCTAssertTrue(kinds.contains(.illegalCharacter)); XCTAssertTrue(kinds.contains(.trailingDotOrSpace))
        XCTAssertTrue(kinds.contains(.symlink))     // 大小写撞名在 APFS(不区分大小写) 上造不出来，见 testNaming
        XCTAssertGreaterThan(report.totalBytes, 9 * 1024 * 1024)
    }

    func testFullRoundTripWithRenames() async throws {
        let src = try makeSource()
        let (engine, m) = try await makeEngine()
        _ = try await Scanner.scan(root: src, into: m)
        let data = tmp.appendingPathComponent("job/data").path
        let target = tmp.appendingPathComponent("exfat").path
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)

        let b = try await engine.backup(sourceRoot: src, dataRoot: data)
        XCTAssertEqual(b.failed, 0); XCTAssertEqual(b.done, 7)
        let v = try await engine.verifyBackup(dataRoot: data)
        XCTAssertEqual(v.done, 7); XCTAssertEqual(v.failed, 0)
        let bad = await engine.quickCheckBackup(dataRoot: data)
        XCTAssertTrue(bad.isEmpty)

        let renamed = await engine.planRestorePaths()
        XCTAssertEqual(renamed, 2)                               // bad:name?.txt、trailing.
        let r = try await engine.restore(dataRoot: data, targetRoot: target)
        XCTAssertEqual(r.failed, 0)
        let rv = try await engine.verifyRestore(targetRoot: target)
        XCTAssertEqual(rv.failed, 0)

        let s = await m.summary()
        XCTAssertEqual(s.restoreVerified, 7); XCTAssertEqual(s.restoreFailed, 0)
        // 内容、改名、时间戳
        XCTAssertEqual(try String(contentsOfFile: target + "/bad_name_.txt"), "illegal")
        XCTAssertEqual(try String(contentsOfFile: target + "/trailing"), "dot")
        XCTAssertEqual(try String(contentsOfFile: target + "/中文/文件 名.txt"), "unicode")
        let a = try FileManager.default.attributesOfItem(atPath: target + "/a.txt")
        XCTAssertEqual((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, 1_600_000_000, accuracy: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/System Volume Information"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/link"))   // 符号链接不会被拷回
        // 没有残留的临时文件
        let leftovers = (FileManager.default.enumerator(atPath: data)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".n2etmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testVerifyCatchesCorruptedBackup() async throws {
        let src = try makeSource()
        let (engine, m) = try await makeEngine()
        _ = try await Scanner.scan(root: src, into: m)
        let data = tmp.appendingPathComponent("job/data").path
        _ = try await engine.backup(sourceRoot: src, dataRoot: data)
        // 悄悄改动备份里的一个字节（大小不变）——只有哈希校验能发现
        let victim = data + "/deep/er/er/file.dat"
        var bytes = try Data(contentsOf: URL(fileURLWithPath: victim)); bytes[500] ^= 0xFF
        try bytes.write(to: URL(fileURLWithPath: victim))
        let v = try await engine.verifyBackup(dataRoot: data)
        XCTAssertEqual(v.failed, 1)
        let s = await m.summary()
        XCTAssertEqual(s.backupFailed, 1)
        let victimEntry = await m.entry("deep/er/er/file.dat")
        XCTAssertEqual(victimEntry?.backup, .failed)
        // quickCheck 只看大小，抓不到这种损坏——所以格式化前必须依赖 verifyBackup 的结果
        let bad = await engine.quickCheckBackup(dataRoot: data)
        XCTAssertTrue(bad.isEmpty)
    }

    func testQuickCheckCatchesMissingAndTruncated() async throws {
        let src = try makeSource()
        let (engine, m) = try await makeEngine()
        _ = try await Scanner.scan(root: src, into: m)
        let data = tmp.appendingPathComponent("job/data").path
        _ = try await engine.backup(sourceRoot: src, dataRoot: data)
        _ = try await engine.verifyBackup(dataRoot: data)
        try FileManager.default.removeItem(atPath: data + "/a.txt")
        try Data("x".utf8).write(to: URL(fileURLWithPath: data + "/big.bin"))
        let bad = Set(await engine.quickCheckBackup(dataRoot: data))
        XCTAssertEqual(bad, ["a.txt", "big.bin"])
    }

    func testResumeAfterCancelSkipsFinishedFiles() async throws {
        let src = try makeSource()
        let (engine, m) = try await makeEngine()
        _ = try await Scanner.scan(root: src, into: m)
        let data = tmp.appendingPathComponent("job/data").path
        // 进度回调里一收到第一个进度就取消，模拟用户中断
        let cancelled = try await engine.backup(sourceRoot: src, dataRoot: data) { _ in engine.cancel() }
        XCTAssertTrue(cancelled.cancelled)
        let partial = await m.summary()
        XCTAssertLessThan(partial.backupVerified + partial.backupPending, 100)
        await m.close()

        // “重启”：重新加载清单，续传
        let m2 = try Manifest(url: tmp.appendingPathComponent("job/manifest.jsonl"))
        let engine2 = CopyEngine(manifest: m2, concurrency: 3)
        let pendingBefore = await m2.all.filter { $0.kind == .file && $0.backup == .pending }.count
        let b = try await engine2.backup(sourceRoot: src, dataRoot: data)
        XCTAssertEqual(b.done, pendingBefore)                    // 只拷还没完成的
        let v = try await engine2.verifyBackup(dataRoot: data)
        XCTAssertEqual(v.failed, 0)
        let s = await m2.summary()
        XCTAssertEqual(s.backupVerified, 7)
    }

    func testRestoreDetectsBackupChangedAfterVerification() async throws {
        let src = try makeSource()
        let (engine, m) = try await makeEngine()
        _ = try await Scanner.scan(root: src, into: m)
        let data = tmp.appendingPathComponent("job/data").path
        let target = tmp.appendingPathComponent("exfat").path
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        _ = try await engine.backup(sourceRoot: src, dataRoot: data)
        _ = try await engine.verifyBackup(dataRoot: data)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: data + "/a.txt")); bytes[0] ^= 0x01
        try bytes.write(to: URL(fileURLWithPath: data + "/a.txt"))
        _ = await engine.planRestorePaths()
        let r = try await engine.restore(dataRoot: data, targetRoot: target)
        XCTAssertEqual(r.failed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/a.txt"), "a corrupt file must not be left on the new disk")
    }

    func testManifestSurvivesTruncatedLastLine() async throws {
        let url = tmp.appendingPathComponent("m.jsonl")
        let m = try Manifest(url: url)
        await m.upsert(ManifestEntry(path: "a", kind: .file, size: 1)); await m.close()
        let h = try FileHandle(forWritingTo: url); h.seekToEndOfFile(); h.write(Data(#"{"path":"b","kin"#.utf8)); try h.close()
        let m2 = try Manifest(url: url)
        let n = await m2.count
        XCTAssertEqual(n, 1)
    }

    func testNaming() {
        XCTAssertEqual(ExFATName.sanitize(component: "a:b*c?.txt"), "a_b_c_.txt")
        XCTAssertEqual(ExFATName.sanitize(component: "name. "), "name")
        let long = String(repeating: "x", count: 300) + ".mp4"
        let s = ExFATName.sanitize(component: long)
        XCTAssertLessThanOrEqual(s.utf16.count, 255); XCTAssertTrue(s.hasSuffix(".mp4"))
        var used: [String: Set<String>] = [:]
        XCTAssertEqual(ExFATName.restorePath(for: "d/A.txt", used: &used), "d/A.txt")
        XCTAssertEqual(ExFATName.restorePath(for: "d/a.TXT", used: &used), "d/a (2).TXT")
        XCTAssertEqual(DiskUtil.sanitizedLabel("My Very Long Backup Disk"), "My Very Lon")
    }

    /// NTFS 区分大小写共存的文件，备份到不区分大小写的卷（APFS）时必须各有各的路径，不能互相覆盖。
    func testBackupPathsAvoidCaseCollisions() async throws {
        let (engine, m) = try await makeEngine()
        for p in ["Case/Readme.txt", "Case/README.TXT", "Dir/a.txt", "dir/A.txt", "ok.txt"] {
            await m.upsert(ManifestEntry(path: p, kind: .file, size: 1))
        }
        await engine.planBackupPaths()
        var seen = Set<String>()
        for e in await m.all {
            let bp = (e.backupPath ?? e.path).lowercased()
            XCTAssertTrue(seen.insert(bp).inserted, "backup path collides case-insensitively: \(bp)")
        }
        let ok = await m.entry("ok.txt"); XCTAssertNil(ok?.backupPath)
        // 幂等：再规划一次结果不变
        let before = await m.all.map { $0.backupPath }
        await engine.planBackupPaths()
        let after = await m.all.map { $0.backupPath }
        XCTAssertEqual(before, after)
    }
}
