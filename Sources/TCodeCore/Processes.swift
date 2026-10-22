import Darwin
import Foundation

public enum Background {
  public static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value)
    async throws -> Value
  {
    let task = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
  }
}

public struct ProcessResult: Sendable {
  public let output: String
  public let status: Int32
  public let stdout: String
}

private final class ErrorBuffer: @unchecked Sendable {
  let lock = NSLock()
  var bytes = Data()
  func append(_ data: Data) {
    lock.lock()
    bytes.append(data)
    lock.unlock()
  }
  func read() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return bytes
  }
}

public enum ToolLocator {
  public static var environment: [String: String] {
    var e = ProcessInfo.processInfo.environment
    e["PATH"] =
      NSHomeDirectory()
      + "/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
      + (e["PATH"] ?? "")
    return e
  }
  public static func find(_ name: String, root: URL? = nil) -> String? {
    guard !name.isEmpty else { return nil }
    if name.hasPrefix("/") {
      return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    let configured = UserDefaults.standard.string(forKey: "tool." + name)
    let preferred: [String?] = [
      configured, root.map { $0.appendingPathComponent(".venv/bin/" + name).path },
      ManagedToolPaths.resolve(name: name),
      NSHomeDirectory() + "/Library/Application Support/tCode/tools/bin/" + name,
      "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/"
        + name,
      "/Applications/Xcode.app/Contents/Developer/usr/bin/" + name,
    ]
    let candidates =
      preferred.compactMap { $0 }
      + (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

public final class RunningProcess: @unchecked Sendable {
  private let process = Process()
  private let lock = NSLock()
  private var group: Int32 = 0
  private var cancelled = false
  public init() {}
  public func run(
    executable: String, arguments: [String], directory: URL?, environment: [String: String] = [:],
    input: Data? = nil, output: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> ProcessResult {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async {
            let pipe = Pipe()
            let errors = Pipe()
            let stdin = Pipe()
            self.process.executableURL = URL(fileURLWithPath: executable)
            self.process.arguments = arguments
            self.process.currentDirectoryURL = directory
            self.process.environment = ToolLocator.environment.merging(environment) { _, b in b }
            self.process.standardOutput = pipe
            self.process.standardError = errors
            self.process.standardInput = stdin
            do {
              self.lock.lock()
              let cancelled = self.cancelled
              self.lock.unlock()
              if cancelled { throw CancellationError() }
              try self.process.run()
              self.lock.lock()
              self.group = self.process.processIdentifier
              let cancelNow = self.cancelled
              self.lock.unlock()
              // Best effort process group. Never signal the application's process group.
              _ = setpgid(self.process.processIdentifier, self.process.processIdentifier)
              if cancelNow { self.cancel() }
              DispatchQueue.global(qos: .userInitiated).async {
                if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                try? stdin.fileHandleForWriting.close()
              }
              let errorBuffer = ErrorBuffer()
              let errorGroup = DispatchGroup()
              errorGroup.enter()
              DispatchQueue.global(qos: .utility).async {
                while true {
                  let bytes = errors.fileHandleForReading.availableData
                  if bytes.isEmpty { break }
                  errorBuffer.append(bytes)
                  output(String(decoding: bytes, as: UTF8.self))
                }
                errorGroup.leave()
              }
              var buffer = Data()
              while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                output(String(decoding: data, as: UTF8.self))
              }
              self.process.waitUntilExit()
              errorGroup.wait()
              self.lock.lock()
              self.group = 0
              self.lock.unlock()
              let stdout = String(decoding: buffer, as: UTF8.self)
              continuation.resume(
                returning: ProcessResult(
                  output: stdout + String(decoding: errorBuffer.read(), as: UTF8.self),
                  status: self.process.terminationStatus, stdout: stdout))
            } catch { continuation.resume(throwing: error) }
          }
        }
      }, onCancel: { self.cancel() })
  }
  public func cancel() {
    lock.lock()
    cancelled = true
    let pid = group
    lock.unlock()
    guard pid > 0 else { return }
    if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { kill(pid, SIGTERM) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let current = self.group
      self.lock.unlock()
      if current == pid {
        if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
      }
    }
  }
}
