// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlideOver",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SlideOver",
            path: "Sources/SlideOver",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
