import XCTest

@testable import TCodeCore

actor Events {
  var values: [[String: Any]] = []
  func append(_ value: [String: Any]) { values.append(value) }
  func contains(_ name: String) -> Bool {
    values.contains { $0["event"] as? String == name || $0["method"] as? String == name }
  }
  func all() -> [[String: Any]] { values }
}

final class IntegrationTests: XCTestCase {
  func enabled() throws {
    if ProcessInfo.processInfo.environment["TCODE_INTEGRATION"] != "1" {
      throw XCTSkip("Set TCODE_INTEGRATION=1 to exercise installed native language tools.")
    }
  }
  func temp() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode-integration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  func testPythonLSP() async throws {
    try enabled()
    try await language(
      name: "pylsp", ext: "py", id: "python",
      text: "def greet(name):\n    return name.upper()\n\ngreet(\"world\")\n",
      definition: Position(line: 3, character: 2), completion: Position(line: 1, character: 16))
  }
  func testClangdLSP() async throws {
    try enabled()
    try await language(
      name: "clangd", ext: "cpp", id: "cpp",
      text: "int greet(int value) { return value + 1; }\nint main() { return greet(42); }\n",
      definition: Position(line: 1, character: 22), completion: Position(line: 1, character: 23))
  }
  func testSwiftLSP() async throws {
    try enabled()
    try await language(
      name: "sourcekit-lsp", ext: "swift", id: "swift",
      text: "func greet(_ value: Int) -> Int { value + 1 }\nlet answer = greet(42)\n",
      definition: Position(line: 1, character: 15), completion: Position(line: 1, character: 16))
  }
  func language(
    name: String, ext: String, id: String, text: String, definition: Position, completion: Position
  ) async throws {
    guard let path = ToolLocator.find(name) else { throw XCTSkip("\(name) unavailable") }
    let root = try temp()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("main." + ext)
    try Data(text.utf8).write(to: file)
    let connection = ProtocolConnection(kind: .lsp)
    let events = Events()
    await connection.handlers(
      event: { await events.append($0) }, log: { text in print("\(name): \(text)") })
    try await connection.start(path: path, directory: root)
    do {
      let initialized = try await connection.request(
        "initialize",
        params: [
          "processId": ProcessInfo.processInfo.processIdentifier, "rootUri": root.absoluteString,
          "capabilities": [
            "general": ["positionEncodings": ["utf-16"]],
            "textDocument": ["publishDiagnostics": ["versionSupport": true]],
          ],
        ], timeout: 30)
      XCTAssertNotNil((initialized["result"] as? [String: Any])?["capabilities"])
      try await connection.notify("initialized")
      try await connection.notify(
        "textDocument/didOpen",
        params: [
          "textDocument": [
            "uri": file.absoluteString, "languageId": id, "version": 1, "text": text,
          ]
        ])
      try await Task.sleep(for: .seconds(2))
      let def = try await connection.request(
        "textDocument/definition",
        params: ["textDocument": ["uri": file.absoluteString], "position": definition.json],
        timeout: 30)
      let locations =
        def["result"] as? [[String: Any]] ?? (def["result"] as? [String: Any]).map { [$0] } ?? []
      XCTAssertFalse(locations.isEmpty, "\(name) should return a real definition: \(def)")
      let comp = try await connection.request(
        "textDocument/completion",
        params: ["textDocument": ["uri": file.absoluteString], "position": completion.json],
        timeout: 30)
      let items =
        comp["result"] as? [[String: Any]] ?? (comp["result"] as? [String: Any])?["items"]
        as? [[String: Any]] ?? []
      XCTAssertFalse(items.isEmpty, "\(name) should return completion items")
      let invalid =
        id == "python"
        ? text + "if )\n"
        : id == "cpp" ? text + "invalid syntax @\n" : text + "let broken: Int = \"wrong\"\n"
      try await connection.notify(
        "textDocument/didChange",
        params: [
          "textDocument": ["uri": file.absoluteString, "version": 2],
          "contentChanges": [["text": invalid]],
        ])
      try await Task.sleep(for: .seconds(3))
      let notifications = await events.all()
      var diagnostics = notifications.filter {
        $0["method"] as? String == "textDocument/publishDiagnostics"
      }.compactMap { ($0["params"] as? [String: Any])?["diagnostics"] as? [[String: Any]] }.flatMap
      { $0 }
      if id == "python", let ruff = ToolLocator.find("ruff") {
        let lint = try await RunningProcess().run(
          executable: ruff,
          arguments: ["check", "--output-format", "json", "--stdin-filename", file.path, "-"],
          directory: root, input: Data(invalid.utf8))
        diagnostics +=
          try JSONSerialization.jsonObject(with: Data(lint.output.utf8)) as? [[String: Any]] ?? []
      }
      XCTAssertFalse(diagnostics.isEmpty, "\(name) should publish actual diagnostics")
      print(
        "VERIFIED \(name): definition=\(locations.count), completion=\(items.count), diagnostics=\(diagnostics.count)"
      )
      await connection.stop()
    } catch {
      await connection.stop()
      throw error
    }
  }
  func testPythonDebugpyBreakpointAndVariables() async throws {
    try enabled()
    try await debug(language: "python")
  }
  func testCPPDebugBreakpointAndVariables() async throws {
    try enabled()
    try await debug(language: "cpp")
  }
  func testSwiftDebugBreakpointAndVariables() async throws {
    try enabled()
    try await debug(language: "swift")
  }
  func debug(language: String) async throws {
    let root = try temp()
    defer { try? FileManager.default.removeItem(at: root) }
    let python = language == "python"
    let swift = language == "swift"
    guard let adapter = ToolLocator.find(python ? "python3" : "lldb-dap") else {
      throw XCTSkip("Debug adapter unavailable")
    }
    let file = root.appendingPathComponent("main." + (python ? "py" : swift ? "swift" : "cpp"))
    let binary = root.appendingPathComponent("sample")
    let text =
      python
      ? "answer = 42\nanswer += 1\nprint(answer)\n"
      : swift
        ? "var answer = 42\nanswer += 1\nprint(answer)\n"
        : "#include <stdio.h>\nint main() {\n  int answer = 42;\n  answer += 1;\n  printf(\"%d\\n\", answer);\n}\n"
    try Data(text.utf8).write(to: file)
    if !python {
      let compile = try await RunningProcess().run(
        executable: swift ? "/usr/bin/swiftc" : "/usr/bin/clang++",
        arguments: swift
          ? ["-g", "-Onone", file.path, "-o", binary.path]
          : ["-g", "-O0", file.path, "-o", binary.path], directory: root)
      XCTAssertEqual(compile.status, 0, compile.output)
    }
    let connection = ProtocolConnection(kind: .dap)
    let events = Events()
    await connection.handlers(
      event: { await events.append($0) }, log: { print("DAP \(language): \($0)") })
    try await connection.start(
      path: adapter, arguments: python ? ["-m", "debugpy.adapter"] : [], directory: root)
    do {
      _ = try await connection.request(
        "initialize",
        params: [
          "clientID": "tcode-test", "adapterID": python ? "python" : "lldb", "linesStartAt1": true,
          "columnsStartAt1": true, "pathFormat": "path", "supportsRunInTerminalRequest": false,
        ])
      let launch = Task {
        try await connection.request(
          "launch",
          params: [
            "program": python ? file.path : binary.path, "cwd": root.path,
            "console": "internalConsole", "stopOnEntry": false,
          ], timeout: 60)
      }
      for _ in 0..<300 {
        if await events.contains("initialized") { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let initialized = await events.contains("initialized")
      XCTAssertTrue(initialized, "Adapter must initialize")
      let bp = try await connection.request(
        "setBreakpoints",
        params: ["source": ["path": file.path], "breakpoints": [["line": python || swift ? 2 : 4]]])
      print("DAP \(language) breakpoints: \(bp)")
      _ = try await connection.request("configurationDone")
      _ = try await launch.value
      for _ in 0..<150 {
        if await events.contains("stopped") { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let stopped = await events.contains("stopped")
      XCTAssertTrue(stopped, "Must stop at real breakpoint")
      guard stopped else {
        throw TCodeError.message("No breakpoint stop. Events: \(await events.all())")
      }
      let threads = try await connection.request("threads")
      let threadID =
        ((threads["body"] as? [String: Any])?["threads"] as? [[String: Any]])?.first?["id"] as? Int
        ?? 0
      let stack = try await connection.request("stackTrace", params: ["threadId": threadID])
      let frame =
        ((stack["body"] as? [String: Any])?["stackFrames"] as? [[String: Any]])?.first?["id"]
        as? Int ?? 0
      let scopes = try await connection.request("scopes", params: ["frameId": frame])
      let refs = ((scopes["body"] as? [String: Any])?["scopes"] as? [[String: Any]] ?? [])
        .compactMap { $0["variablesReference"] as? Int }
      var variables: [[String: Any]] = []
      for ref in refs {
        let response = try await connection.request(
          "variables", params: ["variablesReference": ref])
        variables += (response["body"] as? [String: Any])?["variables"] as? [[String: Any]] ?? []
      }
      let answer = variables.first { $0["name"] as? String == "answer" }
      XCTAssertEqual(answer?["value"] as? String, "42", "Actual variables: \(variables)")
      print("VERIFIED \(language) breakpoint and answer=\(answer?["value"] ?? "missing")")
      _ = try await connection.request("continue", params: ["threadId": threadID])
      await connection.stop()
    } catch {
      await connection.stop()
      throw error
    }
  }
  func awaitValue(_ value: Bool) -> Bool { value }
}
