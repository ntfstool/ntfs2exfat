#!/bin/bash
# 端到端测试：在一个真实的 NTFS 磁盘映像上跑完整迁移（备份→校验→格式化为 exFAT→拷回→校验），并逐文件比对。
# 需要：mkntfs 和 ntfs-3g 的可执行文件（NTFSTool 自带）+ fuse-t（用来无 root 写入测试数据）。
# 环境变量：N2E_DRIVER_DIR（必填：含 mkntfs 和 ntfs-3g 可执行文件 ntfstool-4g 的目录）
# 安全：只会格式化 "Protocol: Disk Image" 的设备，且标识符必须来自本脚本刚 attach 的映像。
set -euo pipefail
cd "$(dirname "$0")/.."
DRV="${N2E_DRIVER_DIR:-}"
[ -n "$DRV" ] && [ -x "$DRV/mkntfs" ] && [ -x "$DRV/ntfstool-4g" ] || { echo "SKIP: set N2E_DRIVER_DIR to a folder containing mkntfs and an ntfs-3g build (ntfstool-4g)"; exit 0; }
W="$(mktemp -d)"; LABEL="E2E$RANDOM"; IMG="$W/n.img"; DISK=""
KEEP="${N2E_KEEP:-0}"
cleanup() { if [ "$KEEP" = 1 ]; then echo "(kept: $W, disk $DISK)"; return; fi; [ -n "$DISK" ] && hdiutil detach "$DISK" -force >/dev/null 2>&1 || true; umount "$W/mnt" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

echo "== 1. 造 NTFS 映像并用 ntfs-3g 写入数据"
mkfile -n 400m "$IMG"; "$DRV/mkntfs" -F -Q -L "$LABEL" "$IMG" >/dev/null 2>&1
mkdir -p "$W/mnt"; (DYLD_LIBRARY_PATH="$DRV" "$DRV/ntfstool-4g" "$IMG" "$W/mnt" -o rw,volname="$LABEL" >/dev/null 2>&1 &)
for i in $(seq 1 20); do mount | grep -q "$W/mnt" && break; sleep 0.5; done; mount | grep -q "$W/mnt" || { echo "FAIL: ntfs-3g mount"; exit 1; }
python3 - "$W/mnt" <<'PY'
import os, sys, random
r = sys.argv[1]; random.seed(11)
def w(rel, data):
    p = os.path.join(r, rel); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(data)
for i in range(250): w(f"Photos/2024/IMG_{i:04d}.jpg", random.randbytes(random.randint(1, 80000)))
for i in range(30): w(f"Docs/项目 {i}/说明 文档.txt", ("内容 %d\n" % i).encode() * 40)
w("Video/big.mov", random.randbytes(48 * 1024 * 1024 + 321))
w("empty.dat", b""); w("Docs/" + "L" * 200 + ".txt", b"long name")
w("Case/Readme.txt", b"upper"); w("Case/README.TXT", b"lower")           # NTFS 区分大小写共存，exFAT 会撞名
w("日本語/ファイル.txt", "こんにちは".encode()); w("emoji/😀.txt", b"emoji")
w("Long/" + "N" * 250 + ".txt", b"near the 255 limit")                     # 临时文件名不能再加长
w("Long/" + "长" * 80 + ".txt", "长文件名".encode())                        # 240 字节 UTF-8
PY
# Finder 标签：fuse-t 挂载不支持扩展属性，macOS 会把它存成 "._*" 附属文件——真实用户盘上大量存在，且常带非 ASCII 名
TAGS='<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><string>Red</string></array></plist>'
for f in "日本語/ファイル.txt" "Docs/项目 1/说明 文档.txt" "Photos/2024/IMG_0001.jpg"; do xattr -w com.apple.metadata:_kMDItemUserTags "$TAGS" "$W/mnt/$f"; done
cp "$W/mnt/Photos/2024/._IMG_0001.jpg" "$W/mnt/Photos/2024/._ghost.jpg" 2>/dev/null || true   # 孤立的附属文件（对应文件不存在）
ls -a "$W/mnt/日本語" | grep -q '^\._' && echo "   AppleDouble sidecars present on source" || echo "   (note: no ._ sidecars were created on the source)"
sync; umount "$W/mnt"; sleep 2

echo "== 2. attach 映像（macOS 原生只读挂载）并记录原盘文件树"
OUT="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage "$IMG")"; DISK="$(echo "$OUT" | awk 'NR==1{print $1}')"; SRCMNT="$(echo "$OUT" | awk -F'\t' 'END{print $NF}' | sed 's/^ *//')"
ID="${DISK#/dev/}"
diskutil info "$ID" | grep -q "Protocol:.*Disk Image" || { echo "FAIL: $ID is not a disk image — refusing"; exit 1; }
echo "   $ID at $SRCMNT"
cat > "$W/tree.py" <<'PY'
import os, sys, hashlib, json
root = sys.argv[1]; out = {}
for d, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f); out[os.path.relpath(p, root)] = hashlib.sha256(open(p, 'rb').read()).hexdigest()
json.dump(out, open(sys.argv[2], 'w'))
print(len(out), "files")
PY
python3 "$W/tree.py" "$SRCMNT" "$W/native.json"

echo "== 3. 分步迁移，并检查安全拦截（CLI）"
swift build -c release --product ntfs2exfat-cli 2>&1 | tail -1
CLI=.build/release/ntfs2exfat-cli
mkdir -p "$W/backup"
JOB="$($CLI start "$ID" "$W/backup" 2>"$W/start.err")"; JOB="$(grep '^Job: ' "$W/start.err" | sed 's/^Job: //')"
sed 's/^/   /' "$W/start.err"
[ -d "$JOB" ] || { echo "FAIL: no job dir"; exit 1; }
# 3a. 备份校验之前，格式化必须被拒绝
if $CLI erase "$JOB" --confirm "$LABEL" 2>"$W/neg1.err"; then echo "FAIL: erase allowed before backup"; exit 1; fi
grep -q "needs phase" "$W/neg1.err" && echo "   OK: erase refused before the backup is verified"
$CLI backup "$JOB" 2>&1 | tr '\r' '\n' | grep -vE "^(backup|verifyBackup): [0-9]+%" | sed 's/^/   /'
# 3b. 卷名输错必须被拒绝，且磁盘没有被动过
if $CLI erase "$JOB" --confirm "WRONG-NAME" 2>"$W/neg2.err"; then echo "FAIL: erase allowed with wrong name"; exit 1; fi
grep -q "does not match" "$W/neg2.err" && echo "   OK: erase refused with a wrong volume name"
diskutil info "$ID" | grep -q "NTFS" || { echo "FAIL: disk changed by a refused erase"; exit 1; }
# 3c. 正确确认后格式化
$CLI erase "$JOB" --confirm "$LABEL" 2>&1 | sed 's/^/   /'
REPORT="$($CLI restore "$JOB" 2>"$W/run.err")" || { tr '\r' '\n' < "$W/run.err" | tail -8; echo "FAIL: restore"; exit 1; }
tr '\r' '\n' < "$W/run.err" | grep -vE "^(restore|verifyRestore): [0-9]+%" | sed 's/^/   /'
echo "$REPORT" | sed 's/^/   | /' | head -12

echo "== 4. 比对恢复后的 exFAT 卷"
NEWMNT="$(echo "$REPORT" | sed -n 's/^New volume: .* at \(.*\)$/\1/p')"
diskutil info "$NEWMNT" | grep -qi "exfat" || { echo "FAIL: $NEWMNT is not exFAT"; exit 1; }
python3 "$W/tree.py" "$NEWMNT" "$W/restored.json"
python3 - "$W/native.json" "$W/restored.json" "$REPORT" <<'PY'
import json, sys, re
native = json.load(open(sys.argv[1])); restored = json.load(open(sys.argv[2]))
# "._*" 附属文件在 exFAT 上会被 macOS 合并成扩展属性，不会以文件形式出现，比对时排除
native = {k: v for k, v in native.items() if not k.split("/")[-1].startswith("._")}
restored = {k: v for k, v in restored.items() if not k.split("/")[-1].startswith("._") and not k.startswith((".fseventsd/", ".Spotlight-V100/", ".Trashes/"))}   # exFAT 上 macOS 自己也会生成目录的 ._*
renames = dict(re.findall(r"^renamed: (.*) -> (.*)$", sys.argv[3], re.M))
expected = {renames.get(k, k): v for k, v in native.items()}
missing = sorted(set(expected) - set(restored)); extra = sorted(set(restored) - set(expected))
wrong = sorted(k for k in expected if k in restored and restored[k] != expected[k])
print(f"   source files: {len(native)}  restored files: {len(restored)}  renamed for exFAT: {len(renames)}")
for k, v in renames.items(): print("   renamed:", k, "->", v)
if missing or extra or wrong:
    print("FAIL missing:", missing[:5], "extra:", extra[:5], "wrong:", wrong[:5]); sys.exit(1)
print("   OK: every file present with identical content")
PY
grep -q "^Metadata not applied: " <<<"$REPORT" && grep "^Metadata not applied: \|^metadata not applied: " <<<"$REPORT" | sed 's/^/   /'
for f in "日本語/ファイル.txt" "Docs/项目 1/说明 文档.txt" "Photos/2024/IMG_0001.jpg"; do
  xattr -p com.apple.metadata:_kMDItemUserTags "$NEWMNT/$f" >/dev/null 2>&1 && echo "   OK: Finder tag kept on $f" || { echo "FAIL: Finder tag lost on $f"; exit 1; }
done
echo "== E2E PASSED"
