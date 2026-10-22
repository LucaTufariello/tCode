// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "tCode",
  platforms: [.macOS("27.0")],
  products: [.executable(name: "tCode", targets: ["TCode"])],
  dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
  targets: [
    .target(name: "TCodeCore"),
    .target(
      name: "CTreeSitter", sources: ["runtime/lib.c"], publicHeadersPath: "include",
      cSettings: [.headerSearchPath("runtime")]),
    .target(name: "TCodeSyntax", dependencies: ["TCodeCore", "CTreeSitter"]),
    .executableTarget(name: "TCodeSyntaxService", dependencies: ["TCodeSyntax", "TCodeCore"]),
    .executableTarget(name: "TCodeSyntaxProbe", dependencies: ["TCodeCore"]),
    .testTarget(name: "TCodeSyntaxTests", dependencies: ["TCodeSyntax", "TCodeCore"]),
    .executableTarget(
      name: "TCode",
      dependencies: ["TCodeCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
      resources: [.copy("Resources")]),
    .testTarget(name: "TCodeCoreTests", dependencies: ["TCodeCore"]),
    .testTarget(name: "TCodeEditorTests", dependencies: ["TCode", "TCodeCore"]),
  ],
  swiftLanguageModes: [.v5]
)
