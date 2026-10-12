# NTFS2exFAT — convert an NTFS drive to exFAT on Mac without losing files

**Short answer first:** no tool can convert NTFS to exFAT *in place*. NTFS and exFAT store data in completely different on-disk structures, so the only safe way is **back up → verify → format → copy back → verify again**. This project automates exactly that, and refuses to erase anything until every file in the backup has been re-read and its SHA-256 checksum matches.

It contains:

* **`N2EKit`** — a small Swift library (Foundation + CryptoKit only) that does the migration: scan, verified copy, resumable jobs, guarded erase, restore.
* **`ntfs2exfat-cli`** — a command-line tool built on `N2EKit`.
* The **NTFS2exFAT** Mac app (guided wizard, about 4 MB, notarized) uses the same engine. Download it from the [releases page](https://github.com/ntfstool/ntfs2exfat/releases/latest) or read the [step-by-step guide](https://ntfstool.com/ntfs-to-exfat/) (also explains the manual Disk Utility method).

> **Before you start:** formatting erases the drive. Keep the drive connected and your Mac awake, and make sure you have free space for a full backup (on another drive or on your Mac). This is a young project — read [Limitations](#limitations) first.

## Why exFAT, and when *not* to convert

| | Windows | macOS | Notes |
|---|---|---|---|
| exFAT | read/write | read/write | No 4 GB file limit. **No journal** — always eject before unplugging. |
| APFS | not supported | read/write | Best choice if the drive is only used with Macs. |
| FAT32 | read/write | read/write | 4 GB per-file limit. |
| NTFS | read/write | **read-only** | Needs a driver on Mac for writing. |

If you only want to *write* to an NTFS drive on a Mac, you don't need to convert — use an NTFS driver such as [NTFSTool](https://ntfstool.com). Convert only when you want to drop NTFS altogether.

## How it works

1. **Preflight (read-only):** counts files and folders, flags names that are not valid on exFAT, skips system folders (`System Volume Information`, `$RECYCLE.BIN`, …), and compares the drive's used space with the files macOS can see.
2. **Backup:** copies every file to a folder you choose (never on the drive being erased), computing a SHA-256 while copying. Progress is stored in an append-only manifest, so the job can be paused and resumed.
3. **Verify:** reads every backup file back from disk (uncached) and compares checksums.
4. **Erase:** only possible when the backup is fully verified, the drive is still the same one (volume/disk UUID and size), the backup folder is not on that disk, and you typed the exact volume name. The intent is written to disk *before* the drive is touched, so an interrupted erase can be recognised and resumed.
5. **Restore + verify:** copies everything onto the new exFAT volume, re-reads it, compares checksums, and writes a report (including every file that had to be renamed).

## Command line

```bash
swift build -c release
.build/release/ntfs2exfat-cli list                                   # external volumes
.build/release/ntfs2exfat-cli start  disk4 ~/Backups                 # check + create a job (read-only)
.build/release/ntfs2exfat-cli backup ~/Backups/NTFS2exFAT-<job>      # copy + verify every file
.build/release/ntfs2exfat-cli erase  ~/Backups/NTFS2exFAT-<job> --confirm "MY DRIVE"   # ERASES the drive
.build/release/ntfs2exfat-cli restore ~/Backups/NTFS2exFAT-<job>     # copy back, verify, write report
```

or everything in one go: `ntfs2exfat-cli run disk4 ~/Backups --confirm "MY DRIVE"`.

## Library

```swift
import N2EKit

let job = try MigrationJob.create(sourceVolume: "disk4", backupRoot: "/Users/me/Backups")
_ = try await job.scan()
_ = try await job.backup()
_ = try await job.verifyBackup()
if await job.eraseReadiness().isEmpty {
    try await job.erase(confirmedName: "MY DRIVE")
    _ = try await job.restore()
    print(try await job.finish())
}
```

## Limitations

* **macOS's built-in NTFS reader can hide or rename files whose names Windows does not allow** (names containing `: ? | * " < >`, or ending in a space or dot). Such names only exist on drives written by Mac or Linux NTFS drivers. In our tests the built-in reader dropped one trailing-space file entirely and silently stripped characters from three other names. The tool cannot detect an individual hidden file; it warns when the drive's used space is much larger than what is visible. If your drive may contain such files, check it in Windows or with an ntfs-3g based driver before converting.
* **`._*` files** (macOS stores Finder tags and other extended attributes in them on non-APFS volumes) are copied, but after restoring to exFAT macOS merges them into extended attributes, so they cannot be byte-verified there. The report counts them.
* Symbolic links / junctions are not copied (exFAT has none). Files that cannot be read are listed, not silently skipped.
* Not supported: BitLocker drives, system/internal disks, Boot Camp partitions.
* exFAT allocates space in clusters; many tiny files can use noticeably more space than on NTFS.
* Requires macOS 13 or later.

## Testing

* `swift test` — engine tests on temporary folders (verification catches a single flipped byte, resume after cancel, rename rules, backup path collisions on case-insensitive volumes, …).
* `Tests/e2e.sh` — end-to-end on a **real NTFS disk image** (needs `mkntfs` and an ntfs-3g build; set `N2E_DRIVER_DIR`). It builds an NTFS image, runs the full migration, and compares every file by SHA-256. It only ever formats a device whose protocol is *Disk Image*.

## License

MIT for this repository (library and CLI). The NTFS2exFAT Mac app is distributed as a signed binary.

NTFS and Windows are registered trademarks of Microsoft Corporation; Mac, macOS and APFS are trademarks of Apple Inc. This project is independent and not affiliated with or endorsed by either company.

[NTFSTool](https://ntfstool.com) · [Guide: NTFS to exFAT on Mac](https://ntfstool.com/ntfs-to-exfat/)
