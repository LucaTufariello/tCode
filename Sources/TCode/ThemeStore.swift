import AppKit
import TCodeCore

extension Notification.Name {
  static let tcodeThemeChanged = Notification.Name("tCodeThemeChanged")
}

enum ThemeRole: String, CaseIterable {
  case background, text, keyword, type, number, string, comment
}

struct ThemeColors: Codable, Equatable {
  var background: String
  var text: String
  var keyword: String
  var type: String
  var number: String
  var string: String
  var comment: String

  func value(_ role: ThemeRole) -> String {
    switch role {
    case .background: return background
    case .text: return text
    case .keyword: return keyword
    case .type: return type
    case .number: return number
    case .string: return string
    case .comment: return comment
    }
  }
}

struct ThemePack: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  var version: String
  var author: String?
  var summary: String?
  var colors: ThemeColors
}

extension NSColor {
  convenience init?(themeHex: String) {
    var value = themeHex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else {
      return nil
    }
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    if value.count == 8 {
      red = CGFloat((number >> 24) & 0xFF) / 255
      green = CGFloat((number >> 16) & 0xFF) / 255
      blue = CGFloat((number >> 8) & 0xFF) / 255
      alpha = CGFloat(number & 0xFF) / 255
    } else {
      red = CGFloat((number >> 16) & 0xFF) / 255
      green = CGFloat((number >> 8) & 0xFF) / 255
      blue = CGFloat(number & 0xFF) / 255
      alpha = 1
    }
    self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }
}

/// Declarative editor themes. A theme is data only: no code, no installer, no network.
@MainActor final class ThemeStore: ObservableObject {
  static let shared = ThemeStore()
  static let activeKey = "theme.active"

  @Published private(set) var themes: [ThemePack] = []
  @Published private(set) var activeID: String?

  private let directory: URL

  init(directory: URL = ThemeStore.defaultDirectory) {
    self.directory = directory
    activeID = UserDefaults.standard.string(forKey: Self.activeKey)
    reload()
  }

  nonisolated static var defaultDirectory: URL {
    LanguageSupportPaths.root.appendingPathComponent("Themes", isDirectory: true)
  }

  static let bundled: [ThemePack] = [
    ThemePack(
      id: "tcode-dark", name: "tCode Dark", version: "1.0.0", author: "tCode",
      summary: "The default quiet dark editor.",
      colors: ThemeColors(
        background: "#1B1D23", text: "#D0D6E0", keyword: "#C678DD", type: "#61AFEF",
        number: "#D19A66", string: "#98C379", comment: "#6B7280")),
    ThemePack(
      id: "tcode-light", name: "tCode Light", version: "1.0.0", author: "tCode",
      summary: "The default light editor.",
      colors: ThemeColors(
        background: "#FFFFFF", text: "#24292F", keyword: "#A626A4", type: "#0550AE",
        number: "#986801", string: "#2E7D32", comment: "#8A919C")),
    ThemePack(
      id: "midnight", name: "Midnight", version: "1.0.0", author: "tCode",
      summary: "A deeper blue-black surface with brighter syntax.",
      colors: ThemeColors(
        background: "#0F1115", text: "#C9D1D9", keyword: "#FF7B72", type: "#79C0FF",
        number: "#D2A8FF", string: "#A5D6FF", comment: "#8B949E")),
    ThemePack(
      id: "paper", name: "Paper", version: "1.0.0", author: "tCode",
      summary: "A warm light surface for long reading sessions.",
      colors: ThemeColors(
        background: "#FAF9F5", text: "#2B2B2B", keyword: "#8B5CF6", type: "#2563EB",
        number: "#B45309", string: "#15803D", comment: "#78716C")),
  ]

  func reload() {
    var byID = Dictionary(Self.bundled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    if let files = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
          let pack = try? JSONDecoder().decode(ThemePack.self, from: data),
          (try? validate(pack)) != nil
        else { continue }
        byID[pack.id] = pack
      }
    }
    themes = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    if let activeID, !themes.contains(where: { $0.id == activeID }) {
      self.activeID = nil
      UserDefaults.standard.removeObject(forKey: Self.activeKey)
    }
  }

  func color(_ role: ThemeRole) -> NSColor? {
    guard let activeID, let pack = themes.first(where: { $0.id == activeID }) else { return nil }
    return NSColor(themeHex: pack.colors.value(role))
  }

  func apply(_ pack: ThemePack) {
    activeID = pack.id
    UserDefaults.standard.set(pack.id, forKey: Self.activeKey)
    NotificationCenter.default.post(name: .tcodeThemeChanged, object: nil)
  }

  func useDefault() {
    activeID = nil
    UserDefaults.standard.removeObject(forKey: Self.activeKey)
    NotificationCenter.default.post(name: .tcodeThemeChanged, object: nil)
  }

  func isUserInstalled(_ id: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(id + ".json").path)
  }

  func importPack(from url: URL) throws -> ThemePack {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 1_048_576 else {
      throw TCodeError.message("Theme pack exceeds the 1 MB limit.")
    }
    let data = try Data(contentsOf: url)
    let pack = try JSONDecoder().decode(ThemePack.self, from: data)
    try validate(pack)
    try write(pack)
    reload()
    return pack
  }

  func remove(_ pack: ThemePack) throws {
    guard isUserInstalled(pack.id) else {
      throw TCodeError.message("Bundled themes cannot be removed.")
    }
    try FileManager.default.removeItem(
      at: directory.appendingPathComponent(pack.id + ".json"))
    if activeID == pack.id { useDefault() }
    reload()
  }

  private func write(_ pack: ThemePack) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(pack).write(
      to: directory.appendingPathComponent(pack.id + ".json"), options: .atomic)
  }

  private func validate(_ pack: ThemePack) throws {
    let identifier = #"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$"#
    guard pack.id.range(of: identifier, options: .regularExpression) != nil,
      !pack.name.isEmpty, pack.name.count <= 120, !pack.version.isEmpty
    else {
      throw TCodeError.message("A theme pack needs a valid id, name, and version.")
    }
    for role in ThemeRole.allCases {
      guard NSColor(themeHex: pack.colors.value(role)) != nil else {
        throw TCodeError.message("Invalid color for \(role.rawValue) in \(pack.name).")
      }
    }
  }
}
