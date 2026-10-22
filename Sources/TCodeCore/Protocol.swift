import Foundation

public struct MessageFramer {
  private var buffer = Data()
  public init() {}
  public mutating func append(_ bytes: Data) throws -> [[String: Any]] {
    buffer.append(bytes)
    var messages: [[String: Any]] = []
    while let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
      guard headerEnd.lowerBound < 8192,
        let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8),
        let lengthLine = header.components(separatedBy: "\r\n").first(where: {
          $0.lowercased().hasPrefix("content-length:")
        }),
        let length = Int(
          lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
        length >= 0, length <= 32 * 1024 * 1024
      else { throw TCodeError.message("Invalid protocol message header.") }
      let body = headerEnd.upperBound
      guard buffer.count >= body + length else { break }
      let value = try JSONSerialization.jsonObject(with: buffer[body..<body + length])
      guard let object = value as? [String: Any] else {
        throw TCodeError.message("Expected a protocol object.")
      }
      messages.append(object)
      buffer = Data(buffer[(body + length)...])
    }
    if buffer.count > 32 * 1024 * 1024 + 8192 {
      throw TCodeError.message("Protocol buffer limit exceeded.")
    }
    return messages
  }
  public static func encode(_ message: [String: Any]) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    return Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data
  }
}

public actor ProtocolConnection {
  public enum Kind { case lsp, dap }
  private let kind: Kind
  private let process = Process()
  private let input = Pipe(), output = Pipe(), errorPipe = Pipe()
  private var framer = MessageFramer()
  private var sequence = 0
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var timeouts: [Int: Task<Void, Never>] = [:]
  private var closed = false
  private var eventSink: AsyncStream<[String: Any]>.Continuation?
  private var eventTask: Task<Void, Never>?
  public var event: (([String: Any]) async -> Void)?
  public var log: ((String) async -> Void)?
  private var serverRequest: (([String: Any]) async throws -> Any)?
  public init(kind: Kind) { self.kind = kind }
  public func handlers(
    event: @escaping ([String: Any]) async -> Void,
    log: @escaping (String) async -> Void = { _ in },
    serverRequest: (([String: Any]) async throws -> Any)? = nil
  ) {
    self.event = event
    self.log = log
    self.serverRequest = serverRequest
    eventTask?.cancel()
    eventSink?.finish()
    let pair = AsyncStream<[String: Any]>.makeStream()
    eventSink = pair.continuation
    eventTask = Task { for await message in pair.stream { await event(message) } }
  }
  public func start(
    path: String, arguments: [String] = [], directory: URL? = nil,
    environment: [String: String] = [:]
  ) throws {
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = ToolLocator.environment.merging(environment) { _, override in override }
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errorPipe
    process.terminationHandler = { [weak self] p in
      Task { await self?.failed("Tool exited with status \(p.terminationStatus).") }
    }
    try process.run()
    let reader = output.fileHandleForReading
    let errors = errorPipe.fileHandleForReading
    let stream = AsyncStream<Data> { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        while true {
          let data = reader.availableData
          if data.isEmpty { break }
          continuation.yield(data)
        }
        continuation.finish()
      }
    }
    Task { for await data in stream { await receive(data) } }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      while true {
        let data = errors.availableData
        if data.isEmpty { break }
        Task { await self?.logged(String(decoding: data, as: UTF8.self)) }
      }
    }
  }
  private func logged(_ text: String) async { await log?(text) }
  public func request(_ method: String, params: [String: Any] = [:], timeout: Double = 15)
    async throws -> [String: Any]
  {
    guard !closed else { throw TCodeError.message("The tool is no longer running.") }
    sequence += 1
    let id = sequence
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          pending[id] = continuation
          do {
            let message: [String: Any] =
              kind == .lsp
              ? ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
              : ["seq": id, "type": "request", "command": method, "arguments": params]
            try write(message)
            timeouts[id] = Task {
              try? await Task.sleep(for: .seconds(timeout))
              guard !Task.isCancelled else { return }
              self.expire(id)
            }
          } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
      }, onCancel: { Task { await self.cancel(id) } })
  }
  public func notify(_ method: String, params: [String: Any] = [:]) throws {
    try write(["jsonrpc": "2.0", "method": method, "params": params])
  }
  private func write(_ message: [String: Any]) throws {
    guard !closed else { throw TCodeError.message("Protocol connection closed.") }
    try input.fileHandleForWriting.write(contentsOf: MessageFramer.encode(message))
  }
  private func expire(_ id: Int) {
    pending.removeValue(forKey: id)?.resume(throwing: TCodeError.message("Tool request timed out."))
    timeouts.removeValue(forKey: id)
    if kind == .lsp { try? notify("$/cancelRequest", params: ["id": id]) }
  }
  private func cancel(_ id: Int) {
    timeouts.removeValue(forKey: id)?.cancel()
    pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    if kind == .lsp { try? notify("$/cancelRequest", params: ["id": id]) }
  }
  private func receive(_ data: Data) async {
    do {
      for message in try framer.append(data) {
        let id = kind == .lsp ? message["id"] as? Int : message["request_seq"] as? Int
        let response =
          kind == .lsp ? message["method"] == nil : message["type"] as? String == "response"
        if response, let id, let continuation = pending.removeValue(forKey: id) {
          timeouts.removeValue(forKey: id)?.cancel()
          if let error = message["error"] as? [String: Any] {
            continuation.resume(
              throwing: TCodeError.message(error["message"] as? String ?? "Language server error"))
          } else if message["success"] as? Bool == false {
            continuation.resume(
              throwing: TCodeError.message(message["message"] as? String ?? "Debug adapter error"))
          } else {
            continuation.resume(returning: message)
          }
        } else if kind == .lsp, let method = message["method"] as? String, let id = message["id"] {
          if ["workspace/applyEdit", "workspace/configuration", "workspace/workspaceFolders"]
            .contains(method), let handler = serverRequest
          {
            // Read responses while the user reviews an asynchronous server edit.
            Task {
              do {
                let result = try await handler(message)
                try self.write(["jsonrpc": "2.0", "id": id, "result": result])
              } catch {
                if method == "workspace/applyEdit" {
                  try? self.write([
                    "jsonrpc": "2.0", "id": id,
                    "result": ["applied": false, "failureReason": error.localizedDescription],
                  ])
                } else {
                  try? self.write([
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": -32603, "message": error.localizedDescription],
                  ])
                }
              }
            }
            continue
          }
          var result: Any = NSNull()
          if method == "workspace/configuration" {
            result = ((message["params"] as? [String: Any])?["items"] as? [Any] ?? []).map { _ in
              [String: Any]()
            }
          }
          if method == "workspace/workspaceFolders" { result = [] as [Any] }
          if method == "workspace/applyEdit" {
            result = ["applied": false, "failureReason": "Use a reviewed tCode code action."]
          }
          if [
            "workspace/configuration", "workspace/workspaceFolders", "workspace/applyEdit",
            "client/registerCapability", "window/workDoneProgress/create",
            "client/unregisterCapability",
          ].contains(method) {
            try write(["jsonrpc": "2.0", "id": id, "result": result])
          } else {
            try write([
              "jsonrpc": "2.0", "id": id,
              "error": ["code": -32601, "message": "Unsupported client request"],
            ])
          }
        } else {
          eventSink?.yield(message)
        }
      }
    } catch { await failed(error.localizedDescription) }
  }
  private func failed(_ reason: String) async {
    guard !closed else { return }
    closed = true
    if process.isRunning { process.terminate() }
    try? input.fileHandleForWriting.close()
    for (_, continuation) in pending { continuation.resume(throwing: TCodeError.message(reason)) }
    pending.removeAll()
    for (_, task) in timeouts { task.cancel() }
    timeouts.removeAll()
    eventSink?.finish()
    eventTask?.cancel()
    await log?(reason)
  }
  public func stop() async {
    guard !closed else { return }
    if kind == .lsp {
      _ = try? await request("shutdown", timeout: 2)
      try? notify("exit")
    } else {
      _ = try? await request("disconnect", params: ["terminateDebuggee": true], timeout: 2)
    }
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
    await failed("Tool stopped.")
  }
}
