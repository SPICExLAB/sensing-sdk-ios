// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sensing-sdk-ios",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "SensingKit", targets: ["SensingKit"]),
        .library(name: "SensingWatch", targets: ["SensingWatch"]),
        .executable(name: "sensing-decode", targets: ["sensing-decode"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    ],
    targets: [
        // Generated from proto/ by scripts/gen-proto.sh (committed, so apps don't need protoc).
        .target(name: "SensingProto", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
                exclude: ["PROTO_VERSION"]),
        // Platform-neutral: clock, sensor ids, conversions, hashing, the engine. `swift test` covers it on macOS.
        .target(name: "SensingCore", dependencies: ["SensingProto"]),
        // Platform-neutral: frames, gzip, chunk files, recovery, retention. Also covered on macOS.
        .target(name: "SensingStorage", dependencies: ["SensingCore", "SensingProto"]),
        // The recording engine, activity sessions and their outbox. Also covered on macOS.
        .target(name: "SensingEngine", dependencies: ["SensingCore", "SensingStorage", "SensingProto"]),
        // CoreMotion, CoreLocation, audio, Bluetooth, network, battery, screen. Empty on macOS.
        .target(name: "SensingAdapters", dependencies: ["SensingCore", "SensingProto"]),
        // WatchConnectivity behind a protocol, so tests use a fake.
        .target(name: "SensingLink", dependencies: ["SensingCore"]),
        // iPhone: the public API, keep-alive, starting the watch app, receiving chunks.
        .target(name: "SensingKit", dependencies: ["SensingCore", "SensingStorage", "SensingEngine", "SensingAdapters", "SensingLink"]),
        // Apple Watch: the public API, workout session and recovery, sending chunks.
        .target(name: "SensingWatch", dependencies: ["SensingCore", "SensingStorage", "SensingEngine", "SensingAdapters", "SensingLink"]),
        // macOS tool: chunks to CSV, plus a rate and gap report.
        .executableTarget(name: "sensing-decode", dependencies: ["SensingCore", "SensingStorage", "SensingProto"]),
        // macOS tool: writes a fixture of every payload type and prints chunks canonically, for scripts/compat.sh.
        .executableTarget(name: "sensing-compat", dependencies: ["SensingCore", "SensingStorage", "SensingEngine", "SensingProto"]),
        .testTarget(name: "SensingCoreTests", dependencies: ["SensingCore", "SensingProto"]),
        .testTarget(name: "SensingStorageTests", dependencies: ["SensingStorage", "SensingProto"]),
        .testTarget(name: "SensingEngineTests", dependencies: ["SensingEngine", "SensingCore", "SensingStorage", "SensingProto"]),
    ]
)
