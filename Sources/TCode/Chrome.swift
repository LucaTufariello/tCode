import AppKit

/// A flat surface with optional one-pixel edge rules. The building block for every chrome
/// region: sidebar, inspector, agent panel, status bar, and panel header.
@MainActor final class SurfaceView: NSView {
  enum Edge { case top, bottom, left, right }
  var fill: NSColor
  var edges: [Edge]

  init(fill: NSColor? = nil, edges: [Edge] = []) {
    self.fill = fill ?? Style.chrome
    self.edges = edges
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    bounds.fill()
    for edge in edges {
      switch edge {
      case .top: Style.rule(NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1))
      case .bottom: Style.rule(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
      case .left: Style.verticalRule(NSRect(x: 0, y: 0, width: 1, height: bounds.height))
      case .right:
        Style.verticalRule(
          NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height))
      }
    }
  }
}

/// A flat input well: the control surface, a squared border, and an accent border while
/// focused. Used by the palette and any chrome-level text entry.
@MainActor final class FieldBox: NSView {
  var focused = false { didSet { needsDisplay = true } }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: Style.radius, yRadius: Style.radius)
    Style.control.setFill()
    path.fill()
    (focused ? Style.accent : Style.hairlineStrong).setStroke()
    path.lineWidth = 1
    path.stroke()
  }
}

/// A flat filter well: a squared control surface, a quiet magnifier, and a borderless field.
/// Used wherever chrome needs a search box, so no rounded system search field appears.
@MainActor final class SearchWell: NSView {
  let field = NSTextField()
  private let glyph = NSImageView()
  private var focused = false { didSet { needsDisplay = true } }

  init(placeholder: String, width: CGFloat = 220) {
    super.init(frame: .zero)
    field.placeholderString = placeholder
    field.font = Style.body
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.textColor = .labelColor
    field.setAccessibilityLabel(placeholder)
    glyph.image = NSImage(
      systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    glyph.contentTintColor = .tertiaryLabelColor
    for view in [glyph, field] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: width),
      heightAnchor.constraint(equalToConstant: 24),
      glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
      glyph.widthAnchor.constraint(equalToConstant: 12),
      field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
      field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      field.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    NotificationCenter.default.addObserver(
      self, selector: #selector(editingBegan), name: NSControl.textDidBeginEditingNotification,
      object: field)
    NotificationCenter.default.addObserver(
      self, selector: #selector(editingEnded), name: NSControl.textDidEndEditingNotification,
      object: field)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func editingBegan() { focused = true }
  @objc private func editingEnded() { focused = false }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: Style.radius, yRadius: Style.radius)
    Style.control.setFill()
    path.fill()
    (focused ? Style.accent : Style.hairlineStrong).setStroke()
    path.lineWidth = 1
    path.stroke()
  }
}

/// A single one-pixel rule, horizontal or vertical.
@MainActor final class HairlineView: NSView {
  enum Axis { case horizontal, vertical }
  let axis: Axis
  init(_ axis: Axis) {
    self.axis = axis
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ dirtyRect: NSRect) {
    if axis == .horizontal {
      Style.rule(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
    } else {
      Style.verticalRule(NSRect(x: 0, y: 0, width: 1, height: bounds.height))
    }
  }
  override var intrinsicContentSize: NSSize {
    axis == .horizontal ? NSSize(width: NSView.noIntrinsicMetric, height: 1)
      : NSSize(width: 1, height: NSView.noIntrinsicMetric)
  }
}

/// A squared button in the industrial language: a filled signal button for the primary
/// action, a ruled button for secondary actions, and a quiet button for inline controls.
@MainActor final class IndustrialButton: NSControl {
  enum Kind { case primary, secondary, quiet }
  let kind: Kind
  var title: String {
    didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
  }
  var onClick: (() -> Void)?
  /// A single-character key equivalent, handled while the button is in the key window.
  var keyEquivalent = ""
  override var isEnabled: Bool { didSet { needsDisplay = true } }
  private var hovered = false { didSet { needsDisplay = true } }
  private var pressed = false { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?

  init(_ title: String, kind: Kind = .secondary) {
    self.title = title
    self.kind = kind
    super.init(frame: .zero)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    let width = (title as NSString).size(withAttributes: [.font: Style.body]).width
    return NSSize(width: ceil(width) + (kind == .quiet ? 12 : 24), height: kind == .quiet ? 22 : 26)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard !keyEquivalent.isEmpty, isEnabled,
      event.charactersIgnoringModifiers == keyEquivalent
    else { return false }
    onClick?()
    if let action { sendAction(action, to: target) }
    return true
  }
  override func mouseDown(with event: NSEvent) {
    pressed = true
  }
  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    guard inside, isEnabled else { return }
    onClick?()
    if let action { sendAction(action, to: target) }
  }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: Style.radius, yRadius: Style.radius)
    switch kind {
    case .primary:
      let fill =
        isEnabled
        ? (pressed ? Style.accent.blended(withFraction: 0.18, of: .black) ?? Style.accent
          : Style.accent)
        : Style.accent.withAlphaComponent(0.4)
      fill.setFill()
      path.fill()
    case .secondary:
      (hovered ? Style.rowHover : NSColor.clear).setFill()
      path.fill()
      Style.hairlineStrong.setStroke()
      path.lineWidth = 1
      path.stroke()
    case .quiet:
      if hovered {
        Style.rowHover.setFill()
        path.fill()
      }
    }
    let color: NSColor =
      !isEnabled
      ? .tertiaryLabelColor
      : (kind == .primary ? .white : (hovered ? .labelColor : .secondaryLabelColor))
    let font = NSFont.systemFont(ofSize: 11.5, weight: kind == .primary ? .semibold : .medium)
    let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
    let size = text.size()
    text.draw(
      at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
  }
}

/// A square, borderless icon control for chrome actions. No bezel, no pill: a glyph that
/// gains a quiet wash under the pointer.
@MainActor final class IconButton: NSControl {
  let symbol: String
  var onClick: (() -> Void)?
  private var hovered = false { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?

  init(symbol: String, label: String) {
    self.symbol = symbol
    super.init(frame: .zero)
    setAccessibilityRole(.button)
    setAccessibilityLabel(label)
    toolTip = label
  }
  required init?(coder: NSCoder) { fatalError() }
  override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick?()
    if let action { sendAction(action, to: target) }
  }
  override func draw(_ dirtyRect: NSRect) {
    if hovered {
      Style.rowHover.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: Style.radius, yRadius: Style.radius).fill()
    }
    guard
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    else { return }
    image.isTemplate = true
    let tinted = NSImage(size: image.size, flipped: false) { rect in
      image.draw(in: rect)
      (self.hovered ? NSColor.labelColor : NSColor.secondaryLabelColor).set()
      rect.fill(using: .sourceAtop)
      return true
    }
    tinted.draw(
      in: NSRect(
        x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
        width: image.size.width, height: image.size.height))
  }
}

/// The bottom-panel selector: tracked uppercase labels on a flat band, with a signal
/// underline on the active segment. Replaces the system segmented control.
@MainActor final class PanelTabs: NSView {
  private(set) var labels: [String]
  var selectedSegment: Int = 2 {
    didSet { needsDisplay = true; setAccessibilityValue(labels[safe: selectedSegment] ?? "") }
  }
  weak var target: AnyObject?
  var action: Selector?
  private var hovered = -1 { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?
  private let inset: CGFloat = 14
  private let gap: CGFloat = 18

  init(_ labels: [String]) {
    self.labels = labels
    super.init(frame: .zero)
    setAccessibilityRole(.tabGroup)
    setAccessibilityLabel("Bottom panel")
  }
  required init?(coder: NSCoder) { fatalError() }

  func setLabel(_ label: String, forSegment index: Int) {
    guard labels.indices.contains(index), labels[index] != label else { return }
    labels[index] = label
    needsDisplay = true
  }
  private var widths: [CGFloat] {
    labels.map { ceil(($0 as NSString).size(withAttributes: [.font: Style.sectionTitle]).width) }
  }
  private func segment(at point: NSPoint) -> Int {
    var x = inset
    for (index, width) in widths.enumerated() {
      if point.x >= x - gap / 2 && point.x < x + width + gap / 2 { return index }
      x += width + gap
    }
    return -1
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseMoved(with event: NSEvent) {
    hovered = segment(at: convert(event.locationInWindow, from: nil))
  }
  override func mouseExited(with event: NSEvent) { hovered = -1 }
  override func mouseUp(with event: NSEvent) {
    let index = segment(at: convert(event.locationInWindow, from: nil))
    guard index >= 0 else { return }
    selectedSegment = index
    if let action { NSApp.sendAction(action, to: target, from: self) }
  }
  override func draw(_ dirtyRect: NSRect) {
    var x = inset
    for (index, label) in labels.enumerated() {
      let color: NSColor =
        index == selectedSegment ? .labelColor : (index == hovered ? .secondaryLabelColor : .tertiaryLabelColor)
      let text = Style.attributed(
        label, font: Style.sectionTitle, color: color, tracking: 0.9, uppercase: true)
      let size = text.size()
      text.draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2))
      if index == selectedSegment {
        Style.accent.setFill()
        NSRect(x: x, y: 0, width: size.width, height: 2).fill()
      }
      x += size.width + gap
    }
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

/// A list row with flat industrial selection: a quiet wash and a two-pixel signal bar.
/// Used by the file tree, the problems table, and transient navigator lists.
@MainActor final class IndustrialRowView: NSTableRowView {
  var showsMarker = true
  private var hovered = false { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  override func drawBackground(in dirtyRect: NSRect) {
    if isSelected {
      (isEmphasized ? Style.accentSoft : Style.rowSelected).setFill()
      bounds.fill()
      if showsMarker {
        Style.accent.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
      }
    } else if hovered {
      Style.rowHover.setFill()
      bounds.fill()
    }
  }
  override func drawSelection(in dirtyRect: NSRect) {}
}

/// A flat popup: a quiet label with a chevron that opens a menu. Replaces the system
/// bezelled popup button so the chrome keeps one voice.
@MainActor final class IndustrialPopUp: NSControl {
  var titles: [String] = [] {
    didSet {
      if !titles.indices.contains(selectedIndex) { selectedIndex = 0 }
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }
  var selectedIndex = 0 { didSet { needsDisplay = true } }
  var onSelect: ((Int) -> Void)?
  private var hovered = false { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityRole(.popUpButton)
    setAccessibilityLabel("Conversations")
  }
  required init?(coder: NSCoder) { fatalError() }
  override var intrinsicContentSize: NSSize {
    let width = titles.indices.contains(selectedIndex)
      ? (titles[selectedIndex] as NSString).size(withAttributes: [.font: Style.callout]).width : 0
    return NSSize(width: ceil(width) + 28, height: 22)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    let menu = NSMenu()
    for (index, title) in titles.enumerated() {
      let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
      item.tag = index
      item.target = self
      item.state = index == selectedIndex ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(
      positioning: menu.items[safe: selectedIndex],
      at: NSPoint(x: 0, y: bounds.height + 4), in: self)
  }
  @objc private func pick(_ sender: NSMenuItem) {
    selectedIndex = sender.tag
    onSelect?(sender.tag)
  }
  override func draw(_ dirtyRect: NSRect) {
    if hovered {
      Style.rowHover.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: Style.radius, yRadius: Style.radius).fill()
    }
    let title = titles[safe: selectedIndex] ?? ""
    let text = Style.attributed(
      title, font: Style.callout, color: hovered ? .labelColor : .secondaryLabelColor)
    let size = text.size()
    text.draw(at: NSPoint(x: 8, y: bounds.midY - size.height / 2))
    if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
    {
      chevron.isTemplate = true
      let tinted = NSImage(size: chevron.size, flipped: false) { rect in
        chevron.draw(in: rect)
        NSColor.tertiaryLabelColor.set()
        rect.fill(using: .sourceAtop)
        return true
      }
      tinted.draw(
        in: NSRect(
          x: bounds.maxX - chevron.size.width - 8,
          y: bounds.midY - chevron.size.height / 2, width: chevron.size.width,
          height: chevron.size.height))
    }
  }
}

/// A welcome-screen action: icon, label, and its shortcut on one ruled row.
@MainActor final class WelcomeActionRow: NSControl {
  let symbol: String
  let title: String
  let shortcut: String
  var onClick: (() -> Void)?
  private var hovered = false { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?

  init(symbol: String, title: String, shortcut: String) {
    self.symbol = symbol
    self.title = title
    self.shortcut = shortcut
    super.init(frame: .zero)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title + ", " + shortcut)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var intrinsicContentSize: NSSize { NSSize(width: 380, height: 40) }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick?()
    if let action { sendAction(action, to: target) }
  }
  override func draw(_ dirtyRect: NSRect) {
    if hovered {
      Style.rowHover.setFill()
      bounds.fill()
      Style.accent.setFill()
      NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
    Style.rule(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
    let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    icon?.isTemplate = true
    if let icon {
      let tinted = NSImage(size: icon.size, flipped: false) { rect in
        icon.draw(in: rect)
        (self.hovered ? NSColor.labelColor : NSColor.secondaryLabelColor).set()
        rect.fill(using: .sourceAtop)
        return true
      }
      tinted.draw(in: NSRect(x: 2, y: bounds.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
    }
    let label = Style.attributed(
      title, font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
      color: hovered ? .labelColor : .labelColor)
    let labelSize = label.size()
    label.draw(at: NSPoint(x: 26, y: bounds.midY - labelSize.height / 2))
    let key = Style.attributed(
      shortcut, font: Style.monoSmall, color: hovered ? .secondaryLabelColor : .tertiaryLabelColor)
    let keySize = key.size()
    key.draw(
      at: NSPoint(x: bounds.maxX - keySize.width - 2, y: bounds.midY - keySize.height / 2))
  }
}

/// A recent-project row: name over a monospaced path, with the same hover language.
@MainActor final class RecentProjectRow: NSControl {
  let name: String
  let path: String
  var onClick: (() -> Void)?
  private var hovered = false { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?

  init(name: String, path: String) {
    self.name = name
    self.path = path
    super.init(frame: .zero)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Open recent project " + path)
    toolTip = path
  }
  required init?(coder: NSCoder) { fatalError() }
  override var intrinsicContentSize: NSSize { NSSize(width: 380, height: 38) }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick?()
    if let action { sendAction(action, to: target) }
  }
  override func draw(_ dirtyRect: NSRect) {
    if hovered {
      Style.rowHover.setFill()
      bounds.fill()
      Style.accent.setFill()
      NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
    Style.rule(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
    let nameText = Style.attributed(
      name, font: NSFont.systemFont(ofSize: 12, weight: .medium), color: .labelColor)
    nameText.draw(at: NSPoint(x: 2, y: bounds.maxY - 20))
    let pathText = Style.attributed(
      path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
      font: Style.monoSmall, color: .tertiaryLabelColor)
    pathText.draw(at: NSPoint(x: 2, y: 6))
  }
}
