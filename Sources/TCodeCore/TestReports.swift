import Foundation

public struct TestEntry: Sendable {
  public let name: String
  public let status: String
  public let path: String?
  public let symbol: String?
  public var label: String { status.isEmpty ? name : "\(status)  \(name)" }
}

/// Parses the documented text formats used by the three first-party test runners.
/// The original output is always retained in Build Output, including unknown formats.
public enum TestReports {
  public static func parse(_ output: String, runner: String) -> [TestEntry] {
    var entries: [TestEntry] = []
    for raw in output.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if runner == "pytest", line.contains("::"), let first = line.split(separator: " ").first,
        first.contains(".py::")
      {
        let name = String(first)
        let pieces = name.components(separatedBy: "::")
        let status =
          ["PASSED", "FAILED", "SKIPPED", "ERROR", "XFAIL", "XPASS"].first(where: line.contains)
          ?? ""
        entries.append(
          TestEntry(
            name: name, status: status, path: pieces.first,
            symbol: pieces.last?.components(separatedBy: "[").first))
      } else if runner == "swift" {
        if line.hasPrefix("Test Case '"), let end = line.dropFirst(11).firstIndex(of: "'") {
          let name = String(line[line.index(line.startIndex, offsetBy: 11)..<end])
          if line.contains(" passed ") || line.contains(" failed ") || line.contains(" skipped ") {
            let symbol = name.components(separatedBy: CharacterSet(charactersIn: " .]")).filter {
              !$0.isEmpty
            }.last
            entries.append(
              TestEntry(
                name: name,
                status: line.contains(" failed ")
                  ? "FAILED" : line.contains(" skipped ") ? "SKIPPED" : "PASSED", path: nil,
                symbol: symbol))
          }
        } else if !line.contains(" "), line.contains("/test"), !line.hasPrefix("/") {
          entries.append(
            TestEntry(
              name: line, status: "", path: nil, symbol: line.components(separatedBy: "/").last))
        }
      } else if runner == "ctest" {
        if let regex = try? NSRegularExpression(
          pattern: #"(?:\d+/\d+\s+)?Test\s+#\d+:\s+([^\s]+)(.*)"#),
          let match = regex.firstMatch(
            in: line, range: NSRange(location: 0, length: line.utf16.count))
        {
          let ns = line as NSString
          let name = ns.substring(with: match.range(at: 1))
          let tail = ns.substring(with: match.range(at: 2))
          entries.append(
            TestEntry(
              name: name,
              status: tail.contains("Passed") ? "PASSED" : tail.contains("Failed") ? "FAILED" : "",
              path: nil, symbol: nil))
        }
      }
    }
    return entries
  }
}
