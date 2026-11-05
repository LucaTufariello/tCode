import AppKit

/// The right-hand document inspector. It is deliberately a small set of sections rather than a
/// second sidebar: document facts, breakpoints, and workspace context.
@MainActor final class InspectorView: NSVisualEffectView {
  private let stack = NSStackView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .sidebar
    blendingMode = .behindWindow
    state = .followsWindowActiveState
    setAccessibilityLabel("Document inspector")
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.edgeInsets = NSEdgeInsets(top: 18, left: 14, bottom: 14, right: 14)
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  func update(
    document: CodeDocument?, root: URL?, breakpoints: Set<Int>, openDocuments: Int
  ) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    guard let document else {
      let empty = NSTextField(labelWithString: "No document open.")
      empty.font = Style.body
      empty.textColor = .tertiaryLabelColor
      stack.addArrangedSubview(empty)
      return
    }
    addSection("Document")
    addRow("Name", document.title)
    addRow("Path", document.url?.path ?? "Unsaved document")
    addRow("Size", "\(document.storage.length.formatted()) UTF-16 units")
    addRow("Language", document.languageID?.uppercased() ?? "TEXT")
    addRow("Encoding", document.encoding == .utf8 ? "UTF-8" : "UTF-16")
    addRow("Line endings", document.lineEnding)
    addRow("State", document.isDirty ? "Modified" : "Saved")

    addSection("Breakpoints")
    if breakpoints.isEmpty {
      addRow("Lines", "None")
    } else {
      addRow("Lines", breakpoints.sorted().map(String.init).joined(separator: ", "))
    }

    addSection("Workspace")
    addRow("Folder", root?.path ?? "No folder")
    addRow("Open editors", "\(openDocuments)")
  }

  private func addSection(_ title: String) {
    let header = NSTextField(labelWithString: title.uppercased())
    header.font = Style.sectionTitle
    header.textColor = .tertiaryLabelColor
    stack.addArrangedSubview(header)
    stack.setCustomSpacing(6, after: header)
  }

  private func addRow(_ label: String, _ value: String) {
    let name = NSTextField(labelWithString: label)
    name.font = Style.caption
    name.textColor = .secondaryLabelColor
    name.widthAnchor.constraint(equalToConstant: 82).isActive = true
    let content = NSTextField(labelWithString: value)
    content.font = Style.callout
    content.textColor = .labelColor
    content.lineBreakMode = .byTruncatingMiddle
    content.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
    content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    content.toolTip = value
    let row = NSStackView(views: [name, content])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 8
    stack.addArrangedSubview(row)
    stack.setCustomSpacing(4, after: row)
  }
}
