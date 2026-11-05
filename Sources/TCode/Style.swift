import AppKit

/// The tCode design system. Chrome uses semantic system colors and materials so light, dark,
/// high-contrast, and Reduce Transparency settings behave natively; the editor keeps a quiet
/// curated surface so code stays the subject.
@MainActor enum Style {
  // MARK: - Surfaces

  /// The editor's paper, also used by output panels, terminals, and diff windows.
  private static let defaultEditorBackground = dynamic(0xFFFFFF, 0x1B1D23)
  private static let defaultEditorText = dynamic(0x24292F, 0xD0D6E0)
  static var editorBackground: NSColor {
    ThemeStore.shared.color(.background) ?? defaultEditorBackground
  }
  static var editorText: NSColor {
    ThemeStore.shared.color(.text) ?? defaultEditorText
  }
  /// The tab strip sits one shade away from the editor so the active tab reads as continuous.
  static let tabStripBackground = dynamic(0xF2F2F4, 0x16171B)
  /// Hairlines: card borders, the status bar's top edge.
  static let separator = NSColor.separatorColor
  static let subtleSeparator = NSColor.separatorColor.withAlphaComponent(0.5)

  // MARK: - Editor chrome

  /// Full-width tint of the caret's line: strong enough to read, quiet enough to ignore.
  static let currentLine = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.035, darkAlpha: 0.035)
  /// Background behind the bracket under the caret and its partner.
  static let matchingBracket = NSColor.controlAccentColor.withAlphaComponent(0.16)
  /// Line numbers and breakpoint gutter.
  static let gutter = NSColor.tertiaryLabelColor
  static let gutterActive = NSColor.secondaryLabelColor

  // MARK: - Syntax

  private static let defaultSyntaxKeyword = dynamic(0xA626A4, 0xC678DD)
  private static let defaultSyntaxType = dynamic(0x0550AE, 0x61AFEF)
  private static let defaultSyntaxNumber = dynamic(0x986801, 0xD19A66)
  private static let defaultSyntaxString = dynamic(0x2E7D32, 0x98C379)
  private static let defaultSyntaxComment = dynamic(0x8A919C, 0x6B7280)
  static var syntaxKeyword: NSColor {
    ThemeStore.shared.color(.keyword) ?? defaultSyntaxKeyword
  }
  static var syntaxType: NSColor {
    ThemeStore.shared.color(.type) ?? defaultSyntaxType
  }
  static var syntaxNumber: NSColor {
    ThemeStore.shared.color(.number) ?? defaultSyntaxNumber
  }
  static var syntaxString: NSColor {
    ThemeStore.shared.color(.string) ?? defaultSyntaxString
  }
  static var syntaxComment: NSColor {
    ThemeStore.shared.color(.comment) ?? defaultSyntaxComment
  }
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
  static let displayTitle = NSFont.systemFont(ofSize: 22, weight: .semibold)
  /// Project name and other primary headings in chrome.
  static let projectTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
  /// Small headings above lists and inspector sections.
  static let sectionTitle = NSFont.systemFont(ofSize: 11, weight: .semibold)
  /// List rows, palette rows, and other interactive text.
  static let body = NSFont.systemFont(ofSize: 12)
  /// Dense supporting text: inspector details, two-line rows.
  static let callout = NSFont.systemFont(ofSize: 11)
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

  static let sidebarInsets = NSEdgeInsets(top: 10, left: 8, bottom: 8, right: 8)
  static let panelHeaderInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
  /// Inner padding for read-only text surfaces such as output panels and diff windows.
  static let textInsets = NSSize(width: 16, height: 10)
  static let statusBarHeight: CGFloat = 24
  static let panelHeaderHeight: CGFloat = 32
  static let tabStripHeight: CGFloat = 32
  static let tabHeight: CGFloat = 26
  /// Long file names stop widening a tab at this point and truncate instead.
  static let tabMaxWidth: CGFloat = 220
  static let sidebarMinimumWidth: CGFloat = 220
  static let sidebarMaximumWidth: CGFloat = 360
  static let inspectorWidth: CGFloat = 260
  static let agentWidth: CGFloat = 320

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
