import AppKit
import TCodeCore

struct WorkspaceLayout: Codable {
  var activePath: String?
  var sidebarHidden = false
  var panelHidden = true
  var inspectorHidden = true
  var sidebarWidth = 230.0
  var panelHeight = 220.0
  var verticalSplit = true
  var splitCount = 1
  var positions: [String: Int] = [:]
  var breakpoints: [String: [Int]] = [:]
}

extension WorkspaceWindow {
  func restoreLayout(_ layout: WorkspaceLayout) {
    outer.splitViewItems.first?.isCollapsed = layout.sidebarHidden
    outer.splitViewItems.last?.isCollapsed = layout.inspectorHidden
    vertical.splitViewItems.last?.isCollapsed = layout.panelHidden
    outer.splitView.setPosition(layout.sidebarWidth, ofDividerAt: 0)
    vertical.splitView.setPosition(
      max(200, vertical.view.bounds.height - layout.panelHeight), ofDividerAt: 0)
    editorSplit.splitView.isVertical = layout.verticalSplit
    if let doc = active {
      for _ in 1..<max(1, min(4, layout.splitCount)) { addPane(doc) }
      if let path = doc.url?.path, let offset = layout.positions[path] {
        panes.first?.go(to: PositionMap.position(in: doc.text, utf16Offset: offset))
      }
    }
    breakpoints = Dictionary(
      uniqueKeysWithValues: layout.breakpoints.map { (URL(fileURLWithPath: $0.key), Set($0.value)) }
    )
    for pane in panes {
      if let url = pane.document.url { pane.ruler.breakpoints = breakpoints[url] ?? [] }
    }
  }
  func currentLayout() -> WorkspaceLayout {
    var positions: [String: Int] = [:]
    if let path = active?.url?.path, let editor {
      positions[path] = editor.selectedRange().location
    }
    return WorkspaceLayout(
      activePath: active?.url?.path,
      sidebarHidden: outer.splitViewItems.first?.isCollapsed ?? false,
      panelHidden: vertical.splitViewItems.last?.isCollapsed ?? true,
      inspectorHidden: outer.splitViewItems.last?.isCollapsed ?? true,
      sidebarWidth: sidebar.view.bounds.width, panelHeight: panel.view.bounds.height,
      verticalSplit: editorSplit.splitView.isVertical, splitCount: panes.count,
      positions: positions,
      breakpoints: Dictionary(
        uniqueKeysWithValues: breakpoints.map { ($0.key.path, Array($0.value)) }))
  }
}
