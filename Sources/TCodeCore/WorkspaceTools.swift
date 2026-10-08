import Foundation

public struct SearchHit: Sendable {
  public let url: URL
  public let line: Int
  public let range: NSRange
  public let preview: String
}
public struct FileChange: Sendable {
  public let url: URL
  public let before: Data
  public let after: Data
  public let text: String
  public init(url: URL, before: Data, after: Data, text: String) {
    self.url = url
    self.before = before
    self.after = after
    self.text = text
  }
}
public enum WorkspaceSearch {
  public static func find(
    root: URL, pattern: String, regex: Bool, limit: Int = 10000,
    excluding: Set<String> = FileIO.exclusions
  ) throws -> [SearchHit] {
    let expression = try NSRegularExpression(
      pattern: regex ? pattern : NSRegularExpression.escapedPattern(for: pattern),
      options: [.anchorsMatchLines])
    var hits: [SearchHit] = []
    for url in try FileIO.indexedFiles(root, excluding: excluding) {
      if Task<Never, Never>.isCancelled { throw CancellationError() }
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
        let data = try? Data(contentsOf: url), let file = try? TextFile(data: data)
      else { continue }
      let ns = file.text as NSString
      for match in expression.matches(in: file.text, range: NSRange(location: 0, length: ns.length))
      {
        let line = PositionMap.position(in: file.text, utf16Offset: match.range.location).line
        let preview = ns.substring(with: ns.lineRange(for: match.range)).trimmingCharacters(
          in: .newlines)
        hits.append(
          SearchHit(url: url, line: line, range: match.range, preview: String(preview.prefix(240))))
        if hits.count >= limit { return hits }
      }
    }
    return hits
  }
  public static func replacements(
    root: URL, pattern: String, replacement: String, regex: Bool,
    excluding: Set<String> = FileIO.exclusions
  ) throws -> [FileChange] {
    let expression = try NSRegularExpression(
      pattern: regex ? pattern : NSRegularExpression.escapedPattern(for: pattern),
      options: [.anchorsMatchLines])
    var changes: [FileChange] = []
    var bytes = 0
    for url in try FileIO.indexedFiles(root, excluding: excluding) {
      try Task.checkCancellation()
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
        let before = try? Data(contentsOf: url), let file = try? TextFile(data: before),
        expression.firstMatch(
          in: file.text, range: NSRange(location: 0, length: file.text.utf16.count)) != nil
      else { continue }
      let template = regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
      let text = expression.stringByReplacingMatches(
        in: file.text, range: NSRange(location: 0, length: file.text.utf16.count),
        withTemplate: template)
      let after = try file.encode(text)
      bytes += before.count + after.count
      guard bytes <= 64 * 1024 * 1024 else {
        throw TCodeError.message(
          "The replacement preview exceeds 64 MB. Narrow the workspace or search pattern; no edits were applied."
        )
      }
      changes.append(FileChange(url: url, before: before, after: after, text: text))
    }
    return changes.sorted { $0.url.path < $1.url.path }
  }
  public static func apply(_ changes: [FileChange]) throws {
    for c in changes {
      guard try Data(contentsOf: c.url) == c.before else {
        throw TCodeError.message(
          "\(c.url.lastPathComponent) changed after the preview. No edits were applied.")
      }
    }
    var applied: [FileChange] = []
    do {
      for c in changes {
        try FileIO.save(c.after, to: c.url, expected: c.before)
        applied.append(c)
      }
    } catch {
      var failures: [String] = []
      for c in applied.reversed() {
        do { try FileIO.save(c.before, to: c.url, expected: c.after) } catch {
          failures.append(c.url.path)
        }
      }
      if !failures.isEmpty {
        throw TCodeError.message(
          "Replacement failed and rollback needs attention: \(failures.joined(separator:", ")). Original bytes remain in the reviewed plan. \(error.localizedDescription)"
        )
      }
      throw error
    }
  }
}

public struct GitEntry: Sendable {
  public let status: String
  public let path: String
}
public enum Git {
  public static func run(_ root: URL, _ arguments: [String]) async throws -> String {
    let result = try await RunningProcess().run(
      executable: "/usr/bin/git", arguments: ["-C", root.path] + arguments, directory: root)
    guard result.status == 0 else {
      throw TCodeError.message(
        result.output.isEmpty ? "Git exited with \(result.status)." : result.output)
    }
    return result.output
  }
  public static func status(_ root: URL) async throws -> [GitEntry] {
    let result = try await run(root, ["status", "--porcelain=v1", "-z"])
    let chunks = result.split(separator: "\0", omittingEmptySubsequences: true)
    var entries: [GitEntry] = []
    var i = 0
    while i < chunks.count {
      let line = String(chunks[i])
      if line.count >= 3 {
        let state = String(line.prefix(2))
        entries.append(GitEntry(status: state, path: String(line.dropFirst(3))))
        if state.contains("R") || state.contains("C") { i += 1 }
      }
      i += 1
    }
    return entries
  }
}
