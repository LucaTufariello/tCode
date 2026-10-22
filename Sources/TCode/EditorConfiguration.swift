import AppKit
import TCodeCore

struct EditorConfiguration {
  var indentSize = 4
  var useTabs = false
  var wrap = true
  var exclusions = FileIO.exclusions
  static func load(root: URL?, file: URL?, languageDefaults: LanguageEditorConfiguration? = nil)
    -> Self
  {
    var result = Self()
    if let size = languageDefaults?.indentSize { result.indentSize = size }
    if let tabs = languageDefaults?.useTabs { result.useTabs = tabs }
    let global = UserDefaults.standard.integer(forKey: "indentWidth")
    if global > 0 { result.indentSize = global }
    if let names = UserDefaults.standard.stringArray(forKey: "exclusions") {
      result.exclusions.formUnion(names)
    }
    guard let root else { return result }
    if let bytes = try? Data(contentsOf: root.appendingPathComponent(".tcode/settings.json")),
      let settings = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    {
      if let size = settings["indentSize"] as? Int { result.indentSize = min(max(size, 1), 16) }
      if let wrap = settings["wrap"] as? Bool { result.wrap = wrap }
      if let names = settings["exclusions"] as? [String] { result.exclusions.formUnion(names) }
    }
    guard let file else { return result }
    // Hierarchical EditorConfig subset: *, *.extension, exact paths; nearest file wins.
    var folders: [URL] = []
    var cursor = file.deletingLastPathComponent()
    while cursor.path.hasPrefix(root.path) {
      folders.append(cursor)
      if cursor == root { break }
      cursor.deleteLastPathComponent()
    }
    for folder in folders.reversed() {
      guard
        let config = try? String(
          contentsOf: folder.appendingPathComponent(".editorconfig"), encoding: .utf8)
      else { continue }
      var matching = true
      for raw in config.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") || line.hasPrefix(";") || line.isEmpty { continue }
        if line.hasPrefix("[") && line.hasSuffix("]") {
          let glob = String(line.dropFirst().dropLast())
          let target =
            glob.contains("/")
            ? String(file.path.dropFirst(folder.path.count + 1)) : file.lastPathComponent
          matching = fnmatch(glob, target, 0) == 0
          continue
        }
        guard matching, let divider = line.firstIndex(of: "=") else { continue }
        let key = line[..<divider].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: divider)...].trimmingCharacters(in: .whitespaces)
        if key == "indent_size", let size = Int(value) { result.indentSize = min(max(size, 1), 16) }
        if key == "indent_style" { result.useTabs = value == "tab" }
      }
    }
    return result
  }
}

@MainActor final class ConcentricGlass: NSGlassEffectView {
  override var cornerConfiguration: NSViewCornerConfiguration? {
    .uniformCorners(radius: .containerConcentric(8))
  }
}
