import Foundation
import N2EKit

// ntfs2exfat-cli — NTFS → exFAT 安全迁移命令行工具（备份 → 逐文件校验 → 格式化 → 拷回 → 再校验）。
// 这是 NTFS2exFAT 应用背后的同一个引擎。会擦除磁盘的步骤（erase / run）需要你输入卷名确认。

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func fmtBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

let usage = """
ntfs2exfat-cli <command>

  list                                    List external volumes
  start  <diskID> <backupDir>             Check the drive, create a job, scan (read-only). Prints the job folder.
  backup <jobDir>                         Copy everything to the backup and verify every file by SHA-256
  erase  <jobDir> --confirm "<VolumeName>"  Format the drive as exFAT (only allowed after a fully verified backup)
  restore <jobDir>                        Copy back to the new exFAT drive, verify again, write the report
  status <jobDir>                         Show where the job is
  run    <diskID> <backupDir> --confirm "<VolumeName>"   All steps in one go

Erasing destroys everything on the drive. Nothing is erased until the backup is verified
and you typed the exact volume name.
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(2) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}

func printProgress(_ p: JobProgress) {
    let pct = Int(p.fraction * 100)
    FileHandle.standardError.write(Data("\r\(p.phase): \(pct)%  \(p.filesDone)/\(p.filesTotal) files  \(fmtBytes(p.bytesDone))/\(fmtBytes(p.bytesTotal))        ".utf8))
}

func report(_ r: PhaseResult, _ what: String) throws {
    err("")
    if r.cancelled { err("\(what): interrupted — run the same command again to resume."); exit(130) }
    err("\(what): \(r.done) ok, \(r.failed) failed")
}

func doStart(_ disk: String, _ backupDir: String) async throws -> MigrationJob {
    let mount = try await MigrationJob.prepareSource(disk)
    err("Mounted read-only, exclusively: \(mount)")
    let job = try MigrationJob.create(sourceVolume: disk, backupRoot: backupDir)
    err("Job: \(job.directory.path)")
    let rep = try await job.scan()
    err("Scanned: \(rep.files) files, \(rep.dirs) folders, \(fmtBytes(rep.totalBytes))")
    if !rep.skipped.isEmpty { err("Skipped system folders: \(rep.skipped.joined(separator: ", "))") }
    if rep.renameCount > 0 { err("\(rep.renameCount) names are not valid on exFAT and will be renamed when copied back (listed in the report).") }
    if rep.unreadableCount > 0 { err("WARNING: \(rep.unreadableCount) items could not be read.") }
    return job
}

func doBackup(_ job: MigrationJob) async throws {
    var r = try await job.backup(progress: printProgress); try report(r, "Backup")
    r = try await job.verifyBackup(progress: printProgress); try report(r, "Verify backup")
    let s = await job.summary()
    if s.backupFailed > 0 || s.backupPending > 0 { err("Backup is NOT fully verified (\(s.backupFailed) failed, \(s.backupPending) pending). Nothing will be erased."); exit(1) }
    err("Backup verified: \(s.backupVerified) files identical.")
}

func doErase(_ job: MigrationJob, confirm: String) async throws {
    try await job.erase(confirmedName: confirm)
    err("Formatted as exFAT: \(job.state.newLabel ?? "") at \(job.state.targetRoot ?? "")")
}

func doRestore(_ job: MigrationJob) async throws {
    let r = try await job.restore(progress: printProgress); try report(r, "Restore + verify")
    let failed = await job.failedRestores(limit: 50)
    if !failed.isEmpty {
        err("Some files were not copied back. All of them are still safe in the backup:")
        err("  \(job.dataRoot)")
        for e in failed { err("  - \(e.path): \(e.error ?? "")") }
        err("Fix the cause (free space, reconnect the drive) and run 'restore' again; only the missing files are copied.")
        exit(1)
    }
    let text = try await job.finish()
    print(text)
}

func jobDir(_ args: [String]) -> URL { URL(fileURLWithPath: args.first ?? ".") }

do {
    switch cmd {
    case "list":
        for v in try DiskUtil.externalVolumes() {
            print("\(v.identifier)\t\(v.fileSystem)\t\(v.volumeName)\t\(fmtBytes(v.totalSize))\t\(v.mountPoint ?? "(not mounted)")")
        }
    case "start":
        guard args.count >= 2 else { print(usage); exit(2) }
        _ = try await doStart(args[0], args[1])
    case "backup":
        try await doBackup(try MigrationJob.resume(directory: jobDir(args)))
    case "erase":
        let confirm = option("--confirm")
        guard let confirm else { err("erase needs --confirm \"<VolumeName>\""); exit(2) }
        try await doErase(try MigrationJob.resume(directory: jobDir(args)), confirm: confirm)
    case "restore":
        try await doRestore(try MigrationJob.resume(directory: jobDir(args)))
    case "status":
        let job = try MigrationJob.resume(directory: jobDir(args))
        let s = await job.summary()
        print("phase: \(job.state.phase.rawValue)\nsource: \(job.state.source.volumeName) (\(job.state.source.identifier))")
        print("files: \(s.files)  backup verified: \(s.backupVerified)  restore verified: \(s.restoreVerified)  failed: \(s.backupFailed + s.restoreFailed)  metadata not applied: \(s.metadataSkipped)")
        print("backup: \(job.dataRoot)")
    case "run":
        let confirm = option("--confirm")
        guard args.count >= 2, let confirm else { print(usage); exit(2) }
        let job = try await doStart(args[0], args[1])
        try await doBackup(job)
        try await doErase(job, confirm: confirm)
        try await doRestore(job)
    default:
        print(usage); exit(2)
    }
} catch {
    err("Error: \(error)")
    exit(1)
}
