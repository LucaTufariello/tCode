import AppKit
import TCodeCore

@MainActor final class OutputLinkHandler: NSObject, NSTextViewDelegate {
  weak var workspace: WorkspaceWindow?
  init(_ workspace: WorkspaceWindow) { self.workspace = workspace }
  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), url.isFileURL
    else { return false }
    let line = Int(url.fragment ?? "1") ?? 1
    workspace?.open(
      URL(fileURLWithPath: url.path), position: Position(line: max(0, line - 1), character: 0))
    return true
  }
  func decorate(_ textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    let text = storage.string as NSString
    let pattern = "((?:/[^:\\n]+|[A-Za-z0-9_./-]+)\\.(?:swift|cpp|cc|c|h|hpp|py)):(\\d+)(?::\\d+)?"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    for match in regex.matches(in: storage.string, range: NSRange(location: 0, length: text.length))
    {
      let path = text.substring(with: match.range(at: 1))
      let line = text.substring(with: match.range(at: 2))
      let file =
        path.hasPrefix("/")
        ? URL(fileURLWithPath: path) : workspace?.root?.appendingPathComponent(path)
      if let file {
        var components = URLComponents(url: file, resolvingAgainstBaseURL: false)
        components?.fragment = line
        if let url = components?.url { storage.addAttribute(.link, value: url, range: match.range) }
      }
    }
  }
}
