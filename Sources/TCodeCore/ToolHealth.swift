import Foundation

public struct ToolHealthReport: Codable, Sendable {
  public enum Status: String, Codable, Sendable { case healthy, missing, failed, timedOut }
  public let executable: String
  public let status: Status
  public let version: String?
  public let detail: String
  public var isHealthy: Bool { status == .healthy }
  public init(executable: String, status: Status, version: String? = nil, detail: String) {
    self.executable = executable
    self.status = status
    self.version = version
    self.detail = detail
  }
}

public enum ToolHealth {
  /// Probes a real executable. Rustup shims and stale executable paths are not treated as installed.
  public static func check(
    executable: String, arguments: [String] = ["--version"], timeout: TimeInterval = 8
  ) async -> ToolHealthReport {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      return .init(
        executable: executable, status: .missing,
        detail: "Executable is missing or is not executable.")
    }
    let process = RunningProcess()
    let timeoutTask = Task {
      try? await Task.sleep(for: .seconds(timeout))
      if !Task.isCancelled { process.cancel() }
    }
    defer { timeoutTask.cancel() }
    do {
      let start = Date()
      let result = try await process.run(
        executable: executable, arguments: arguments, directory: nil)
      try Task.checkCancellation()
      if Date().timeIntervalSince(start) >= timeout {
        return .init(
          executable: executable, status: .timedOut,
          detail: "The executable did not complete its version probe within \(timeout) seconds.")
      }
      guard result.status == 0 else {
        return .init(
          executable: executable, status: .failed,
          detail: String(result.output.prefix(4000)))
      }
      let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        return .init(
          executable: executable, status: .failed,
          detail: "Version probe succeeded without identifying the tool.")
      }
      return .init(
        executable: executable, status: .healthy, version: String(text.prefix(1000)),
        detail: "Version probe completed successfully.")
    } catch {
      return .init(executable: executable, status: .failed, detail: error.localizedDescription)
    }
  }
}
