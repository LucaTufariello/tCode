import AppKit

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
