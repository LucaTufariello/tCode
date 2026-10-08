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
    stack.spacing = 8
    let label = NSTextField(labelWithString: navigatorTitle)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    stack.addArrangedSubview(label)
    let sc = NSScrollView()
    sc.hasVerticalScroller = true
    sc.drawsBackground = false
    let column = NSTableColumn(identifier: .init("result"))
    table.addTableColumn(column)
    table.headerView = nil
    table.backgroundColor = .clear
    table.rowSizeStyle = .medium
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
    let label = NSTextField(labelWithString: rows[row])
    label.font = .systemFont(ofSize: 12)
    label.lineBreakMode = .byTruncatingMiddle
    return label
  }
  @objc func chosen() { if table.selectedRow >= 0 { selection(table.selectedRow) } }
}
