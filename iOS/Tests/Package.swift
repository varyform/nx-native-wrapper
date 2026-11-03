// swift-tools-version: 6.0
// The iOS app's logic that needs no UIKit, built and tested on the Mac: the pairing link and addresses (Shared), the
// client's pairing attempts and advice, the stored pairing, Bonjour's addresses, and Sources' state for each pairing.
// Logic/ links to the app's own files. Run: swift test --package-path iOS/Tests --scratch-path <somewhere outside iOS/>
import PackageDescription

let package = Package(
    name: "NXPlayIOSLogic",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "NXPlayIOSLogic", path: "Logic"),
        .testTarget(name: "NXPlayIOSLogicTests", dependencies: ["NXPlayIOSLogic"], path: "LogicTests"),
    ]
)
