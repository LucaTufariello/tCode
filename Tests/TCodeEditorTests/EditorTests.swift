import AppKit
import TCodeCore
import XCTest

@testable import TCode

@MainActor private final class DiagnosticSnapshot { var values: [[String: Any]] = [] }

final class EditorTests: XCTestCase {
  func testNativeUndoAndRedoCommandRouting() async throws {
    try await MainActor.run {
      _ = NSApplication.shared
      let doc = CodeDocument(file: try TextFile(data: Data("answer = 42\n".utf8)))
      let window = WorkspaceWindow(root: nil)
      window.add(doc)
      doc.undo.groupsByEvent = false
      doc.undo.beginUndoGrouping()
      window.editor?.insertText("# test\n", replacementRange: NSRange(location: 0, length: 0))
      doc.undo.endUndoGrouping()
      XCTAssertTrue(doc.modified)
      window.perform("undo")
      XCTAssertEqual(doc.text, "answer = 42\n")
      window.perform("redo")
      XCTAssertTrue(doc.text.hasPrefix("# test"))
      window.perform("undo")
      doc.recoveryTask?.cancel()
      window.cleanup()
    }
  }
  override func setUp() {
    super.setUp()
    setenv(
      "TCODE_RECOVERY_PATH",
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "tcode-editor-tests-\(ProcessInfo.processInfo.processIdentifier)"
      ).path, 1)
  }
  func testSplitEditorsShareTextAndUndo() async throws {
    try await MainActor.run {
      _ = NSApplication.shared
      let doc = CodeDocument(file: try TextFile(data: Data("let answer = 42\n".utf8)))
      let one = EditorPane(document: doc)
      let two = EditorPane(document: doc)
      _ = one.view
      _ = two.view
      doc.undo.groupsByEvent = false
      doc.undo.beginUndoGrouping()
      one.editor.replace(NSRange(location: 13, length: 2), with: "43", action: "Edit Answer")
      doc.undo.endUndoGrouping()
      XCTAssertEqual(two.editor.string, "let answer = 43\n")
      XCTAssertTrue(doc.modified)
      XCTAssertTrue(doc.undo.canUndo)
      doc.undo.undo()
      XCTAssertEqual(two.editor.string, "let answer = 42\n")
      XCTAssertFalse(doc.modified)
      doc.undo.redo()
      XCTAssertEqual(one.editor.string, two.editor.string)
      one.detach()
      two.detach()
    }
  }
  func testFoldingDoesNotModifySavedText() async throws {
    try await MainActor.run {
      let text = "func greet() {\n    print(42)\n}\n"
      let doc = CodeDocument(file: try TextFile(data: Data(text.utf8)))
      let pane = EditorPane(document: doc)
      _ = pane.view
      let lm = pane.editor.layoutManager as! FoldingLayoutManager
      lm.toggle(NSRange(location: 15, length: 14))
      lm.ensureLayout(for: pane.editor.textContainer!)
      XCTAssertEqual(doc.text, text)
      XCTAssertFalse(doc.modified)
      XCTAssertEqual(try doc.encoded(), Data(text.utf8))
      lm.toggle(NSRange(location: 0, length: 0))
      XCTAssertTrue(lm.folded.isEmpty)
      pane.detach()
    }
  }
  func testMultipleCursorsAndIMEFallback() async throws {
    try await MainActor.run {
      let doc = CodeDocument(file: try TextFile(data: Data("one\ntwo\n".utf8)))
      let pane = EditorPane(document: CodeDocument())
      let actual = EditorPane(document: doc)
      _ = actual.view
      actual.editor.setSelectedRange(NSRange(location: 0, length: 0))
      actual.editor.addCursorBelow(nil)
      doc.undo.beginUndoGrouping()
      actual.editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
      doc.undo.endUndoGrouping()
      XCTAssertEqual(doc.text, "Xone\nXtwo\n")
      XCTAssertEqual(actual.editor.additionalCursors.count, 1)
      actual.editor.setMarkedText(
        "あ", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(actual.editor.additionalCursors.isEmpty)
      actual.editor.unmarkText()
      actual.detach()
      _ = pane
    }
  }
  func testDocumentSaveRejectsExternalChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("main.py")
    let data = Data("answer = 42\r\n".utf8)
    try data.write(to: url)
    let doc = try await MainActor.run { CodeDocument(url: url, file: try TextFile(data: data)) }
    await MainActor.run {
      doc.storage.replaceCharacters(in: NSRange(location: 9, length: 2), with: "43")
    }
    try Data("external\n".utf8).write(to: url)
    do {
      try await doc.save(to: url)
      XCTFail("Conflicting save must fail")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: url), Data("external\n".utf8))
    await MainActor.run { doc.recoveryTask?.cancel() }
    try await CodeDocument.recovery.remove(doc.id)
  }
  func testCompletionAdditionalEditsShareOneUndoTransaction() async throws {
    try await MainActor.run {
      _ = NSApplication.shared
      let doc = CodeDocument(file: try TextFile(data: Data("pri\n".utf8)))
      let pane = EditorPane(document: CodeDocument())
      let actual = EditorPane(document: doc)
      _ = actual.view
      doc.undo.groupsByEvent = false
      let window = WorkspaceWindow(root: nil)
      let completion: [String: Any] = [
        "label": "print",
        "textEdit": [
          "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]],
          "newText": "print",
        ],
        "additionalTextEdits": [
          [
            "range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 0]],
            "newText": "# additional\n",
          ]
        ],
      ]
      try window.applyCompletion(
        completion, editor: actual.editor, document: doc,
        selection: NSRange(location: 3, length: 0), encoding: "utf-16")
      XCTAssertEqual(doc.text, "print\n# additional\n")
      doc.undo.undo()
      XCTAssertEqual(doc.text, "pri\n")
      window.cleanup()
      actual.detach()
      _ = pane
    }
  }
  func testRealPythonDiagnosticsSurviveEmptyServerUpdateAndMapEmoji() async throws {
    guard ProcessInfo.processInfo.environment["TCODE_INTEGRATION"] == "1",
      ToolLocator.find("pylsp") != nil, ToolLocator.find("ruff") != nil
    else { throw XCTSkip("Set TCODE_INTEGRATION=1 and install Python tools.") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode-python-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("main.py")
    let text = "message = \"👩🏽‍💻\"; missing_name\n"
    try Data(text.utf8).write(to: url)
    let (session, document, snapshot) = try await MainActor.run {
      let pack = try XCTUnwrap(LanguagePack.discover().first(where: { $0.id == "python" }))
      let session = LanguageSession(pack: pack)
      let document = CodeDocument(url: url, file: try TextFile(data: Data(text.utf8)))
      let snapshot = DiagnosticSnapshot()
      session.diagnostics = { _, values in snapshot.values = values }
      DocumentPool.shared.documents.append(document)
      return (session, document, snapshot)
    }
    do {
      try await session.start(root: root)
      try await session.open(document)
      try await Task.sleep(for: .seconds(2))
      try await MainActor.run {
        let finding = try XCTUnwrap(
          snapshot.values.first(where: { ($0["message"] as? String)?.contains("F821") == true }))
        let range = try XCTUnwrap(finding["range"] as? [String: Any])
        XCTAssertEqual(
          PositionMap.range(in: text, json: range)?.location,
          (text as NSString).range(of: "missing_name").location)
        XCTAssertTrue(
          session.serverDiagnostics[url.absoluteString]?.isEmpty == true,
          "The real server's empty diagnostics must not clear Ruff findings.")
        session.close(document, url: url)
        XCTAssertTrue(
          snapshot.values.isEmpty, "Closing or moving a document must clear old-path diagnostics.")
      }
    } catch {
      await session.shutdown()
      throw error
    }
    await session.shutdown()
    await MainActor.run { DocumentPool.shared.documents.removeAll { $0 === document } }
  }
  func testMeasuredNativeTypingAndLargeFileLoad() async throws {
    guard let path = ProcessInfo.processInfo.environment["TCODE_EDITOR_METRICS"] else {
      throw XCTSkip("Set TCODE_EDITOR_METRICS for hardware measurements.")
    }
    let id = try await MainActor.run { () -> UUID in
      let text = String(repeating: "let answer = 42\n", count: 10000)
      let started = Date()
      let doc = CodeDocument(file: try TextFile(data: Data(text.utf8)))
      let pane = EditorPane(document: doc)
      _ = pane.view
      pane.editor.layoutManager?.ensureLayout(for: pane.editor.textContainer!)
      let loadMS = Date().timeIntervalSince(started) * 1000
      doc.undo.groupsByEvent = false
      var times: [Double] = []
      for _ in 0..<100 {
        doc.undo.beginUndoGrouping()
        let start = Date()
        pane.editor.insertText("x", replacementRange: NSRange(location: 20, length: 0))
        pane.editor.layoutManager?.ensureLayout(
          forBoundingRect: NSRect(x: 0, y: 0, width: 800, height: 600),
          in: pane.editor.textContainer!)
        times.append(Date().timeIntervalSince(start) * 1000)
        doc.undo.endUndoGrouping()
      }
      times.sort()
      let largeText = String(repeating: "let value = 42\n", count: 700000)
      let largeStart = Date()
      let large = CodeDocument(file: try TextFile(data: Data(largeText.utf8)))
      let largeMS = Date().timeIntervalSince(largeStart) * 1000
      let metric: [String: Any] = [
        "typing_dataset_bytes": text.utf8.count, "typing_dataset_lines": 10000,
        "native_text_insertions": 100, "typing_median_ms": times[50], "typing_p95_ms": times[95],
        "initial_full_layout_ms": loadMS, "large_file_bytes": largeText.utf8.count,
        "large_decode_and_storage_ms": largeMS, "large_mode_enabled": large.large,
        "measurement":
          "Synchronous NSTextView insertion plus visible-region layout; excludes display latency",
      ]
      try JSONSerialization.data(withJSONObject: metric, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path))
      doc.recoveryTask?.cancel()
      pane.detach()
      return doc.id
    }
    try await CodeDocument.recovery.remove(id)
  }
}
