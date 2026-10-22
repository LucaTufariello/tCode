import Foundation
import XCTest

@testable import TCodeCore

final class LanguagePackTests: XCTestCase {
  func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode-packs-" + UUID().uuidString
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func data(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
  func legacy(_ id: String) throws -> LanguagePack {
    let options: [String: ([String], String, String, String)] = [
      "python": (["py", "pyw"], "pylsp", "ruff", "debugpy"),
      "cpp": (["c", "h", "cc", "cpp", "hpp"], "clangd", "clang-format", "lldb-dap"),
      "swift": (["swift"], "sourcekit-lsp", "swift-format", "lldb-dap"),
    ]
    let row = try XCTUnwrap(options[id])
    return try LanguagePackRegistry.decode(
      data([
        "interfaceVersion": 1, "id": id, "name": id.capitalized, "extensions": row.0,
        "server": row.1, "serverArguments": [], "formatter": row.2, "adapter": row.3,
      ]))
  }
  func pack(_ id: String = "fixture", name: String = "Fixture") -> LanguagePack {
    LanguagePack(
      id: id, name: name,
      associations: [
        .init(
          languageID: id, extensions: ["fixture"], filenames: ["Fixturefile"],
          firstLinePattern: "^#!.*fixture")
      ], editor: .init(lineComment: "#"))
  }
  func testAllThreeVersionOnePacksMigrateAndVersionTwoRoundTrips() throws {
    for id in ["python", "cpp", "swift"] {
      let value = try legacy(id)
      XCTAssertEqual(value.interfaceVersion, 2)
      XCTAssertFalse(value.tasks.isEmpty)
      XCTAssertNotNil(value.languageServer)
      XCTAssertNotNil(value.debugger)
      XCTAssertNotNil(value.editor.lineComment)
      XCTAssertFalse(value.grammarIDs.isEmpty)
      let bytes = try value.portableData()
      XCTAssertEqual(try LanguagePackRegistry.decode(bytes), value)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      XCTAssertEqual(object["interfaceVersion"] as? Int, 2)
    }
    let cpp = try legacy("cpp")
    XCTAssertEqual(Set(cpp.associations.map(\.languageID)), ["c", "cpp"])
    let python = try legacy("python")
    XCTAssertEqual(
      python.formatterCommand?.arguments, ["format", "--stdin-filename", "${file}", "-"])
    XCTAssertEqual(python.diagnosticAdapter, "ruff")
    XCTAssertEqual(try LanguagePackRegistry.decode(LanguagePack.rust.portableData()), .rust)
  }
  func testRecognitionUppercaseSpecialFilenameShebangAndUnknownText() throws {
    let value = pack()
    XCTAssertEqual(
      LanguageRecognition.matches(
        packs: [value], url: URL(fileURLWithPath: "/tmp/HELLO.FIXTURE"), firstLine: ""
      ).first?.association.languageID, "fixture")
    XCTAssertEqual(
      LanguageRecognition.matches(
        packs: [value], url: URL(fileURLWithPath: "/tmp/Fixturefile"), firstLine: ""
      ).first?.score, 30)
    XCTAssertEqual(
      LanguageRecognition.matches(
        packs: [value], url: URL(fileURLWithPath: "/tmp/tool"), firstLine: "#!/usr/bin/env fixture"
      ).first?.score, 10)
    XCTAssertTrue(
      LanguageRecognition.matches(
        packs: [value], url: URL(fileURLWithPath: "/tmp/unknown.zzz"), firstLine: ""
      ).isEmpty)
    XCTAssertTrue(LanguageRecognition.matches(packs: [value], url: nil, firstLine: "").isEmpty)
    XCTAssertEqual(
      LanguageRecognition.matches(
        packs: [value], url: nil, firstLine: "", override: "fixture:fixture"
      ).count, 1)
  }
  func testAmbiguousHeaderNeedsManualOverrideAndPlainTextClearsLanguage() throws {
    let cpp = try legacy("cpp")
    let url = URL(fileURLWithPath: "/tmp/header.h")
    XCTAssertEqual(
      Set(LanguageRecognition.matches(packs: [cpp], url: url, firstLine: "").map(\.key)),
      ["cpp:c", "cpp:cpp"])
    XCTAssertEqual(
      LanguageRecognition.matches(packs: [cpp], url: url, firstLine: "", override: "cpp:c").map(
        \.key), ["cpp:c"])
    XCTAssertTrue(
      LanguageRecognition.matches(packs: [cpp], url: url, firstLine: "", override: "text").isEmpty)
    XCTAssertTrue(
      LanguageRecognition.matches(
        packs: [cpp], url: url, firstLine: "", override: "missing:language"
      ).isEmpty)
  }
  func testPathologicalFirstLinePatternsShareDeadlineAndPreserveFileAssociations() throws {
    var hostile = pack("pathological")
    hostile.associations = (0..<64).map {
      LanguageAssociation(languageID: "pathological\($0)", firstLinePattern: "(a+)+$")
    }
    try hostile.validate()
    let ordinary = pack()
    let packs = [hostile, ordinary]
    let line = String(repeating: "a", count: 1023) + "!"
    let clock = ContinuousClock()

    for filename in [nil, "sample.fixture", "Fixturefile"] {
      let start = clock.now
      let matches = LanguageRecognition.matches(
        packs: packs, url: filename.map { URL(fileURLWithPath: "/tmp/" + $0) }, firstLine: line)
      XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(250))
      XCTAssertEqual(matches.map(\.key), filename == nil ? [] : ["fixture:fixture"])
    }
    XCTAssertEqual(
      LanguageRecognition.matches(
        packs: [ordinary], url: nil, firstLine: "#!/usr/bin/env fixture"
      ).first?.score, 10)
  }
  func testCommandPlaceholderExpansionPreservesArgumentBoundaries() throws {
    let file = "/tmp/project with spaces/main;echo $HOME.py"
    let value = LanguageCommand(
      executable: "tool", arguments: ["--file", "${file}", "${workspace}/build"],
      workingDirectory: "${workspace}", environment: ["VALUE": "${fileStem}"])
    let command = try value.resolved([
      "file": file, "workspace": "/tmp/my project", "fileStem": "main;echo",
    ])
    XCTAssertEqual(command.arguments, ["--file", file, "/tmp/my project/build"])
    XCTAssertEqual(command.workingDirectory, "/tmp/my project")
    XCTAssertEqual(command.environment["VALUE"], "main;echo")
    XCTAssertThrowsError(try LanguageCommand.expand("${secret}", context: ["secret": "value"]))
    XCTAssertThrowsError(try LanguageCommand.expand("${file}", context: [:]))
  }
  func testInvalidSchemaIdentifiersRegexAndPlaceholdersAreRejected() throws {
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: pack().portableData()) as? [String: Any])
    object["interfaceVersion"] = 99
    XCTAssertThrowsError(try LanguagePackRegistry.decode(data(object)))
    object["interfaceVersion"] = 2
    object["id"] = "../outside"
    XCTAssertThrowsError(try LanguagePackRegistry.decode(data(object)))
    var value = pack()
    value.associations[0].firstLinePattern = "("
    XCTAssertThrowsError(try LanguagePackRegistry.decode(JSONEncoder().encode(value)))
    value = pack()
    value.languageServer = .init(command: .init(executable: "tool", arguments: ["${unknown}"]))
    XCTAssertThrowsError(try value.validate())
    XCTAssertThrowsError(try LanguagePackRegistry.decode(Data(repeating: 0x20, count: 1_048_577)))
  }
  func testRegistryRetainsLastWorkingPackForCorruptReplacement() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LanguagePackRegistry(directory: root, bundledPacks: [pack(name: "Bundled")])
    let custom = pack(name: "Custom")
    try registry.importPack(data: custom.portableData())
    try Data("{broken json".utf8).write(to: root.appendingPathComponent("fixture.json"))
    XCTAssertEqual(registry.reload().first?.name, "Custom")
    XCTAssertFalse(registry.issues.isEmpty)
    XCTAssertThrowsError(try registry.importPack(data: Data("{}".utf8), replace: true))
    XCTAssertEqual(registry.packs.first?.name, "Custom")
  }
  func testDuplicateReportingRemovalAndBundledFallback() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LanguagePackRegistry(directory: root, bundledPacks: [pack(name: "Bundled")])
    try registry.importPack(data: pack(name: "Custom").portableData())
    XCTAssertThrowsError(try registry.importPack(data: pack(name: "Other").portableData()))
    try pack(name: "Duplicate").portableData().write(
      to: root.appendingPathComponent("z-duplicate.json"))
    _ = registry.reload()
    XCTAssertTrue(registry.issues.contains { $0.message.contains("Duplicate") })
    try FileManager.default.removeItem(at: root.appendingPathComponent("z-duplicate.json"))
    try registry.removePack(id: "fixture")
    XCTAssertEqual(registry.packs.first?.name, "Bundled")
    XCTAssertThrowsError(try registry.removePack(id: "fixture"))
    XCTAssertThrowsError(try registry.removePack(id: "../escape"))
  }
  func testCorruptFallbackDoesNotOverrideAnEarlierValidDuplicate() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LanguagePackRegistry(directory: root, bundledPacks: [])
    try pack(name: "Original").portableData().write(
      to: root.appendingPathComponent("z-original.json"))
    _ = registry.reload()
    try pack(name: "Earlier").portableData().write(
      to: root.appendingPathComponent("a-earlier.json"))
    try Data("{corrupt".utf8).write(to: root.appendingPathComponent("z-original.json"))
    XCTAssertEqual(registry.reload().first?.name, "Earlier")
    XCTAssertFalse(registry.issues.isEmpty)
  }
  func testImportAndRemovePreserveExplicitWorkspaceContext() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("project")
    let overrides = workspace.appendingPathComponent(".tcode/languages")
    try FileManager.default.createDirectory(at: overrides, withIntermediateDirectories: true)
    try pack(name: "Workspace").portableData().write(
      to: overrides.appendingPathComponent("fixture.json"))
    let registry = LanguagePackRegistry(
      directory: root.appendingPathComponent("user"), bundledPacks: [pack(name: "Bundled")])
    _ = registry.reload(workspace: workspace, allowWorkspacePacks: true)
    try registry.importPack(data: pack("second").portableData())
    XCTAssertEqual(registry.packs.first { $0.id == "fixture" }?.name, "Workspace")
    try registry.removePack(id: "second")
    XCTAssertEqual(registry.packs.first?.name, "Workspace")
  }
  func testOversizedReplacementRetainsLastGoodWithoutReadingWholeFile() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LanguagePackRegistry(directory: root, bundledPacks: [pack(name: "Bundled")])
    try registry.importPack(data: pack(name: "Custom").portableData())
    let file = root.appendingPathComponent("fixture.json")
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 128 * 1_024 * 1_024)
    try handle.close()
    XCTAssertEqual(registry.reload().first?.name, "Custom")
    XCTAssertTrue(registry.issues.contains { $0.message.contains("1 MB") })
  }
  func testVersionedHistoryRecoversAfterRestartAndRemovalPreventsResurrection() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = pack(name: "Bundled")
    let registry = LanguagePackRegistry(directory: root, bundledPacks: [bundled])
    try registry.importPack(data: pack(name: "First").portableData())
    var second = pack(name: "Second")
    second.version = "2.0.0"
    try registry.importPack(data: second.portableData(), replace: true)
    let history = root.appendingPathComponent("versions/fixture")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, 3)
    let active = root.appendingPathComponent("fixture.json")
    try Data("{broken active configuration".utf8).write(to: active)
    let restarted = LanguagePackRegistry(directory: root, bundledPacks: [bundled])
    XCTAssertEqual(restarted.packs.first?.name, "Second")
    XCTAssertFalse(restarted.issues.isEmpty)
    try restarted.removePack(id: "fixture")
    XCTAssertEqual(restarted.packs.first?.name, "Bundled")
    XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
    try Data("{still broken".utf8).write(to: active)
    XCTAssertEqual(
      LanguagePackRegistry(directory: root, bundledPacks: [bundled]).packs.first?.name, "Bundled")
  }
  func testHistoryRetentionIsBoundedAndRemovalRetainsUnownedFiles() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LanguagePackRegistry(directory: root, bundledPacks: [])
    for index in 0..<20 {
      var value = pack(name: "Revision \(index)")
      value.version = "1.0.\(index)"
      try registry.importPack(data: value.portableData(), replace: index > 0)
    }
    let history = root.appendingPathComponent("versions/fixture")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, 17)
    let unowned = history.appendingPathComponent("my-notes")
    try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
    let note = unowned.appendingPathComponent("notes.txt")
    try Data("Unowned data".utf8).write(to: note)
    try registry.removePack(id: "fixture")
    XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path), ["my-notes"])
  }
  func testHistoryChecksumRejectsModifiedBackup() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = pack(name: "Bundled")
    let registry = LanguagePackRegistry(directory: root, bundledPacks: [bundled])
    try registry.importPack(data: pack(name: "Original").portableData())
    let history = root.appendingPathComponent("versions/fixture")
    let version = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).first {
        $0.lastPathComponent != "active.json"
      })
    try pack(name: "Tampered").portableData().write(to: version.appendingPathComponent("pack.json"))
    try Data("{corrupt".utf8).write(to: root.appendingPathComponent("fixture.json"))
    let restarted = LanguagePackRegistry(directory: root, bundledPacks: [bundled])
    XCTAssertEqual(restarted.packs.first?.name, "Bundled")
    XCTAssertFalse(restarted.issues.isEmpty)
  }
  func testWorkspaceOverridesRequireExplicitEnableAndNeverLeakIntoOtherWorkspace() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let user = root.appendingPathComponent("user")
    let workspace = root.appendingPathComponent("project")
    let overrides = workspace.appendingPathComponent(".tcode/languages")
    try FileManager.default.createDirectory(at: overrides, withIntermediateDirectories: true)
    try pack(name: "Workspace").portableData().write(
      to: overrides.appendingPathComponent("fixture.json"))
    let registry = LanguagePackRegistry(directory: user, bundledPacks: [pack(name: "Bundled")])
    XCTAssertEqual(registry.reload(workspace: workspace).first?.name, "Bundled")
    XCTAssertEqual(
      registry.reload(workspace: workspace, allowWorkspacePacks: true).first?.name, "Workspace")
    XCTAssertEqual(registry.reload().first?.name, "Bundled")
    XCTAssertEqual(
      registry.reload(workspace: root.appendingPathComponent("other"), allowWorkspacePacks: true)
        .first?.name, "Bundled")
  }
  func testImportDoesNotExecuteConfiguredTools() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("should-not-exist")
    var value = pack()
    value.languageServer = .init(
      command: .init(executable: "/usr/bin/touch", arguments: [marker.path]))
    let registry = LanguagePackRegistry(
      directory: root.appendingPathComponent("packs"), bundledPacks: [])
    try registry.importPack(data: JSONEncoder().encode(value))
    _ = registry.reload()
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(registry.packs.first?.languageServer?.command.executable, "/usr/bin/touch")
  }
  func testPortableExportRejectsLocalPathsAndPrivateEnvironment() throws {
    var value = pack()
    value.languageServer = .init(command: .init(executable: "/Users/private/bin/tool"))
    XCTAssertThrowsError(try value.portableData())
    value.languageServer = .init(
      command: .init(executable: "tool", environment: ["API_KEY": "private"]))
    XCTAssertThrowsError(try value.portableData())
    value.languageServer = .init(
      command: .init(executable: "tool", workingDirectory: "/Users/private/project"))
    XCTAssertThrowsError(try value.portableData())
    value.languageServer = nil
    value.tasks["test"] = .init(steps: [
      .init(executable: "tool", environment: ["TOKEN": "private"])
    ])
    XCTAssertThrowsError(try value.portableData())
    value.tasks = [:]
    XCTAssertEqual(try LanguagePackRegistry.decode(value.portableData()), value)
  }
}
