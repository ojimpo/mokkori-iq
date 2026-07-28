// swift-tools-version: 5.9
// MokkoriCore — 解析エンジン (turn_stand.py / swim_report.py の Swift 移植)。
// iOS アプリ本体 (app/MokkoriIQ) から利用する。macOS でもビルドできるので
// パリティテスト (swift test) は Mac 上で Xcode 不要で回る。
import PackageDescription

let package = Package(
    name: "MokkoriCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MokkoriCore", targets: ["MokkoriCore"]),
    ],
    targets: [
        .target(name: "MokkoriCore"),
        .testTarget(name: "MokkoriCoreTests", dependencies: ["MokkoriCore"]),
    ]
)
