// swift-tools-version:5.9
// N2EKit：NTFS → exFAT 安全迁移引擎（扫描 / 备份 / 逐文件 SHA-256 校验 / 格式化 / 拷回 / 断点续传）。
// 只依赖 Foundation 与 CryptoKit，可独立开源（见 docs/开源策略）。
import PackageDescription

let package = Package(
    name: "N2EKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "N2EKit", targets: ["N2EKit"]),
        .executable(name: "ntfs2exfat-cli", targets: ["ntfs2exfat-cli"]),
    ],
    targets: [
        .target(name: "N2EKit"),
        .executableTarget(name: "ntfs2exfat-cli", dependencies: ["N2EKit"]),
        .testTarget(name: "N2EKitTests", dependencies: ["N2EKit"]),
    ]
)
