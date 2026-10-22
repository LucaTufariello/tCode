import Darwin
import Foundation
import XCTest

@testable import TCodeCore

private actor RustProtocolEvents {
  var messages: [[String: Any]] = []
  func append(_ value: [String: Any]) { messages.append(value) }
  func contains(_ event: String) -> Bool { messages.contains { $0["event"] as? String == event } }
  func diagnostics() -> [[String: Any]] {
    messages.filter { $0["method"] as? String == "textDocument/publishDiagnostics" }.flatMap {
      ($0["params"] as? [String: Any])?["diagnostics"] as? [[String: Any]] ?? []
    }
  }
}

/// These cases start actual Cargo/rustfmt/rust-analyzer/LLDB processes, never protocol mocks.
final class RustIntegrationTests: XCTestCase {
  let source = """
    fn greet(value: i32) -> i32 {
        value + 1
    }
    fn main() {
        let mut answer = greet(41);
        answer += 1;
        println!("{answer}");
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn computes_answer() { assert_eq!(greet(41), 42); }
    }
    """ + "\n"
  func enabled() throws {
    guard ProcessInfo.processInfo.environment["TCODE_INTEGRATION"] == "1" else {
      throw XCTSkip(
        "Set TCODE_INTEGRATION=1 to exercise the real Rust language toolchain and LLDB.")
    }
  }
  func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode-rust-" + UUID().uuidString
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try Data(
      "[package]\nname = \"tcode_rust_validation\"\nversion = \"0.1.0\"\nedition = \"2021\"\n".utf8
    ).write(to: root.appendingPathComponent("Cargo.toml"))
    try Data(source.utf8).write(to: root.appendingPathComponent("src/main.rs"))
    return root
  }
  func tool(_ name: String) async throws -> String {
    guard let path = ToolLocator.find(name) else {
      throw XCTSkip(
        "\(name) is missing. Install the external Rust/Xcode toolchain before running this integration case."
      )
    }
    let health = await ToolHealth.check(executable: path)
    guard health.isHealthy else { throw XCTSkip("\(name) is not healthy: \(health.detail)") }
    return path
  }
  func cargo(_ arguments: [String], root: URL) async throws -> ProcessResult {
    let path = try await tool("cargo")
    return try await RunningProcess().run(
      executable: path, arguments: arguments, directory: root,
      environment: ["CARGO_TARGET_DIR": root.appendingPathComponent("target").path])
  }
  func testCargoBuildRunTestAndRustfmt() async throws {
    try enabled()
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for arguments in [["build", "--offline"], ["run", "--offline"], ["test", "--offline"]] {
      let result = try await cargo(arguments, root: root)
      XCTAssertEqual(result.status, 0, result.output)
      if arguments[0] == "run" {
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "43")
      }
      if arguments[0] == "test" { XCTAssertTrue(result.stdout.contains("1 passed"), result.output) }
    }
    let rustfmt = try await tool("rustfmt")
    let formatted = try await RunningProcess().run(
      executable: rustfmt, arguments: ["--edition", "2021"], directory: root,
      input: Data("fn main(){let answer=42;println!(\"{answer}\");}".utf8))
    XCTAssertEqual(formatted.status, 0, formatted.output)
    XCTAssertTrue(formatted.stdout.contains("let answer = 42;"), formatted.stdout)
    print("VERIFIED Rust: Cargo build/run/test, one passing test, rustfmt stdin formatting")
  }
  func testRustAnalyzerCompletionDefinitionAndDiagnostics() async throws {
    try enabled()
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let path: String
    if let existing = ToolLocator.find("rust-analyzer"),
      (await ToolHealth.check(executable: existing)).isHealthy
    {
      path = existing
    } else {
      let installer = ToolInstaller(
        directory: root.appendingPathComponent("managed-tools"), preferExistingTools: false)
      let plan = try await installer.plan(recipeID: "rust-analyzer")
      guard plan.canInstall else {
        throw XCTSkip(plan.prerequisites.map(\.detail).joined(separator: "\n"))
      }
      let receipt = try await installer.install(plan, approval: { _ in true })
      path = try XCTUnwrap(receipt.executables["rust-analyzer"])
    }
    let file = root.appendingPathComponent("src/main.rs")
    let connection = ProtocolConnection(kind: .lsp)
    let events = RustProtocolEvents()
    await connection.handlers(event: { await events.append($0) }, log: { print("Rust LSP: \($0)") })
    try await connection.start(path: path, directory: root)
    do {
      _ = try await connection.request(
        "initialize",
        params: [
          "processId": ProcessInfo.processInfo.processIdentifier, "rootUri": root.absoluteString,
          "workspaceFolders": [["uri": root.absoluteString, "name": "Rust Fixture"]],
          "capabilities": [
            "general": ["positionEncodings": ["utf-16"]],
            "textDocument": [
              "publishDiagnostics": ["versionSupport": true],
              "completion": ["completionItem": ["snippetSupport": false]],
            ],
          ],
          "initializationOptions": [
            "cargo": ["buildScripts": ["enable": false]], "procMacro": ["enable": false],
            "checkOnSave": false,
          ],
        ], timeout: 60)
      try await connection.notify("initialized")
      try await connection.notify(
        "textDocument/didOpen",
        params: [
          "textDocument": [
            "uri": file.absoluteString, "languageId": "rust", "version": 1, "text": source,
          ]
        ])
      let usage = try XCTUnwrap(source.range(of: "greet(41)"))
      let offset = source.utf16.distance(
        from: source.utf16.startIndex, to: usage.lowerBound.samePosition(in: source.utf16)!)
      let definition = PositionMap.position(in: source, utf16Offset: offset + 2)
      let completion = PositionMap.position(in: source, utf16Offset: offset + 3)
      var locations: [[String: Any]] = []
      var items: [[String: Any]] = []
      for _ in 0..<60 {
        if let response = try? await connection.request(
          "textDocument/definition",
          params: ["textDocument": ["uri": file.absoluteString], "position": definition.json],
          timeout: 10)
        {
          locations =
            response["result"] as? [[String: Any]] ?? (response["result"] as? [String: Any]).map {
              [$0]
            } ?? []
        }
        if let response = try? await connection.request(
          "textDocument/completion",
          params: [
            "textDocument": ["uri": file.absoluteString], "position": completion.json,
            "context": ["triggerKind": 1],
          ], timeout: 10)
        {
          items =
            response["result"] as? [[String: Any]] ?? (response["result"] as? [String: Any])?[
              "items"] as? [[String: Any]] ?? []
        }
        if !locations.isEmpty && !items.isEmpty { break }
        try await Task.sleep(for: .milliseconds(500))
      }
      XCTAssertFalse(
        locations.isEmpty, "rust-analyzer must return a real local function definition")
      XCTAssertTrue(
        items.contains { ($0["label"] as? String)?.contains("greet") == true },
        "Completion labels: \(items.map { $0["label"] ?? "" })")
      try await connection.notify(
        "textDocument/didChange",
        params: [
          "textDocument": ["uri": file.absoluteString, "version": 2],
          "contentChanges": [["text": source + "\nfn broken( {\n"]],
        ])
      for _ in 0..<100 {
        if !(await events.diagnostics()).isEmpty { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let diagnostics = await events.diagnostics()
      XCTAssertFalse(diagnostics.isEmpty, "rust-analyzer must publish syntax diagnostics")
      print(
        "VERIFIED Rust LSP: definitions=\(locations.count), completion=\(items.count), diagnostics=\(diagnostics.count)"
      )
      await connection.stop()
    } catch {
      await connection.stop()
      throw error
    }
  }
  func testRustLLDBBreakpointAndInspectableVariable() async throws {
    try enabled()
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let build = try await cargo(["build", "--offline"], root: root)
    XCTAssertEqual(build.status, 0, build.output)
    let adapter = try await tool("lldb-dap")
    let file = root.appendingPathComponent("src/main.rs")
    let binary = root.appendingPathComponent("target/debug/tcode_rust_validation")
    let line =
      source.components(separatedBy: "\n").firstIndex(where: { $0.contains("answer += 1") })! + 1
    let connection = ProtocolConnection(kind: .dap)
    let events = RustProtocolEvents()
    await connection.handlers(event: { await events.append($0) }, log: { print("Rust DAP: \($0)") })
    try await connection.start(path: adapter, directory: root)
    do {
      _ = try await connection.request(
        "initialize",
        params: [
          "clientID": "tcode-rust-test", "adapterID": "lldb", "linesStartAt1": true,
          "columnsStartAt1": true, "pathFormat": "path", "supportsRunInTerminalRequest": false,
        ])
      let launch = Task {
        try await connection.request(
          "launch", params: ["program": binary.path, "cwd": root.path, "stopOnEntry": false],
          timeout: 60)
      }
      for _ in 0..<300 {
        if await events.contains("initialized") { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let breakpoints = try await connection.request(
        "setBreakpoints",
        params: ["source": ["path": physicalPath(file.path)], "breakpoints": [["line": line]]])
      let rows = (breakpoints["body"] as? [String: Any])?["breakpoints"] as? [[String: Any]] ?? []
      XCTAssertTrue(rows.first?["verified"] as? Bool == true, "\(breakpoints)")
      _ = try await connection.request("configurationDone")
      _ = try await launch.value
      for _ in 0..<150 {
        if await events.contains("stopped") { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let stopped = await events.contains("stopped")
      XCTAssertTrue(stopped, "Rust executable must stop at the source breakpoint")
      guard stopped else { throw TCodeError.message("Rust LLDB did not stop at breakpoint") }
      let threads = try await connection.request("threads")
      let threadID = try XCTUnwrap(
        ((threads["body"] as? [String: Any])?["threads"] as? [[String: Any]])?.first?["id"] as? Int)
      let stack = try await connection.request("stackTrace", params: ["threadId": threadID])
      let frameID = try XCTUnwrap(
        ((stack["body"] as? [String: Any])?["stackFrames"] as? [[String: Any]])?.first?["id"]
          as? Int)
      let scopes = try await connection.request("scopes", params: ["frameId": frameID])
      let references = ((scopes["body"] as? [String: Any])?["scopes"] as? [[String: Any]] ?? [])
        .compactMap { $0["variablesReference"] as? Int }
      var variables: [[String: Any]] = []
      for reference in references {
        let response = try await connection.request(
          "variables", params: ["variablesReference": reference])
        variables += (response["body"] as? [String: Any])?["variables"] as? [[String: Any]] ?? []
      }
      XCTAssertEqual(
        variables.first { $0["name"] as? String == "answer" }?["value"] as? String, "42",
        "Actual Rust variables: \(variables)")
      print("VERIFIED Rust LLDB: verified source breakpoint, answer=42")
      _ = try await connection.request("continue", params: ["threadId": threadID])
      await connection.stop()
    } catch {
      await connection.stop()
      throw error
    }
  }
  private func physicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
