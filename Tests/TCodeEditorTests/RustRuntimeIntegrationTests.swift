import AppKit
import TCodeCore
import XCTest

@testable import TCode

/// Exercises the native application's installed-pack, editor, LSP, and task wiring with actual Rust tools.
final class RustRuntimeIntegrationTests: XCTestCase {
  @MainActor private func waitFor(
    _ description: String, timeout: TimeInterval = 30, _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else {
        throw TCodeError.message("Timed out waiting for \(description).")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func healthyTool(_ name: String) async throws -> String {
    guard let path = ToolLocator.find(name),
      (await ToolHealth.check(executable: path)).isHealthy
    else {
      throw XCTSkip("A working external \(name) is required for the native Rust integration case.")
    }
    return path
  }

  private func rustAnalyzer(root: URL) async throws -> String {
    if let path = ToolLocator.find("rust-analyzer"),
      (await ToolHealth.check(executable: path)).isHealthy
    {
      return path
    }
    let installer = ToolInstaller(
      directory: root.appendingPathComponent("managed-tools"), preferExistingTools: false)
    let plan = try await installer.plan(recipeID: "rust-analyzer")
    guard plan.canInstall else {
      throw XCTSkip(plan.prerequisites.map(\.detail).joined(separator: "\n"))
    }
    let receipt = try await installer.install(plan, approval: { _ in true })
    return try XCTUnwrap(receipt.executables["rust-analyzer"])
  }

  @MainActor private func cleanup(_ workspace: WorkspaceWindow, document: CodeDocument) async {
    document.recoveryTask?.cancel()
    document.autosaveTask?.cancel()
    await workspace.shutdown()
    for pane in workspace.panes { pane.detach() }
    workspace.window?.orderOut(nil)
    DocumentPool.shared.documents.removeAll { $0 === document }
    try? await CodeDocument.recovery.remove(document.id)
  }

  @MainActor func testImportedRustPackDrivesNativeLanguageEditorAndCargoWorkflows() async throws {
    guard ProcessInfo.processInfo.environment["TCODE_INTEGRATION"] == "1" else {
      throw XCTSkip(
        "Set TCODE_INTEGRATION=1 to validate the real native Rust application workflow.")
    }
    _ = try await healthyTool("cargo")
    _ = try await healthyTool("rustc")
    _ = try await healthyTool("rustfmt")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode native Rust 😀 " + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let analyzer = try await rustAnalyzer(root: root)
    let source = """
      fn greet(value:i32)->i32{value+1}
      fn main(){let _message="👩🏽‍💻";let answer=greet(41);println!("{answer}");}
      #[cfg(test)]
      mod tests{use super::*;#[test]fn answer_test(){assert_eq!(greet(41),42);}}

      """
    let file = root.appendingPathComponent("src/main.rs")
    try Data(source.utf8).write(to: file)
    try Data("[package]\nname=\"tcode_native_rust\"\nversion=\"0.1.0\"\nedition=\"2021\"\n".utf8)
      .write(to: root.appendingPathComponent("Cargo.toml"))
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let packBytes = try Data(
      contentsOf: repository.appendingPathComponent(
        "Sources/TCode/Resources/CatalogPacks/rust.json"))
    let registry = LanguagePackRegistry(
      directory: root.appendingPathComponent("packs"), bundledPacks: LanguagePack.bundled())
    XCTAssertFalse(registry.packs.contains { $0.id == "rust" }, "Rust starts as on-demand support.")
    let imported = try registry.importPack(data: packBytes)
    XCTAssertEqual(imported.id, "rust")

    let preferenceKeys = ["tool.rust-analyzer", "disabled.rust", "autosave"]
    let previous = Dictionary(
      uniqueKeysWithValues: preferenceKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
    defer {
      for key in preferenceKeys {
        if let value = previous[key] ?? nil {
          UserDefaults.standard.set(value, forKey: key)
        } else {
          UserDefaults.standard.removeObject(forKey: key)
        }
      }
      for prefix in ["tabs.", "layout.", "watches.", "workspaceLanguagePacks.", "tCode.frame."] {
        UserDefaults.standard.removeObject(forKey: prefix + root.path)
      }
    }
    UserDefaults.standard.set(analyzer, forKey: "tool.rust-analyzer")
    UserDefaults.standard.set(false, forKey: "disabled.rust")
    UserDefaults.standard.set(false, forKey: "autosave")
    _ = NSApplication.shared
    let workspace = WorkspaceWindow(root: nil)
    workspace.root = root
    workspace.workspaceRegistry = registry
    workspace.configuration.environment = [
      "CARGO_NET_OFFLINE": "true", "CARGO_HOME": root.appendingPathComponent(".cargo").path,
      "CARGO_TARGET_DIR": root.appendingPathComponent("target").path,
    ]
    let document = CodeDocument(url: file, file: try TextFile(data: Data(source.utf8)))
    DocumentPool.shared.documents.append(document)
    workspace.add(document)
    workspace.addPane(document)
    document.undo.groupsByEvent = false
    do {
      XCTAssertEqual(document.languagePackID, "rust")
      XCTAssertEqual(document.languageID, "rust")
      XCTAssertEqual(document.grammarID, "rust")
      XCTAssertTrue(workspace.panes.allSatisfy { $0.editor.comment == "//" })
      try await Task.sleep(for: .milliseconds(200))
      XCTAssertFalse(workspace.languageEnabled)
      XCTAssertTrue(
        workspace.services.isEmpty, "Importing and recognizing the pack must not start a tool.")
      XCTAssertNil(document.languageSession)

      workspace.perform("enableLanguages")
      try await waitFor("the native Rust LanguageSession") {
        workspace.services["rust"]?.ready == true && document.languageSession != nil
      }
      let session = try XCTUnwrap(document.languageSession)
      XCTAssertEqual(
        session.pack, imported,
        "The app must use the imported pack, including its initialization settings.")
      XCTAssertTrue(session.supports("completion"))
      XCTAssertTrue(session.supports("definition"))
      let usage = (source as NSString).range(of: "greet(41)")
      var definitions: [[String: Any]] = []
      var completions: [[String: Any]] = []
      let indexedDeadline = Date().addingTimeInterval(30)
      repeat {
        if let value = try? await session.request(
          "definition", document: document, offset: usage.location + 2)
        {
          definitions = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
        }
        if let value = try? await session.request(
          "completion", document: document, offset: usage.location + 3)
        {
          completions =
            value as? [[String: Any]] ?? (value as? [String: Any])?["items"] as? [[String: Any]]
            ?? []
        }
        if !definitions.isEmpty
          && completions.contains(where: { ($0["label"] as? String)?.contains("greet") == true })
        {
          break
        }
        try await Task.sleep(for: .milliseconds(250))
      } while Date() < indexedDeadline
      XCTAssertFalse(
        definitions.isEmpty, "The native LanguageSession must return a real function definition.")
      XCTAssertTrue(
        definitions.contains { location in
          let uri = (location["uri"] ?? location["targetUri"]) as? String ?? ""
          let range = (location["range"] ?? location["targetSelectionRange"]) as? [String: Any]
          let line = (range?["start"] as? [String: Int])?["line"]
          return URL(string: uri)?.path.hasSuffix("/src/main.rs") == true && line == 0
        },
        "The definition must resolve to the local greet function before the emoji-containing use site."
      )
      XCTAssertTrue(completions.contains { ($0["label"] as? String)?.contains("greet") == true })

      let editor = try XCTUnwrap(workspace.editor)
      editor.replace(
        NSRange(location: document.storage.length, length: 0), with: "\nfn broken( {\n",
        action: "Insert syntax error")
      try await waitFor("Rust diagnostics in the native Problems panel") {
        !(workspace.diagnosticList[file.absoluteString] ?? []).isEmpty
          && !workspace.problems.string.contains("No problems detected.")
      }
      let diagnosticCount = workspace.diagnosticList[file.absoluteString]?.count ?? 0
      XCTAssertTrue(workspace.problems.string.contains("main.rs:"))
      workspace.perform("undo")
      XCTAssertEqual(document.text, source)
      try await waitFor("Rust syntax diagnostics to clear after undo") {
        (workspace.diagnosticList[file.absoluteString] ?? []).isEmpty
      }

      workspace.formatDocument()
      try await waitFor("native rustfmt formatting") { document.text != source }
      let formatted = document.text
      XCTAssertTrue(formatted.contains("fn greet(value: i32) -> i32"), formatted)
      XCTAssertTrue(formatted.contains("👩🏽‍💻"))
      XCTAssertTrue(workspace.panes.allSatisfy { $0.editor.string == formatted })
      workspace.perform("undo")
      XCTAssertEqual(document.text, source)
      XCTAssertTrue(workspace.panes.allSatisfy { $0.editor.string == source })
      workspace.perform("redo")
      XCTAssertEqual(document.text, formatted)
      workspace.perform("undo")
      XCTAssertEqual(document.text, source)
      XCTAssertFalse(
        document.modified, "Undoing formatting must restore the saved buffer before task routing.")

      for action in ["build", "run", "test"] {
        workspace.runTask(action)
        XCTAssertNotNil(
          workspace.taskHandle, "The selected Rust pack must route \(action) to Cargo.")
        try await waitFor("native Cargo \(action)") { workspace.taskHandle == nil }
        XCTAssertTrue(workspace.status.stringValue.contains("completed"), workspace.output.string)
      }
      XCTAssertTrue(
        workspace.output.string.components(separatedBy: .newlines).contains("42"),
        workspace.output.string)
      XCTAssertTrue(
        workspace.navigator?.rows.contains { $0.contains("PASSED") && $0.contains("answer_test") }
          == true,
        workspace.navigator?.rows.joined(separator: "\n") ?? workspace.output.string)
      print(
        "VERIFIED native Rust: on-demand JSON import; tools off until enabled; LanguageSession definition=\(definitions.count), completion=\(completions.count), diagnostics=\(diagnosticCount); shared split rustfmt undo/redo; Cargo build/run42/test and PASSED navigator row"
      )
    } catch {
      print(
        "Native Rust workflow output:\n\(workspace.output.string)\nStatus: \(workspace.status.stringValue)"
      )
      await cleanup(workspace, document: document)
      throw error
    }
    await cleanup(workspace, document: document)
  }
}
