import XCTest

@testable import TCodeCore

final class CoreTests: XCTestCase {
  func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func testUnicodeAndLineEndingsRoundTrip() throws {
    for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
      let prefix =
        encoding == .utf8
        ? Data([0xEF, 0xBB, 0xBF])
        : encoding == .utf16LittleEndian ? Data([0xFF, 0xFE]) : Data([0xFE, 0xFF])
      let text = "let café = \"👩🏽‍💻e\u{301}\"\r\n\t第二行\r\n"
      let bytes = prefix + text.data(using: encoding)!
      let file = try TextFile(data: bytes)
      XCTAssertEqual(try file.encode(file.text), bytes)
      XCTAssertEqual(file.lineEnding, "CRLF")
    }
    XCTAssertThrowsError(try TextFile(data: Data([0, 1, 2, 3])))
  }
  func testPositionsAcrossUnicodeEncodings() {
    let text = "a👩🏽‍💻e\u{301}\n第二行\n"
    let ns = text as NSString
    for encoding in ["utf-8", "utf-16", "utf-32"] {
      var offset = 0
      for scalar in text.unicodeScalars {
        let p = PositionMap.position(in: text, utf16Offset: offset, encoding: encoding)
        XCTAssertEqual(PositionMap.offset(in: text, position: p, encoding: encoding), offset)
        offset += scalar.utf16.count
      }
      XCTAssertEqual(
        PositionMap.offset(
          in: text, position: Position(line: 100, character: 0), encoding: encoding), ns.length)
    }
  }
  func testCRAndCRLFNavigation() {
    for separator in ["\n", "\r", "\r\n"] {
      let text = "first" + separator + "👩🏽‍💻second" + separator
      let offset = 5 + separator.utf16.count
      XCTAssertEqual(
        PositionMap.position(in: text, utf16Offset: offset), Position(line: 1, character: 0))
      XCTAssertEqual(
        PositionMap.offset(in: text, position: Position(line: 1, character: 0)), offset)
      XCTAssertEqual(
        PositionMap.offset(in: text, position: Position(line: 2, character: 0)), text.utf16.count)
    }
  }
  func testFilesystemCollisionsRenameAndSymlinkSave() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try FileIO.create(in: root, name: "Sources", directory: true)
    let file = try FileIO.create(in: folder, name: "hello.swift", directory: false)
    XCTAssertThrowsError(try FileIO.create(in: folder, name: "hello.swift", directory: false))
    XCTAssertThrowsError(try FileIO.validate("../outside"))
    let moved = try FileIO.move(file, into: root, name: "main.swift")
    let link = root.appendingPathComponent("alias.swift")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
    try FileIO.save(Data("hello".utf8), to: link, expected: Data())
    XCTAssertEqual(try Data(contentsOf: moved), Data("hello".utf8))
    XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    XCTAssertThrowsError(try FileIO.move(folder, into: folder, name: "nested"))
  }
  func testExternalConflictDoesNotOverwrite() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file.txt")
    try Data("external".utf8).write(to: file)
    XCTAssertThrowsError(try FileIO.save(Data("mine".utf8), to: file, expected: Data("old".utf8)))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
  }
  func testRecoveryPersistsBaselineAndOriginalEncoding() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directory: root)
    let record = RecoveryRecord(
      id: UUID(), path: "/file.py", text: "👩🏽‍💻 unsaved", baseline: Data("saved".utf8),
      encoding: String.Encoding.utf16LittleEndian.rawValue, bom: Data([255, 254]))
    try await store.write(record)
    let records = try await store.read()
    XCTAssertEqual(records.first?.text, record.text)
    XCTAssertEqual(records.first?.baseline, record.baseline)
    XCTAssertEqual(records.first?.bom, record.bom)
    try await store.remove(record.id)
    let remaining = try await store.read()
    XCTAssertTrue(remaining.isEmpty)
  }
  func testFramingFragmentedCombinedUnicodeAndMalformed() throws {
    let one = try MessageFramer.encode(["id": 1, "result": "😀"])
    let two = try MessageFramer.encode(["id": 2, "result": [1, 2]])
    var f = MessageFramer()
    var result: [[String: Any]] = []
    for byte in one + two { result += try f.append(Data([byte])) }
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0]["result"] as? String, "😀")
    var bad = MessageFramer()
    XCTAssertThrowsError(try bad.append(Data("Content-Length: -1\r\n\r\n".utf8)))
    var combined = MessageFramer()
    XCTAssertEqual(try combined.append(one + two).count, 2)
  }
  func testSearchPreviewRejectsExternalModification() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("main.py")
    try Data("answer = 42\nprint(answer)\n".utf8).write(to: file)
    let ignored = try FileIO.create(in: root, name: "node_modules", directory: true)
    try Data("answer".utf8).write(to: ignored.appendingPathComponent("ignore.py"))
    XCTAssertEqual(try WorkspaceSearch.find(root: root, pattern: "answer", regex: false).count, 2)
    let plan = try WorkspaceSearch.replacements(
      root: root, pattern: "answer", replacement: "value", regex: false)
    try Data("external".utf8).write(to: file)
    XCTAssertThrowsError(try WorkspaceSearch.apply(plan))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
    try plan[0].before.write(to: file)
    try WorkspaceSearch.apply(plan)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "value = 42\nprint(value)\n")
  }
  func testProcessOutputExitAndCancellation() async throws {
    let result = try await RunningProcess().run(
      executable: "/usr/bin/printf", arguments: ["hello 😀\n"], directory: nil)
    XCTAssertEqual(result.output, "hello 😀\n")
    XCTAssertEqual(result.status, 0)
    let process = RunningProcess()
    let start = Date()
    let task = Task {
      try await process.run(executable: "/bin/sleep", arguments: ["20"], directory: nil)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    _ = try? await task.value
    XCTAssertLessThan(Date().timeIntervalSince(start), 3)
  }
  func testCancellationCleansUpChildProcessGroup() async throws {
    let process = RunningProcess()
    let start = Date()
    let task = Task {
      try await process.run(
        executable: "/bin/sh", arguments: ["-c", "sleep 20 & wait"], directory: nil)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    _ = try? await task.value
    XCTAssertLessThan(
      Date().timeIntervalSince(start), 3,
      "Descendants must release the output pipes after cancellation.")
  }
  func testActualGitStageCommitAndStatus() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await Git.run(root, ["init", "-b", "main"])
    _ = try await Git.run(root, ["config", "user.name", "tCode Tests"])
    _ = try await Git.run(root, ["config", "user.email", "tests@example.invalid"])
    let file = root.appendingPathComponent("space name.py")
    try Data("answer = 42\n".utf8).write(to: file)
    let before = try await Git.status(root)
    XCTAssertEqual(before.first?.path, "space name.py")
    _ = try await Git.run(root, ["add", "--", "space name.py"])
    _ = try await Git.run(root, ["commit", "-m", "Initial test"])
    let after = try await Git.status(root)
    XCTAssertTrue(after.isEmpty)
  }
  func testNativeTestResultNavigationFormats() {
    let python = TestReports.parse("test_main.py::test_answer PASSED [100%]\n", runner: "pytest")
    XCTAssertEqual(python.first?.path, "test_main.py")
    XCTAssertEqual(python.first?.symbol, "test_answer")
    XCTAssertEqual(python.first?.status, "PASSED")
    let swift = TestReports.parse(
      "SampleTests.SampleTests/testAnswer\nTest Case '-[SampleTests.SampleTests testAnswer]' passed (0.001 seconds).",
      runner: "swift")
    XCTAssertEqual(swift.count, 2)
    XCTAssertEqual(swift.last?.symbol, "testAnswer")
    XCTAssertEqual(swift.last?.status, "PASSED")
    let ctest = TestReports.parse(
      "  Test #1: answer\n1/1 Test #1: answer ........ Passed 0.01 sec", runner: "ctest")
    XCTAssertEqual(ctest.count, 2)
    XCTAssertEqual(ctest.last?.name, "answer")
    XCTAssertEqual(ctest.last?.status, "PASSED")
  }
  func testProtocolCancellationAndToolFailure() async throws {
    let slow = ProtocolConnection(kind: .lsp)
    try await slow.start(
      path: "/usr/bin/python3", arguments: ["-c", "import time; time.sleep(20)"])
    let task = Task { try await slow.request("initialize", timeout: 10) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled request should fail")
    } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    await slow.stop()
    let dead = ProtocolConnection(kind: .lsp)
    try await dead.start(path: "/usr/bin/false")
    do {
      _ = try await dead.request("initialize", timeout: 2)
      XCTFail("A dead tool must fail pending requests")
    } catch {}
    await dead.stop()
  }
  func testMeasuredProjectSearch() throws {
    guard let path = ProcessInfo.processInfo.environment["TCODE_SEARCH_METRICS"] else {
      throw XCTSkip("Set TCODE_SEARCH_METRICS for hardware measurements.")
    }
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = String(repeating: "let answer = 42 // tCode benchmark\n", count: 60)
    for index in 0..<1000 {
      let folder = root.appendingPathComponent("Sources\(index/100)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: folder.appendingPathComponent("File\(index).swift"))
    }
    let ignored = root.appendingPathComponent("node_modules")
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    for i in 0..<100 {
      try Data(text.utf8).write(to: ignored.appendingPathComponent("Ignored\(i).swift"))
    }
    var started = Date()
    let children = try FileIO.children(root)
    let lazyMS = Date().timeIntervalSince(started) * 1000
    started = Date()
    let indexed = try FileIO.indexedFiles(root)
    let indexMS = Date().timeIntervalSince(started) * 1000
    started = Date()
    let hits = try WorkspaceSearch.find(
      root: root, pattern: "benchmark", regex: false, limit: 100000)
    let searchMS = Date().timeIntervalSince(started) * 1000
    let metric: [String: Any] = [
      "source_files": 1000, "source_bytes": text.utf8.count * 1000, "ignored_files": 100,
      "root_children": children.count, "indexed_files": indexed.count, "hits": hits.count,
      "lazy_root_listing_ms": lazyMS, "index_ms": indexMS, "search_ms": searchMS,
    ]
    try JSONSerialization.data(withJSONObject: metric, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path))
    XCTAssertEqual(indexed.count, 1000)
    XCTAssertEqual(hits.count, 60000)
  }
}
