import Foundation

/// XPC errors, interruption, reply and transport timeout can race; resume exactly once.
private final class SyntaxReplyGate<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
  @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: result)
    return pending != nil
  }
}

/// The only connection to executable grammars. Kept outside the editor for independent packaged testing.
public final class SyntaxConnection: @unchecked Sendable {
  public static let serviceName = "dev.tufariello.tCode.SyntaxService"
  private let lock = NSLock()
  private var connection: NSXPCConnection?
  private var generation = 0
  public init() {}
  deinit { connection?.invalidate() }
  public func invalidate() {
    lock.lock()
    let old = connection
    connection = nil
    generation += 1
    lock.unlock()
    old?.invalidate()
  }
  public var connectionGeneration: Int {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }
  private func connect() -> NSXPCConnection {
    lock.lock()
    defer { lock.unlock() }
    if let connection { return connection }
    let next = NSXPCConnection(serviceName: Self.serviceName)
    next.remoteObjectInterface = NSXPCInterface(with: SyntaxServiceProtocol.self)
    next.interruptionHandler = { [weak self, weak next] in self?.lost(next) }
    next.invalidationHandler = { [weak self, weak next] in self?.lost(next) }
    connection = next
    next.resume()
    return next
  }
  private func lost(_ old: NSXPCConnection?) {
    lock.lock()
    defer { lock.unlock() }
    if connection === old {
      connection = nil
      generation += 1
    }
  }
  public func remote(error: @escaping (Error) -> Void) throws -> SyntaxServiceProtocol {
    guard let proxy = connect().remoteObjectProxyWithErrorHandler(error) as? SyntaxServiceProtocol
    else {
      throw SyntaxFailure.unavailable
    }
    return proxy
  }
  public func highlight(_ request: SyntaxRequest) async throws -> SyntaxResponse {
    // Transfer a read-only descriptor, never a workspace path or a sandbox extension.
    // macOS quarantines executable files synthesized inside a sandboxed worker.
    // The host creates this verified immutable copy; only the worker maps its code.
    var moduleHandle: FileHandle?
    var moduleDirectory: URL?
    defer {
      try? moduleHandle?.close()
      if let moduleDirectory { try? FileManager.default.removeItem(at: moduleDirectory) }
    }
    if let module = request.moduleData {
      try SyntaxIntegrity.validateModule(module, descriptor: request.grammar)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tcode-syntax-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      moduleDirectory = directory
      let file = directory.appendingPathComponent("grammar.dylib")
      try module.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
      moduleHandle = try FileHandle(forReadingFrom: file)
    }
    let wireRequest = SyntaxRequest(
      documentID: request.documentID, version: request.version, text: request.text,
      grammar: request.grammar, moduleData: nil, queryData: request.queryData)
    let bytes = try JSONEncoder().encode(wireRequest)
    return try await withCheckedThrowingContinuation { continuation in
      let gate = SyntaxReplyGate<SyntaxResponse>(continuation)
      DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
        if gate.finish(.failure(SyntaxFailure.timeout)) { self?.invalidate() }
      }
      do {
        let proxy = try remote { gate.finish(.failure($0)) }
        proxy.highlight(bytes, module: moduleHandle) { data, message in
          if let message {
            gate.finish(.failure(SyntaxFailure.invalidGrammar(message)))
            return
          }
          guard let data, let response = try? JSONDecoder().decode(SyntaxResponse.self, from: data),
            response.documentID == request.documentID, response.version == request.version,
            response.spans.count <= 100_000,
            response.spans.allSatisfy({
              $0.location >= 0 && $0.length >= 0
                && $0.location <= request.text.utf16.count - $0.length && $0.capture.count <= 128
            })
          else {
            gate.finish(.failure(SyntaxFailure.invalidResponse))
            return
          }
          gate.finish(.success(response))
        }
      } catch { gate.finish(.failure(error)) }
    }
  }
  public func close(_ id: UUID) {
    lock.lock()
    let current = connection
    lock.unlock()
    guard let current,
      let proxy = current.remoteObjectProxyWithErrorHandler({ _ in }) as? SyntaxServiceProtocol
    else { return }
    proxy.closeDocument(id.uuidString)
  }
}
