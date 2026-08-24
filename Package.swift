// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = []
var ivyCoreDependencies: [Target.Dependency] = [
    .product(name: "LeafiyUICore", package: "leafiy-ui")
]
var ivyCoreTestDependencies: [Target.Dependency] = ["IvyCore"]
var targets: [Target] = []

// Apple SDKs ship an SQLite3 module; Linux links the system library so
// IvyCore tests can run there too.
#if !canImport(Darwin)
targets.append(
    .systemLibrary(
        name: "CSQLite",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"])]
    )
)
ivyCoreDependencies.append("CSQLite")
ivyCoreTestDependencies.append("CSQLite")
#endif

targets.append(contentsOf: [
    .target(
        name: "IvyCore",
        dependencies: ivyCoreDependencies
    ),
    .testTarget(
        name: "IvyCoreTests",
        dependencies: ivyCoreTestDependencies
    )
])

// The app target needs AppKit/SwiftUI; IvyCore stays UI-free and testable.
#if os(macOS)
products.append(.executable(name: "ivy", targets: ["Ivy"]))
targets.append(
    .executableTarget(
        name: "Ivy",
        dependencies: [
            "IvyCore",
            .product(name: "LeafiyUI", package: "leafiy-ui"),
            .product(name: "LeafiyUICore", package: "leafiy-ui")
        ],
        resources: [.process("Resources")]
    )
)
targets.append(
    .testTarget(
        name: "IvyTests",
        dependencies: ["Ivy"]
    )
)
#endif

let package = Package(
    name: "Ivy",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    dependencies: [
        .package(path: "../leafiy-ui")
    ],
    targets: targets
)
