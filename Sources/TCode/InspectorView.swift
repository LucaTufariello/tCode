import AppKit

/// The right-hand document inspector. It is deliberately a small set of sections rather than a
/// second sidebar: document facts, breakpoints, and workspace context. Flat graphite, ruled
/// header, and monospaced values for anything that is a readout.
@MainActor final class InspectorView: NSView {
  private let stack = NSStackView()
  private var sectionCount = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityLabel("Document inspector")
    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .centerY
    header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
    header.addArrangedSubview(Style.sectionLabel("Inspector"))
    header.heightAnchor.constraint(equalToConstant: 36).isActive = true
    header.translatesAutoresizingMaskIntoConstraints = false
    addSubview(header)
    let rule = HairlineView(.horizontal)
    rule.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rule)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 14, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      rule.topAnchor.constraint(equalTo: header.bottomAnchor),
      rule.leadingAnchor.constraint(equalTo: leadingAnchor),
      rule.trailingAnchor.constraint(equalTo: trailingAnchor),
      rule.heightAnchor.constraint(equalToConstant: 1),
      stack.topAnchor.constraint(equalTo: rule.bottomAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    Style.chrome.setFill()
    bounds.fill()
    Style.verticalRule(NSRect(x: 0, y: 0, width: 1, height: bounds.height))
  }

  func update(
    document: CodeDocument?, root: URL?, breakpoints: Set<Int>, openDocuments: Int
  ) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    sectionCount = 0
    guard let document else {
      let empty = NSTextField(labelWithString: "No document open.")
      empty.font = Style.body
      empty.textColor = .tertiaryLabelColor
      stack.addArrangedSubview(empty)
      return
    }
    addSection("Document")
    addRow("Name", document.title)
    addRow("Path", document.url?.path ?? "Unsaved document", mono: true)
    addRow("Size", "\(document.storage.length.formatted()) UTF-16 units", mono: true)
    addRow("Language", document.languageID?.uppercased() ?? "TEXT")
    addRow("Encoding", document.encoding == .utf8 ? "UTF-8" : "UTF-16")
    addRow("Line endings", document.lineEnding)
    addRow("State", document.isDirty ? "Modified" : "Saved")

    addSection("Breakpoints")
    if breakpoints.isEmpty {
      addRow("Lines", "None")
    } else {
      addRow("Lines", breakpoints.sorted().map(String.init).joined(separator: ", "), mono: true)
    }

    addSection("Workspace")
    addRow("Folder", root?.path ?? "No folder", mono: true)
    addRow("Open editors", "\(openDocuments)")
  }

  private func addSection(_ title: String) {
    if sectionCount > 0 { stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!) }
    sectionCount += 1
    let header = Style.sectionLabel(title)
    stack.addArrangedSubview(header)
    stack.setCustomSpacing(8, after: header)
  }

  private func addRow(_ label: String, _ value: String, mono: Bool = false) {
    let name = NSTextField(labelWithString: label)
    name.font = Style.caption
    name.textColor = .tertiaryLabelColor
    name.widthAnchor.constraint(equalToConstant: 82).isActive = true
    let content = NSTextField(labelWithString: value)
    content.font = mono ? Style.monoSmall : Style.callout
    content.textColor = mono ? .secondaryLabelColor : .labelColor
    content.lineBreakMode = .byTruncatingMiddle
    content.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
    content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    content.toolTip = value
    let row = NSStackView(views: [name, content])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 8
    stack.addArrangedSubview(row)
    stack.setCustomSpacing(5, after: row)
  }
}
