import AppKit

@MainActor final class ActionTable: NSTableView {
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76, let action = doubleAction {
      NSApp.sendAction(action, to: target, from: self)
    } else {
      super.keyDown(with: event)
    }
  }
}

@MainActor final class FileOutline: NSOutlineView {
  var openSelection: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {
      openSelection?()
    } else {
      super.keyDown(with: event)
    }
  }
}

/// A transient sidebar list — test results, variable values and similar — shown below the
/// sidebar title. The title row already names the list, so it is not repeated here.
@MainActor final class NavigatorList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  let rows: [String], selection: (Int) -> Void, table = ActionTable(), navigatorTitle: String
  init(title: String, rows: [String], selection: @escaping (Int) -> Void) {
    self.navigatorTitle = title
    self.rows = rows
    self.selection = selection
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)
    if rows.isEmpty {
      let empty = NSTextField(labelWithString: "No results.")
      empty.font = Style.body
      empty.textColor = .tertiaryLabelColor
      empty.alignment = .center
      empty.setAccessibilityLabel(navigatorTitle + ": no results")
      stack.addArrangedSubview(empty)
      empty.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
      view = stack
      return
    }
    let sc = NSScrollView()
    sc.hasVerticalScroller = true
    sc.drawsBackground = false
    let column = NSTableColumn(identifier: .init("result"))
    table.addTableColumn(column)
    table.headerView = nil
    table.backgroundColor = .clear
    table.style = .fullWidth
    table.selectionHighlightStyle = .none
    table.rowSizeStyle = .custom
    table.rowHeight = Style.rowHeight
    table.intercellSpacing = .zero
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(chosen)
    table.setAccessibilityLabel(navigatorTitle)
    sc.documentView = table
    stack.addArrangedSubview(sc)
    sc.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    view = stack
  }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: rows[row])
    label.font = Style.body
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    cell.textField = label
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    IndustrialRowView()
  }
  @objc func chosen() { if table.selectedRow >= 0 { selection(table.selectedRow) } }
}
