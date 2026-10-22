import Foundation

/// Compile with Files.swift, LanguagePack.swift and LanguagePackDefaults.swift; this maintainer tool
/// serializes the same migration/default models used by the app instead of maintaining duplicate JSON.
@main struct GenerateLanguagePacks {
  static func main() throws {
    let root = URL(
      fileURLWithPath: CommandLine.arguments.dropFirst().first
        ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let resources = root.appendingPathComponent("Sources/TCode/Resources")
    let artifacts = root.appendingPathComponent("catalog/packs")
    let rustResources = resources.appendingPathComponent("CatalogPacks")
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rustResources, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    for id in ["python", "cpp", "swift", "rust"] {
      var pack =
        id == "rust"
        ? LanguagePack.rust
        : try JSONDecoder().decode(
          LanguagePack.self, from: Data(contentsOf: resources.appendingPathComponent(id + ".json")))
      pack.version = "2.0.0"
      try pack.validate()
      let bytes = try encoder.encode(pack) + Data([0x0a])
      try bytes.write(to: artifacts.appendingPathComponent(id + ".json"), options: .atomic)
      let bundled =
        id == "rust"
        ? rustResources.appendingPathComponent("rust.json")
        : resources.appendingPathComponent(id + ".json")
      try bytes.write(to: bundled, options: .atomic)
      print(
        "Prepared \(id) interface \(pack.interfaceVersion), version \(pack.version), \(bytes.count) bytes"
      )
    }
  }
}
