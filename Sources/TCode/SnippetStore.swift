import Foundation
import TCodeCore

struct SnippetPack: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  var version: String
  var author: String?
  var summary: String?
  var languageID: String
  var snippets: [LanguageSnippet]
}

/// Declarative snippet packs. They merge into the existing language snippet menu.
@MainActor final class SnippetStore: ObservableObject {
  static let shared = SnippetStore()
  @Published private(set) var packs: [SnippetPack] = []
  private let directory: URL

  init(directory: URL = SnippetStore.defaultDirectory) {
    self.directory = directory
    reload()
  }

  nonisolated static var defaultDirectory: URL {
    LanguageSupportPaths.root.appendingPathComponent("Snippets", isDirectory: true)
  }

  static let bundled: [SnippetPack] = [
    SnippetPack(
      id: "python-starter", name: "Python Starter", version: "1.0.0", author: "tCode",
      summary: "A few small Python entry points.",
      languageID: "python",
      snippets: [
        LanguageSnippet(
          name: "main guard",
          text: "if __name__ == \"__main__\":\n    main()\n"),
        LanguageSnippet(name: "print", text: "print()"),
        LanguageSnippet(name: "test function", text: "def test_():\n    assert True\n"),
      ]),
    SnippetPack(
      id: "swift-starter", name: "Swift Starter", version: "1.0.0", author: "tCode",
      summary: "Small Swift building blocks.",
      languageID: "swift",
      snippets: [
        LanguageSnippet(
          name: "guard let", text: "guard let value = value else { return }\n"),
        LanguageSnippet(
          name: "function", text: "func name() {\n    \n}\n"),
        LanguageSnippet(
          name: "test case", text: "func testExample() throws {\n    \n}\n"),
      ]),
    SnippetPack(
      id: "rust-starter", name: "Rust Starter", version: "1.0.0", author: "tCode",
      summary: "Common Rust entry points.",
      languageID: "rust",
      snippets: [
        LanguageSnippet(name: "println", text: "println!(\"{}\", value);"),
        LanguageSnippet(name: "test", text: "#[test]\nfn test_example() {\n    assert_eq!(1, 1);\n}\n"),
      ]),
  ]

  func reload() {
    var byID = Dictionary(Self.bundled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    if let files = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
          let pack = try? JSONDecoder().decode(SnippetPack.self, from: data),
          (try? validate(pack)) != nil
        else { continue }
        byID[pack.id] = pack
      }
    }
    packs = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func snippets(for languageID: String) -> [LanguageSnippet] {
    packs.filter { $0.languageID == languageID }.flatMap(\.snippets)
  }

  func isUserInstalled(_ id: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(id + ".json").path)
  }

  func importPack(from url: URL) throws -> SnippetPack {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 1_048_576 else {
      throw TCodeError.message("Snippet pack exceeds the 1 MB limit.")
    }
    let pack = try JSONDecoder().decode(SnippetPack.self, from: Data(contentsOf: url))
    try validate(pack)
    try write(pack)
    reload()
    return pack
  }

  func remove(_ pack: SnippetPack) throws {
    guard isUserInstalled(pack.id) else {
      throw TCodeError.message("Bundled snippet packs cannot be removed.")
    }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(pack.id + ".json"))
    reload()
  }

  private func write(_ pack: SnippetPack) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(pack).write(
      to: directory.appendingPathComponent(pack.id + ".json"), options: .atomic)
  }

  private func validate(_ pack: SnippetPack) throws {
    let identifier = #"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$"#
    guard pack.id.range(of: identifier, options: .regularExpression) != nil,
      !pack.name.isEmpty, pack.name.count <= 120, !pack.version.isEmpty,
      !pack.languageID.isEmpty, pack.languageID.count <= 80, pack.snippets.count <= 200
    else {
      throw TCodeError.message("A snippet pack needs a valid id, name, version, and language.")
    }
    for snippet in pack.snippets {
      guard !snippet.name.isEmpty, snippet.name.count <= 120, snippet.text.utf8.count <= 65_536 else {
        throw TCodeError.message("Invalid snippet in \(pack.name).")
      }
    }
  }
}
