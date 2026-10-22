import Foundation
import TCodeCore
import XCTest

@testable import TCodeSyntax

final class SyntaxTests: XCTestCase {
  func testDescriptorValidationAndArm64Integrity() throws {
    let descriptor = SyntaxGrammarDescriptor(
      id: "rust", version: "0.24.0", symbol: "tree_sitter_rust",
      moduleSHA256: String(repeating: "a", count: 64),
      querySHA256: String(repeating: "b", count: 64),
      sourceRevision: "fixture", abi: 15)
    XCTAssertNoThrow(try descriptor.validate())
    XCTAssertThrowsError(
      try SyntaxIntegrity.validateModule(Data(repeating: 0, count: 32), descriptor: descriptor))
  }
  func testSizeGuardDoesNotLoadGrammar() throws {
    let descriptor = SyntaxGrammarDescriptor(
      id: "rust", version: "0.24.0", symbol: "tree_sitter_rust",
      moduleSHA256: String(repeating: "a", count: 64),
      querySHA256: String(repeating: "b", count: 64),
      sourceRevision: "fixture", abi: 15)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let parser = try NativeSyntaxParser(moduleDirectory: temporary)
    XCTAssertThrowsError(
      try parser.highlight(
        SyntaxRequest(
          documentID: UUID(), version: 1,
          text: String(repeating: "a", count: 2_000_001), grammar: descriptor, moduleData: nil,
          queryData: nil))
    ) { error in
      guard case SyntaxFailure.tooLarge = error else {
        return XCTFail("Expected size cutoff, got \(error)")
      }
    }
  }
  func testUnicodeIncrementalEditCoordinates() {
    let old = Array("// 👩🏽‍💻\r\nlet café = 42\r\n".utf8)
    let new = Array("// 👨🏽‍💻\r\nlet cafe\u{301} = 420\r\n".utf8)
    let edit = NativeSyntaxParser.edit(from: old, to: new)
    XCTAssertEqual(edit.start_point.row, 0)
    XCTAssertEqual(edit.new_end_point.row, 1)
    XCTAssertLessThan(edit.start_byte, edit.old_end_byte)
    XCTAssertEqual(edit.start_byte, 3)
  }
  func testRealGrammarsAndIncrementalUnicode() throws {
    guard let rootPath = ProcessInfo.processInfo.environment["TCODE_GRAMMAR_FIXTURES"] else {
      throw XCTSkip("Set TCODE_GRAMMAR_FIXTURES to generated grammar directories")
    }
    let root = URL(fileURLWithPath: rootPath)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let parser = try NativeSyntaxParser(moduleDirectory: temporary)
    for id in ["python", "c", "cpp", "swift", "rust"] {
      let directory = root.appendingPathComponent(id)
      let descriptor = try JSONDecoder().decode(
        SyntaxGrammarDescriptor.self,
        from: Data(contentsOf: directory.appendingPathComponent("descriptor.json")))
      let module = try Data(contentsOf: directory.appendingPathComponent(descriptor.module))
      let query = try Data(contentsOf: directory.appendingPathComponent(descriptor.query))
      let source =
        id == "python"
        ? "# 👩🏽‍💻 café\r\ndef greet():\r\n    return \"hello\"\r\n" : "// 👩🏽‍💻 café\r\n\"hello\"\r\n"
      let uuid = UUID()
      let first = try parser.highlight(
        SyntaxRequest(
          documentID: uuid, version: 1, text: source,
          grammar: descriptor, moduleData: module, queryData: query))
      XCTAssertFalse(first.spans.isEmpty, id)
      let shared = try parser.highlight(
        SyntaxRequest(
          documentID: uuid, version: 1, text: source,
          grammar: descriptor, moduleData: nil, queryData: nil))
      XCTAssertEqual(shared.spans, first.spans, "Split views reuse the same document result")
      XCTAssertTrue(first.spans.contains { $0.capture == "comment" && $0.location == 0 }, id)
      let stringRange = (source as NSString).range(of: "\"hello\"")
      XCTAssertTrue(
        first.spans.contains { $0.capture == "string" && $0.range == stringRange },
        "UTF-8 to UTF-16 capture mapping: \(id)")
      let invalidQuery = Data("(".utf8)
      let invalidDescriptor = SyntaxGrammarDescriptor(
        id: id, version: descriptor.version, symbol: descriptor.symbol,
        moduleSHA256: descriptor.moduleSHA256, querySHA256: SyntaxIntegrity.sha256(invalidQuery),
        sourceRevision: descriptor.sourceRevision, abi: descriptor.abi)
      XCTAssertThrowsError(
        try parser.highlight(
          SyntaxRequest(
            documentID: uuid, version: 2, text: source,
            grammar: invalidDescriptor, moduleData: module, queryData: invalidQuery)))
      let changed = source.replacingOccurrences(of: "👩", with: "👨").replacingOccurrences(
        of: "café", with: "cafe\u{301}")
      let next = try parser.highlight(
        SyntaxRequest(
          documentID: uuid, version: 2, text: changed,
          grammar: descriptor, moduleData: nil, queryData: nil))
      XCTAssertTrue(next.incremental, id)
      XCTAssertTrue(next.spans.allSatisfy { NSMaxRange($0.range) <= changed.utf16.count }, id)
      XCTAssertThrowsError(
        try parser.highlight(
          SyntaxRequest(
            documentID: uuid, version: 0, text: source,
            grammar: descriptor, moduleData: nil, queryData: nil)))
      parser.close(uuid)
    }
  }
}
