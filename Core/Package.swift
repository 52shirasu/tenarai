// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if os(macOS)
// The bundled Metal backend crashes while loading a BF16 kernel on the development machine.
// Use the upstream CPU-only backend until GPU compatibility is verified.
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = ["ZenzaiCPU"]
#else
// for testing in Ubuntu environment.
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = []
#endif

var products: [Product] = [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
        name: "Core",
        targets: ["Core"]
    )
]

var targets: [Target] = [
    .executableTarget(name: "SecurityScenarios", dependencies: ["Core"], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .executableTarget(name: "TenaraiScenarios", dependencies: ["Core"], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .executableTarget(name: "TenaraiChecks", dependencies: ["Core"], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .executableTarget(
        name: "TenaraiMemoryTool",
        dependencies: ["Core", .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
    .executableTarget(
        name: "git-info-generator"
    ),
    .plugin(
        name: "GitInfoPlugin",
        capability: .buildTool(),
        dependencies: [.target(name: "git-info-generator")]
    ),
    .target(
        name: "Core",
        dependencies: [
            .product(name: "SwiftUtils", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "EfficientNGram", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "LearningCore", package: "LearningCore")
        ],
        resources: [.process("Resources")],
        swiftSettings: [.interoperabilityMode(.Cxx), .define("TENARAI_LOCAL_ONLY")],
        plugins: [
            .plugin(name: "GitInfoPlugin")
        ]
    ),
    .testTarget(
        name: "CoreTests",
        dependencies: ["Core", "TrendWords", .product(name: "LearningCore", package: "LearningCore")],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
    // 流行語の一覧の取得と生成。通信するプログラムに使うため Foundation だけに依存し、Core は含めない
    .target(
        name: "TrendWords"
    ),
    .testTarget(
        name: "TrendWordsTests",
        dependencies: ["TrendWords"]
    )
]

#if os(macOS)
products.append(
    .executable(
        name: "ConverterServer",
        targets: ["ConverterServer"]
    )
)
targets.append(
    .executableTarget(
        name: "ConverterServer",
        dependencies: ["Core", .product(name: "LearningCore", package: "LearningCore")],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    )
)
products.append(
    .executable(
        name: "TrendWordsUpdater",
        targets: ["TrendWordsUpdater"]
    )
)
targets.append(
    .executableTarget(
        name: "TrendWordsUpdater",
        dependencies: ["TrendWords"]
    )
)
#endif

let package = Package(
    name: "Core",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: [
        .package(path: "../LearningCore"),
        .package(path: "../Vendor/AzooKeyKanaKanjiConverter", traits: kanaKanjiConverterTraits),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")
    ],
    targets: targets
)
