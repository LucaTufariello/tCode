import AppKit

/// Opt-in local measurement output. No document content or file paths are recorded.
@MainActor enum SyntaxMetric {
  static func record(_ document: CodeDocument, spanCount: Int? = nil) async {
    guard let path = ProcessInfo.processInfo.environment["TCODE_SYNTAX_METRICS_PATH"] else {
      return
    }
    let worker = await SyntaxClient.shared.serviceProcessID
    let metric: [String: Any] = [
      "document_id": document.id.uuidString,
      "document_version": document.version,
      "utf16_length": document.storage.length,
      "grammar_id": document.grammarID ?? "",
      "status": document.syntaxStatus,
      "span_count": spanCount ?? 0,
      "helper_pid": worker ?? 0,
    ]
    guard let data = try? JSONSerialization.data(
      withJSONObject: metric, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

@MainActor enum LaunchMetric {
  static var reported = false
  static func windowReady(_ window: NSWindow) {
    guard !reported, let path = ProcessInfo.processInfo.environment["TCODE_METRICS_PATH"],
      let raw = ProcessInfo.processInfo.environment["TCODE_LAUNCH_STARTED"],
      let started = Double(raw)
    else { return }
    DispatchQueue.main.async {
      window.contentView?.layoutSubtreeIfNeeded()
      guard !reported else { return }
      reported = true
      let metric: [String: Any] = [
        "launch_to_first_layout_ms": (Date().timeIntervalSince1970 - started) * 1000,
        "measurement": "External process start to first native window layout; single warm launch",
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: metric, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
      }
    }
  }
}
