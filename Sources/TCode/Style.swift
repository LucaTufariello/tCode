import AppKit

/// The tCode design system: a precise, industrial instrument. Flat graphite and paper
/// surfaces, hairline rules, squared geometry, tracked micro-labels, and one restrained
/// signal accent. Chrome uses explicit light/dark pairs so it stays legible in both
/// appearances; the editor keeps the quiet curated surface so code stays the subject.
@MainActor enum Style {
  // MARK: - Surfaces

  /// The editor's paper, also used by output panels, terminals, and diff windows.
  private static let defaultEditorBackground = dynamic(0xFFFFFF, 0x1B1D21)
  private static let defaultEditorText = dynamic(0x1F2328, 0xCFD4DC)
  static var editorBackground: NSColor {
    ThemeStore.shared.color(.background) ?? defaultEditorBackground
  }
  static var editorText: NSColor {
    ThemeStore.shared.color(.text) ?? defaultEditorText
  }
  /// Sidebar, inspector, agent panel, status bar, and panel header.
  static let chrome = dynamic(0xF2F2EF, 0x15171A)
  /// Wells inside the chrome: input fields, the panel body behind lists.
  static let chromeInset = dynamic(0xEAEAE6, 0x111316)
  /// The tab strip sits one shade away from the editor.
  static let tabStrip = dynamic(0xECECE8, 0x131518)
  /// Raised controls: text fields, popovers, the palette.
  static let control = dynamic(0xFFFFFF, 0x1D2025)

  // MARK: - Rules and state

  /// A one-pixel rule. The primary structural device of the interface.
  static let hairline = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.11, darkAlpha: 0.09)
  /// A stronger rule for the edge of the window and focused controls.
  static let hairlineStrong = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.16)
  /// Hover wash for list rows and controls.
  static let rowHover = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.05)
  /// Selected wash for list rows when the row itself is not the focus.
  static let rowSelected = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.08)

  /// The single signal accent. Used for active markers, the caret, and primary actions.
  static let accent = dynamic(0xC2410C, 0xFF8A4C)
  static let accentSoft = dynamic(0xC2410C, 0xFF8A4C, lightAlpha: 0.10, darkAlpha: 0.14)
  static let accentWash = dynamic(0xC2410C, 0xFF8A4C, lightAlpha: 0.20, darkAlpha: 0.26)

  // MARK: - Editor chrome

  /// Full-width tint of the caret's line: strong enough to read, quiet enough to ignore.
  static let currentLine = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.032, darkAlpha: 0.038)
  /// Background behind the bracket under the caret and its partner.
  static let matchingBracket = dynamic(0xC2410C, 0xFF8A4C, lightAlpha: 0.16, darkAlpha: 0.20)
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

  /// The welcome screen wordmark.
  static let displayTitle = NSFont.systemFont(ofSize: 30, weight: .semibold)
  /// Project name and other primary headings in chrome.
  static let projectTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
  /// Uppercase tracked labels above lists and inspector sections.
  static let sectionTitle = NSFont.systemFont(ofSize: 10, weight: .semibold)
  /// List rows, palette rows, and other interactive text.
  static let body = NSFont.systemFont(ofSize: 12)
  /// Dense supporting text: inspector details, two-line rows.
  static let callout = NSFont.systemFont(ofSize: 11)
  /// Status bar and other secondary annotations.
  static let caption = NSFont.systemFont(ofSize: 10.5)
  /// Monospaced content: editor, output panels, terminals, diff windows.
  static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  /// Technical readouts: paths, coordinates, counts.
  static let monoSmall = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
  /// Right-aligned status segments; tabular digits keep the row from shifting while typing.
  static let statusInfo = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
  /// Editor tab labels: the selected tab carries the stronger weight.
  static func tabTitle(selected: Bool) -> NSFont {
    .systemFont(ofSize: 11.5, weight: selected ? .medium : .regular)
  }

  // MARK: - Metrics

  static let sidebarInsets = NSEdgeInsets(top: 0, left: 12, bottom: 10, right: 12)
  static let panelHeaderInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
  /// Inner padding for read-only text surfaces such as output panels and diff windows.
  static let textInsets = NSSize(width: 14, height: 10)
  static let statusBarHeight: CGFloat = 26
  static let panelHeaderHeight: CGFloat = 32
  static let tabStripHeight: CGFloat = 36
  static let tabHeight: CGFloat = 36
  static let breadcrumbHeight: CGFloat = 26
  static let rowHeight: CGFloat = 24
  /// Long file names stop widening a tab at this point and truncate instead.
  static let tabMaxWidth: CGFloat = 240
  static let sidebarMinimumWidth: CGFloat = 220
  static let sidebarMaximumWidth: CGFloat = 360
  static let inspectorWidth: CGFloat = 280
  static let agentWidth: CGFloat = 340
  /// Squared geometry: the interface has no pills.
  static let radius: CGFloat = 3

  // MARK: - Text helpers

  /// Tracked, optionally uppercased text. Used for every micro-label so the interface
  /// keeps one voice.
  static func attributed(
    _ text: String, font: NSFont, color: NSColor, tracking: CGFloat = 0, uppercase: Bool = false
  ) -> NSAttributedString {
    NSAttributedString(
      string: uppercase ? text.uppercased() : text,
      attributes: [.font: font, .foregroundColor: color, .kern: tracking])
  }

  /// A configured label for chrome. Micro-labels are uppercase and tracked.
  @discardableResult
  static func label(
    _ text: String, font: NSFont? = nil, color: NSColor = .labelColor,
    tracking: CGFloat = 0, uppercase: Bool = false
  ) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.attributedStringValue = attributed(
      text, font: font ?? body, color: color, tracking: tracking, uppercase: uppercase)
    field.lineBreakMode = .byTruncatingTail
    return field
  }

  /// A section heading: uppercase, tracked, quiet.
  static func sectionLabel(_ text: String) -> NSTextField {
    label(text, font: sectionTitle, color: .tertiaryLabelColor, tracking: 0.9, uppercase: true)
  }

  /// A technical readout in tabular monospace.
  static func readout(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = statusInfo
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
  }

  // MARK: - Drawing helpers

  /// Fills a crisp one-pixel rule aligned to the backing store.
  static func rule(_ rect: NSRect, color: NSColor? = nil) {
    (color ?? hairline).setFill()
    NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
  }

  /// Fills a crisp one-pixel vertical rule.
  static func verticalRule(_ rect: NSRect, color: NSColor? = nil) {
    (color ?? hairline).setFill()
    NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
  }

  /// A small filled square used as an active marker.
  static func marker(_ rect: NSRect, color: NSColor? = nil) {
    (color ?? accent).setFill()
    NSRect(x: rect.minX, y: rect.midY - 2, width: 4, height: 4).fill()
  }

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
