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
  /// Restores split geometry. Must run once the split views have a real frame, otherwise every
  /// divider would be placed against a zero-height container and leave dead space behind.
  func restoreLayout(_ layout: WorkspaceLayout) {
    outer.splitViewItems.first?.isCollapsed = layout.sidebarHidden
    outer.splitViewItems.last?.isCollapsed = layout.inspectorHidden
    let panelItem = vertical.splitViewItems.last
    panelItem?.isCollapsed = layout.panelHidden
    // Only a divider whose neighbouring item is visible can be positioned.
    if outer.splitViewItems.first?.isCollapsed == false {
      outer.splitView.setPosition(
        max(outer.splitViewItems.first?.minimumThickness ?? 220, layout.sidebarWidth),
        ofDividerAt: 0)
    }
    if panelItem?.isCollapsed == false {
      applyPanelHeight(layout.panelHeight)
    }
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
  /// Sizes the bottom panel to `height`, keeping the editor whatever is left.
  func applyPanelHeight(_ height: CGFloat) {
    guard let panelItem = vertical.splitViewItems.last, !panelItem.isCollapsed else { return }
    let available = vertical.view.bounds.height
    guard available > 0 else { return }
    let wanted = max(panelItem.minimumThickness, min(height, available - 160))
    vertical.splitView.setPosition(available - wanted, ofDividerAt: 0)
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
      sidebarWidth: sidebar.view.bounds.width,
      // A collapsed panel reports a zero height, which would be a useless value to restore.
      panelHeight: max(panel.view.bounds.height, lastPanelHeight),
      verticalSplit: editorSplit.splitView.isVertical, splitCount: panes.count,
      positions: positions,
      breakpoints: Dictionary(
        uniqueKeysWithValues: breakpoints.map { ($0.key.path, Array($0.value)) }))
  }
}
