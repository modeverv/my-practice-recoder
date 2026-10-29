// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PracticeRecorder", platforms: [.macOS(.v15)], products: [
 .executable(name: "PracticeRecorder", targets: ["PracticeRecorderApp"]),
 .executable(name: "PracticeRecorderCheck", targets: ["PracticeRecorderCheck"])
], targets: [
 .target(name: "PracticeRecorderCore"),
 .target(name: "PracticeRecorderMedia", dependencies: ["PracticeRecorderCore"]),
 .executableTarget(name: "PracticeRecorderApp", dependencies: ["PracticeRecorderCore", "PracticeRecorderMedia"]),
 .executableTarget(name: "PracticeRecorderCheck", dependencies: ["PracticeRecorderCore", "PracticeRecorderMedia"]),
 .testTarget(name: "PracticeRecorderTests", dependencies: ["PracticeRecorderCore", "PracticeRecorderMedia"]),
 .testTarget(name: "PracticeRecorderAppTests", dependencies: ["PracticeRecorderApp"])
], swiftLanguageModes: [.v5])
