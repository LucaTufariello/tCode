import AppKit
import TCodeCore
import XCTest

@testable import TCode

final class LanguageRuntimeTests: XCTestCase {
  func testBundledMigrationAndRustCatalogRemainSeparate() throws {
    let bundled = LanguagePack.bundled()
    XCTAssertEqual(Set(bundled.map(\.id)), ["python", "cpp", "swift"])
    XCTAssertTrue(bundled.allSatisfy { $0.interfaceVersion == 2 })
    XCTAssertTrue(
      bundled.first { $0.id == "python" }?.tasks["test"]?.steps.first?.arguments.contains("pytest")
        == true)
    XCTAssertTrue(
      bundled.first { $0.id == "cpp" }?.associations.contains { $0.languageID == "c" } == true)
    XCTAssertTrue(LanguageCatalog.starter.entries.contains { $0.id == "rust" })
  }

  @MainActor func testDocumentOverridesUpdateCommentsAndSharedPanesWithoutStartingTools() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let window = WorkspaceWindow(root: nil)
    window.workspaceRegistry = LanguagePackRegistry(
      directory: root, bundledPacks: LanguagePack.bundled() + [.rust])
    let doc = CodeDocument(
      url: root.appendingPathComponent("shared.h"),
      file: try TextFile(data: Data("int answer = 42;\n".utf8)))
    window.add(doc)
    XCTAssertNil(doc.languageID, "A .h header must not silently choose between C and C++.")
    XCTAssertEqual(window.editor?.comment, "")
    doc.languageOverride = "cpp:c"
    window.configureLanguage(doc)
    XCTAssertEqual(doc.languageID, "c")
    XCTAssertEqual(doc.grammarID, "c")
    XCTAssertEqual(window.editor?.comment, "//")
    window.addPane(doc)
    XCTAssertTrue(window.panes.allSatisfy { $0.document === doc && $0.editor.comment == "//" })
    doc.languageOverride = "python:python"
    window.configureLanguage(doc)
    XCTAssertTrue(window.panes.allSatisfy { $0.editor.comment == "#" })
    XCTAssertEqual(doc.languageID, "python")
    XCTAssertTrue(window.services.isEmpty)
    XCTAssertFalse(window.languageEnabled)
    doc.languageOverride = "text"
    window.configureLanguage(doc)
    XCTAssertNil(doc.grammarID)
    XCTAssertNil(doc.languageID)
    XCTAssertTrue(window.panes.allSatisfy { $0.editor.comment.isEmpty })
    window.cleanup()
    doc.recoveryTask?.cancel()
  }

  func testExternalPackDrivesFormatterAndSharedUndo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = LanguagePack(
      id: "upper", name: "Uppercase fixture",
      associations: [.init(languageID: "upper", extensions: ["upper"])],
      editor: .init(lineComment: ";"),
      formatterCommand: .init(executable: "/usr/bin/tr", arguments: ["a-z", "A-Z"]))
    let registry = LanguagePackRegistry(
      directory: root.appendingPathComponent("packs"), bundledPacks: [])
    _ = try registry.importPack(data: JSONEncoder().encode(pack))
    let (doc, window) = try await MainActor.run {
      _ = NSApplication.shared
      let doc = CodeDocument(
        url: root.appendingPathComponent("name with spaces;literal.upper"),
        file: try TextFile(data: Data("hello 👩🏽‍💻\r\n".utf8)))
      let window = WorkspaceWindow(root: nil)
      window.workspaceRegistry = registry
      window.add(doc)
      window.addPane(doc)
      doc.undo.groupsByEvent = false
      window.formatDocument()
      return (doc, window)
    }
    let deadline = Date().addingTimeInterval(5)
    while await MainActor.run(body: { doc.text != "HELLO 👩🏽‍💻\r\n" }) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    await MainActor.run {
      XCTAssertEqual(doc.text, "HELLO 👩🏽‍💻\r\n")
      XCTAssertTrue(window.panes.allSatisfy { $0.editor.string == doc.text })
      window.perform("undo")
      XCTAssertEqual(doc.text, "hello 👩🏽‍💻\r\n")
      XCTAssertTrue(window.services.isEmpty)
      doc.recoveryTask?.cancel()
      window.cleanup()
    }
  }

  func testExternalPackRunsSequentialTasksAndCancels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = LanguagePack(
      id: "taskfixture", name: "Task fixture",
      associations: [.init(languageID: "taskfixture", extensions: ["taskfixture"])],
      tasks: [
        "build": .init(steps: [
          .init(executable: "/usr/bin/printf", arguments: ["first step\\n"]),
          .init(executable: "/usr/bin/printf", arguments: ["second step\\n"]),
        ]),
        "test": .init(steps: [.init(executable: "/bin/sleep", arguments: ["10"])]),
      ])
    let (window, doc) = try await MainActor.run {
      _ = NSApplication.shared
      let window = WorkspaceWindow(root: nil)
      window.root = root
      window.workspaceRegistry = LanguagePackRegistry(
        directory: root.appendingPathComponent("packs"), bundledPacks: [pack])
      let doc = CodeDocument(
        url: root.appendingPathComponent("source.taskfixture"),
        file: try TextFile(data: Data("fixture\n".utf8)))
      window.add(doc)
      window.runTask("build")
      return (window, doc)
    }
    var deadline = Date().addingTimeInterval(5)
    while await MainActor.run(body: { window.taskHandle != nil }) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    await MainActor.run {
      XCTAssertNil(window.taskHandle)
      XCTAssertTrue(window.output.string.contains("first step\n"))
      XCTAssertTrue(window.output.string.contains("second step\n"))
      XCTAssertTrue(window.status.stringValue.contains("completed"))
      window.runTask("test")
    }
    try await Task.sleep(for: .milliseconds(100))
    await window.perform("cancel")
    deadline = Date().addingTimeInterval(3)
    while await MainActor.run(body: { window.taskHandle != nil }) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    await MainActor.run {
      XCTAssertNil(window.taskHandle)
      XCTAssertTrue(window.output.string.contains("cancelled"))
      window.cleanup()
      doc.recoveryTask?.cancel()
    }
    for prefix in ["tabs.", "layout."] {
      UserDefaults.standard.removeObject(forKey: prefix + root.path)
    }
  }
}
