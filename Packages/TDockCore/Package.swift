// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TDockCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TDockCore", targets: ["TDockCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "2.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "TDockCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "TDockCoreTests",
            dependencies: [
                "TDockCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
    ]
)
