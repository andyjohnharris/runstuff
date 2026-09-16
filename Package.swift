// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
  .unsafeFlags(["-warnings-as-errors"])
]

let package = Package(
  name: "RunStuff",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")
  ],
  targets: [
    .target(
      name: "RunStuffCore",
      path: "RunStuffCore",
      swiftSettings: strict,
      linkerSettings: [.linkedFramework("Security")]
    ),
    .executableTarget(
      name: "runstuff-acceptance",
      dependencies: [
        "RunStuffCore",
        .product(name: "SwiftTerm", package: "SwiftTerm"),
      ],
      path: "RunStuffAcceptance",
      swiftSettings: strict
    ),
    .executableTarget(
      name: "runstuff",
      dependencies: ["RunStuffCore"],
      path: "RunStuffCLI",
      swiftSettings: strict
    ),
    // C helper that acquires the controlling terminal before exec, which
    // posix_spawn cannot do. Built next to runstuff-acceptance, which finds it
    // automatically.
    .executableTarget(
      name: "runstuff-tty-helper",
      path: "RunStuffTTYHelper",
      cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]
    ),
    .testTarget(
      name: "RunStuffCoreTests",
      dependencies: ["RunStuffCore"],
      path: "RunStuffCoreTests",
      swiftSettings: strict
    ),
  ]
)
