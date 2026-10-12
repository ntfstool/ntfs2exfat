# NTFS2exFAT — 在 Mac 上把 NTFS 移动硬盘转成 exFAT，不丢文件

**先说结论：** 没有任何工具能把 NTFS **原地**转换成 exFAT，两种格式的磁盘结构完全不同。唯一安全的做法是 **备份 → 逐文件校验 → 格式化 → 拷回 → 再校验**。本项目把这个流程自动化，并且在备份里的每个文件都被重新读取、SHA-256 校验一致之前，**绝不擦除任何数据**。

* **`N2EKit`**：纯 Swift 引擎（只依赖 Foundation 和 CryptoKit）：扫描、带校验的拷贝、可续传任务、受保护的格式化、拷回。
* **`ntfs2exfat-cli`**：基于引擎的命令行工具。
* **NTFS2exFAT** Mac 应用（图形向导，约 4MB，已公证）使用同一个引擎：[下载](https://github.com/ntfstool/ntfs2exfat/releases/latest)，或先看[图文教程](https://ntfstool.com/lang/zhCN/ntfs-to-exfat/)（也包含用“磁盘工具”手动操作的方法）。

> **开始前：** 格式化会擦除磁盘。请保持磁盘连接、Mac 不休眠，并准备好能放下完整备份的空间（另一块磁盘或这台 Mac）。项目还很年轻，请先阅读下面的“局限”。

## 流程

1. **预检（只读）**：统计文件与文件夹、标出 exFAT 不允许的文件名、跳过系统目录，并对比磁盘已用空间与 macOS 能看到的文件总量。
2. **备份**：拷到你指定的文件夹（不能在即将被擦除的磁盘上），边拷边算 SHA-256；进度写入追加式清单，可随时暂停、续传。
3. **校验**：从磁盘重新读取每个备份文件（绕过缓存），与校验值比对。
4. **格式化**：只有备份全部校验通过、仍是同一块磁盘（卷/磁盘 UUID 与容量一致）、备份不在该磁盘上、并且你输入了完全一致的卷名，才允许执行。格式化前先把意图写入磁盘，所以中途被打断也能识别并继续。
5. **拷回 + 校验**：拷到新的 exFAT 卷，重新读取比对，生成报告（含所有被改名的文件）。

## 命令行

```bash
swift build -c release
.build/release/ntfs2exfat-cli list
.build/release/ntfs2exfat-cli start  disk4 ~/Backups
.build/release/ntfs2exfat-cli backup ~/Backups/NTFS2exFAT-<任务>
.build/release/ntfs2exfat-cli erase  ~/Backups/NTFS2exFAT-<任务> --confirm "磁盘名"   # 会擦除磁盘
.build/release/ntfs2exfat-cli restore ~/Backups/NTFS2exFAT-<任务>
```

## 局限（请务必阅读）

* **macOS 自带的 NTFS 读取器会隐藏或改名“Windows 不允许的文件名”**（含 `: ? | * " < >`，或以空格、句点结尾）。这种文件名只会出现在被 Mac 或 Linux 的 NTFS 驱动写过的磁盘上。我们的测试里，自带读取器把一个以空格结尾的文件完全隐藏，并悄悄去掉了另外三个文件名里的字符。工具无法发现单个被隐藏的文件，只能在“已用空间远大于可见文件”时发出警告。如果你的磁盘可能有这类文件，请先在 Windows 或用基于 ntfs-3g 的驱动检查。
* `._*` 附属文件（macOS 在非 APFS 卷上用它保存 Finder 标签等扩展属性）会被拷贝，但拷到 exFAT 后系统会把它们合并成扩展属性，无法按字节校验；报告里会统计数量。
* 符号链接/联接点不会被拷贝；无法读取的文件会列出，不会被悄悄跳过。
* 不支持：BitLocker 磁盘、系统盘/内置盘、Boot Camp 分区。需要 macOS 13 及以上。

## 许可

本仓库（库与命令行）采用 MIT 许可。NTFS2exFAT Mac 应用以签名二进制分发。NTFS、Windows 是微软的注册商标；Mac、macOS、APFS 是苹果公司的商标。本项目为独立项目，与两家公司无关联。

[NTFSTool](https://ntfstool.com)
