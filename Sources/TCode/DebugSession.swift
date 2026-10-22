import Darwin
import Foundation
import TCodeCore

@MainActor final class DebugSession {
  let connection = ProtocolConnection(kind: .dap)
  var initialized = false
  var stopped = false
  var active = true
  var threads: [[String: Any]] = []
  var frames: [[String: Any]] = []
  var threadID = 0
  var frameID = 0
  var output: ((String) -> Void)?
  var location: ((URL, Position) -> Void)?
  var state: ((String) -> Void)?
  func start(
    adapter: String, arguments: [String], program: String, python: Bool = false, root: URL,
    breakpoints: [URL: [Int]], programArguments: [String] = [], environment: [String: String] = [:],
    adapterID: String? = nil, launchOptions: [String: Any] = [:]
  ) async throws {
    await connection.handlers(
      event: { [weak self] event in await self?.handle(event) },
      log: { [weak self] text in await MainActor.run { self?.output?(text) } })
    try await connection.start(path: adapter, arguments: arguments, directory: root)
    _ = try await connection.request(
      "initialize",
      params: [
        "clientID": "tcode", "clientName": "tCode",
        "adapterID": adapterID ?? (python ? "python" : "lldb"),
        "pathFormat": "path", "linesStartAt1": true, "columnsStartAt1": true,
        "supportsVariableType": true, "supportsRunInTerminalRequest": false,
      ])
    var launch: [String: Any] = [
      "program": program, "cwd": root.path, "stopOnEntry": false, "args": programArguments,
      "env": ToolLocator.environment.merging(environment) { _, new in new },
    ]
    if python {
      launch["console"] = "internalConsole"
      launch["justMyCode"] = true
      launch["python"] = [adapter]
    }
    launch.merge(launchOptions) { _, configured in configured }
    launch["program"] = program
    let launchTask = Task { try await connection.request("launch", params: launch, timeout: 60) }
    for _ in 0..<600 {
      if initialized { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard initialized else {
      launchTask.cancel()
      throw TCodeError.message("The debug adapter did not initialize.")
    }
    for (url, lines) in breakpoints { try await sendBreakpoints(url, lines: lines) }
    _ = try await connection.request("configurationDone")
    _ = try await launchTask.value
    state?("Debugger running")
  }
  func handle(_ event: [String: Any]) async {
    let body = event["body"] as? [String: Any] ?? [:]
    switch event["event"] as? String {
    case "initialized": initialized = true
    case "output":
      if body["category"] as? String != "telemetry" { output?(body["output"] as? String ?? "") }
    case "stopped":
      stopped = true
      threadID = body["threadId"] as? Int ?? 0
      do {
        let t = try await connection.request("threads")
        threads = (t["body"] as? [String: Any])?["threads"] as? [[String: Any]] ?? []
        if threadID == 0 { threadID = threads.first?["id"] as? Int ?? 0 }
        let stack = try await connection.request(
          "stackTrace", params: ["threadId": threadID, "startFrame": 0, "levels": 100])
        frames = (stack["body"] as? [String: Any])?["stackFrames"] as? [[String: Any]] ?? []
        if let frame = frames.first { select(frame) }
        state?("Paused: " + (body["reason"] as? String ?? "breakpoint"))
        output?("\nPaused. Use Run → Inspect Variables or Evaluate Watch.\n")
      } catch { output?(error.localizedDescription) }
    case "continued":
      stopped = false
      state?("Debugger running")
    case "terminated", "exited":
      stopped = false
      active = false
      state?("Debugger finished")
    default: break
    }
  }
  func select(_ frame: [String: Any]) {
    frameID = frame["id"] as? Int ?? 0
    if let source = frame["source"] as? [String: Any], let path = source["path"] as? String {
      location?(
        URL(fileURLWithPath: path),
        Position(
          line: (frame["line"] as? Int ?? 1) - 1, character: (frame["column"] as? Int ?? 1) - 1))
    }
  }
  func sendBreakpoints(_ url: URL, lines: [Int]) async throws {
    let source = url.path.withCString { path -> String in
      guard let resolved = realpath(path, nil) else { return url.path }
      defer { free(resolved) }
      return String(cString: resolved)
    }
    let result = try await connection.request(
      "setBreakpoints",
      params: ["source": ["path": source], "breakpoints": lines.sorted().map { ["line": $0] }])
    let values = (result["body"] as? [String: Any])?["breakpoints"] as? [[String: Any]] ?? []
    for b in values where b["verified"] as? Bool != true {
      output?("Unverified breakpoint: \(b["message"] ?? "pending symbols")\n")
    }
  }
  func setBreakpoints(_ url: URL, lines: [Int]) {
    guard active, initialized else { return }
    Task {
      do { try await sendBreakpoints(url, lines: lines) } catch {
        output?(error.localizedDescription)
      }
    }
  }
  func command(_ method: String) async throws {
    guard active else { throw TCodeError.message("Start a debug session first.") }
    _ = try await connection.request(method, params: ["threadId": threadID])
  }
  func variables(reference: Int? = nil) async throws -> [[String: Any]] {
    if let reference {
      let result = try await connection.request(
        "variables", params: ["variablesReference": reference])
      return (result["body"] as? [String: Any])?["variables"] as? [[String: Any]] ?? []
    }
    let result = try await connection.request("scopes", params: ["frameId": frameID])
    let scopes = (result["body"] as? [String: Any])?["scopes"] as? [[String: Any]] ?? []
    var values: [[String: Any]] = []
    for scope in scopes {
      if let ref = scope["variablesReference"] as? Int {
        values += try await variables(reference: ref)
      }
    }
    return values
  }
  func evaluate(_ expression: String) async throws -> String {
    let result = try await connection.request(
      "evaluate", params: ["expression": expression, "frameId": frameID, "context": "watch"])
    return (result["body"] as? [String: Any])?["result"] as? String ?? "No result"
  }
  func stop() {
    active = false
    stopped = false
    Task { await connection.stop() }
  }
  func shutdown() async {
    active = false
    stopped = false
    await connection.stop()
  }
}

struct RunConfiguration: Codable {
  var executable = ""
  var arguments: [String] = []
  var environment: [String: String] = [:]
  var workingDirectory = ""
  var python = ""
  var debugProgram = ""
}
