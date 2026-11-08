import AppKit

struct Problem: Sendable {
  let url: URL?
  let path: String
  let line: Int
  let column: Int
  let severity: Int
  let message: String
  let source: String?
}

/// Structured Problems surface: one row per diagnostic, filterable, with double-click
/// navigation. Replaces the old text-only panel.
@MainActor final class ProblemsView: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  private let table = NSTableView()
  private let scroll = NSScrollView()
  private let search = SearchWell(placeholder: "Filter problems")
  private let countLabel = NSTextField(labelWithString: "")
  private let emptyLabel = NSTextField(labelWithString: "No problems detected.")
  private var all: [Problem] = []
  private var filtered: [Problem] = []
  var open: ((Problem) -> Void)?
  var snapshot: [Problem] { filtered }

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = Style.editorBackground.cgColor
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 0
    stack.alignment = .width
    root.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
    ])

    search.field.delegate = self
    countLabel.font = Style.monoSmall
    countLabel.textColor = .tertiaryLabelColor
    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let header = NSStackView(views: [search, countLabel, spacer])
    header.orientation = .horizontal
    header.spacing = 8
    header.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
    stack.addArrangedSubview(header)
    header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let headerRule = HairlineView(.horizontal)
    stack.addArrangedSubview(headerRule)
    headerRule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    headerRule.heightAnchor.constraint(equalToConstant: 1).isActive = true

    table.addTableColumn(NSTableColumn(identifier: .init("problem")))
    table.headerView = nil
    table.rowHeight = Style.rowHeight
    table.intercellSpacing = .zero
    table.style = .fullWidth
    table.selectionHighlightStyle = .none
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openSelected)
    table.setAccessibilityLabel("Problems")
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.documentView = table
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    emptyLabel.font = Style.body
    emptyLabel.textColor = .tertiaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
    ])
    view = root
    update([])
  }

  func themeChanged() {
    view.layer?.backgroundColor = Style.editorBackground.cgColor
    scroll.backgroundColor = Style.editorBackground
    table.reloadData()
  }

  func update(_ problems: [Problem]) {
    all = problems.sorted {
      if $0.severity != $1.severity { return $0.severity < $1.severity }
      if $0.path != $1.path { return $0.path < $1.path }
      return $0.line < $1.line
    }
    applyFilter()
  }

  private func applyFilter() {
    let query = search.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    filtered =
      query.isEmpty
      ? all
      : all.filter {
        $0.message.lowercased().contains(query) || $0.path.lowercased().contains(query)
          || ($0.source ?? "").lowercased().contains(query)
      }
    table.reloadData()
    countLabel.stringValue =
      filtered.count == 1 ? "1 problem" : "\(filtered.count) problems"
    emptyLabel.stringValue =
      all.isEmpty
      ? "No problems detected." : "No problems match “\(search.field.stringValue)”."
    emptyLabel.isHidden = !filtered.isEmpty
  }

  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    let identifier = NSUserInterfaceItemIdentifier("problem")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? ProblemCell ?? ProblemCell()
    cell.identifier = identifier
    cell.configure(filtered[row])
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    IndustrialRowView()
  }

  func controlTextDidChange(_ notification: Notification) {
    applyFilter()
  }

  @objc private func openSelected() {
    guard table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
    open?(filtered[table.selectedRow])
  }
}

@MainActor final class ProblemCell: NSTableCellView {
  private let icon = NSImageView()
  private let message = NSTextField(labelWithString: "")
  private let location = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    icon.translatesAutoresizingMaskIntoConstraints = false
    message.translatesAutoresizingMaskIntoConstraints = false
    location.translatesAutoresizingMaskIntoConstraints = false
    message.font = NSFont.systemFont(ofSize: 11.5)
    message.lineBreakMode = .byTruncatingTail
    location.font = Style.monoSmall
    location.textColor = .tertiaryLabelColor
    location.alignment = .right
    location.lineBreakMode = .byTruncatingMiddle
    addSubview(icon)
    addSubview(message)
    addSubview(location)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 13),
      icon.heightAnchor.constraint(equalToConstant: 13),
      message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
      message.centerYAnchor.constraint(equalTo: centerYAnchor),
      location.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: 10),
      location.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      location.centerYAnchor.constraint(equalTo: centerYAnchor),
      location.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  func configure(_ problem: Problem) {
    let symbol: String
    let color: NSColor
    switch problem.severity {
    case 1:
      symbol = "xmark.octagon.fill"
      color = .systemRed
    case 2:
      symbol = "exclamationmark.triangle.fill"
      color = .systemOrange
    case 3:
      symbol = "info.circle.fill"
      color = .systemBlue
    default:
      symbol = "lightbulb.fill"
      color = .secondaryLabelColor
    }
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.contentTintColor = color
    message.stringValue = problem.message
    location.stringValue = "\(problem.path):\(problem.line + 1):\(problem.column + 1)"
    toolTip = problem.message + (problem.source.map { "\n\($0)" } ?? "")
    setAccessibilityLabel(
      "\(problem.source ?? "Problem"): \(problem.message), \(problem.path) line \(problem.line + 1)")
  }
}
