import AppKit

/// The tCode design system. Every surface — sidebar, tab strip, editor, panels, status bar —
/// draws its color, type, and spacing from here, so the window reads as one designed object in
/// both appearances.
///
/// The editor surfaces (editor, output panels, terminals, diff windows) share one tone; the
/// chrome around them (tab strip, cards) sits a shade away so content reads as the subject.
@MainActor enum Style {
  // MARK: - Surfaces

  /// The editor's paper, also used by output panels, terminals, and diff windows.
  static let editorBackground = dynamic(0xFFFFFF, 0x1B1D23)
  static let editorText = dynamic(0x24292F, 0xD0D6E0)
  /// The tab strip sits a shade away from the editor so the selected tab reads as lifted.
  static let tabStripBackground = dynamic(0xEFEFF2, 0x14161A)
  /// Filled rows and cards: recent projects, hover states.
  static let card = dynamic(0xF4F5F7, 0x24262C)
  /// Hairlines: card borders, the status bar's top edge.
  static let separator = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)
  static let subtleSeparator = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)

  // MARK: - Editor chrome

  /// Full-width tint of the caret's line: strong enough to read, quiet enough to ignore.
  static let currentLine = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.045)
  /// Background behind the bracket under the caret and its partner.
  static let matchingBracket = NSColor.controlAccentColor.withAlphaComponent(0.18)
  /// Line numbers and breakpoint gutter.
  static let gutter = dynamic(0x9AA1AB, 0x565D68)
  static let gutterActive = dynamic(0x24292F, 0xB6BDC7)

  // MARK: - Syntax

  static let syntaxKeyword = dynamic(0xA626A4, 0xC678DD)
  static let syntaxType = dynamic(0x0550AE, 0x61AFEF)
  static let syntaxNumber = dynamic(0x986801, 0xD19A66)
  static let syntaxString = dynamic(0x2E7D32, 0x98C379)
  static let syntaxComment = dynamic(0x8A919C, 0x6B7280)
  /// Underline colors for LSP diagnostics, keyed by severity (1 error … 4 hint).
  static func diagnostic(severity: Int?) -> NSColor {
    switch severity ?? 1 {
    case 1: return .systemRed
    case 2: return .systemOrange
    case 3: return .systemBlue
    default: return .secondaryLabelColor
    }
  }

  // MARK: - Type scale

  /// The welcome screen headline.
  static let displayTitle = NSFont.systemFont(ofSize: 30, weight: .semibold)
  /// Project name and other primary headings in chrome.
  static let projectTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
  /// Small headings above lists and inspector sections.
  static let sectionTitle = NSFont.systemFont(ofSize: 11, weight: .semibold)
  /// List rows, palette rows, and other interactive text.
  static let body = NSFont.systemFont(ofSize: 13)
  /// Dense supporting text: inspector details, two-line rows.
  static let callout = NSFont.systemFont(ofSize: 12)
  /// Status bar and other secondary annotations.
  static let caption = NSFont.systemFont(ofSize: 11)
  /// Monospaced content: editor, output panels, terminals, diff windows.
  static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  /// Right-aligned status segments; tabular digits keep the row from shifting while typing.
  static let statusInfo = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
  /// Editor tab labels: the selected tab carries the strongest weight.
  static func tabTitle(selected: Bool) -> NSFont {
    .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
  }

  // MARK: - Metrics

  static let sidebarInsets = NSEdgeInsets(top: 12, left: 8, bottom: 8, right: 8)
  static let panelHeaderInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
  /// Inner padding for read-only text surfaces such as output panels and diff windows.
  static let textInsets = NSSize(width: 14, height: 10)
  static let statusBarHeight: CGFloat = 28
  static let tabStripHeight: CGFloat = 38
  static let tabHeight: CGFloat = 27
  /// Long file names stop widening a tab at this point and truncate instead.
  static let tabMaxWidth: CGFloat = 200
  static let tabRadius: CGFloat = 6
  static let cardRadius: CGFloat = 12
  static let sidebarMinimumWidth: CGFloat = 220
  static let sidebarMaximumWidth: CGFloat = 460

  // MARK: - Internals

  private nonisolated static func srgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
  /// One semantic color with a light and a dark form, resolved against the current appearance
  /// at draw time.
  private nonisolated static func dynamic(
    _ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
  ) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? srgb(dark, darkAlpha) : srgb(light, lightAlpha)
    }
  }
}
