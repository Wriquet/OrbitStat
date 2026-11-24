// swift-tools-version: 5.10
import Foundation
import PackageDescription

let cltTestingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
var testSwiftSettings: [SwiftSetting] = []
if FileManager.default.fileExists(atPath: cltTestingPluginPath) {
    testSwiftSettings.append(
        .unsafeFlags(["-load-plugin-library", cltTestingPluginPath])
    )
}

let package = Package(
    name: "OrbitStat",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OrbitStat", targets: ["OrbitStat"])
    ],
    targets: [
        .executableTarget(
            name: "OrbitStat",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "OrbitStatTests",
            dependencies: ["OrbitStat"],
            swiftSettings: testSwiftSettings
        )
    ]
)
