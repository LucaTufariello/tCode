import AppKit
import SwiftTerm
import TCodeCore

typealias Position = TCodeCore.Position

@MainActor final class FileNode {
  var url: URL
  let directory: Bool
  let symlink: Bool
  var children: [FileNode]?
  var loading = false
  init(_ url: URL, directory: Bool, symlink: Bool = false) {
    self.url = url
    self.directory = directory
    self.symlink = symlink
  }
}

@MainActor
final class WorkspaceWindow: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource,
  NSOutlineViewDelegate, NSToolbarDelegate
{
  var root: URL?
  let listenerID = UUID()
  var rootNode: FileNode?
  var documents: [CodeDocument] = []
  var active: CodeDocument?
  var panes: [EditorPane] = []
  let outer = NSSplitViewController(), vertical = NSSplitViewController(),
    editorSplit = NSSplitViewController()
  let sidebar = NSViewController(), content = NSViewController(), panel = NSViewController(),
    inspector = NSViewController()
  let outline = FileOutline()
  var sidebarContent: NSView!
  var sidebarTitle: NSTextField!
  var sidebarIcon: NSImageView!
  var sidebarBack: NSButton!
  var sidebarEmptyState: NSView!
  var tabBar: NSView!
  var tabBarWidth: NSLayoutConstraint!
  var filesScroll: NSScrollView!
  var navigator: NavigatorList?
  let tabs = NSStackView(), contentStack = NSStackView(), panelStack = NSStackView()
  let status = StatusLabel(labelWithString: "Ready")
  var statusInfo: NSTextField!
  var panelAddButton: NSButton!
  let inspectorText = NSTextField(wrappingLabelWithString: "")
  let output = NSTextView(), debugOutput = NSTextView(), problems = NSTextView()
  var terminalViews: [LocalProcessTerminalView] = []
  var selectedPanel = 2
  let panelSelector = NSSegmentedControl(
    labels: ["Terminal", "Problems", "Build Output", "Debug Console"], trackingMode: .selectOne,
    target: nil, action: nil)
  var services: [String: LanguageSession] = [:]
  var languageEnabled = false
  var diagnosticList: [String: [[String: Any]]] = [:]
  var taskProcess: RunningProcess?
  var taskHandle: Task<Void, Never>?
  var searchHandle: Task<Void, Never>?
  var lastPanelHeight: CGFloat = 220
  var pendingLayout: WorkspaceLayout?
  var debugSession: DebugSession?
  var watchExpressions: [String] = []
  var history: [(URL, Position)] = []
  var configuration = RunConfiguration()
  var watchers: [DispatchSourceFileSystemObject] = []
  var watched = Set<URL>()
  var fileWatchers: [UUID: (URL, DispatchSourceFileSystemObject)] = [:]
  var breakpoints: [URL: Set<Int>] = [:]
  var palette: PaletteController?
  var linkHandler: OutputLinkHandler!
  var workspaceRegistry: LanguagePackRegistry?
  var packs: [LanguagePack] { workspaceRegistry?.packs ?? LanguageEnvironment.shared.packs }
  var selectedURL: URL? {
    (outline.item(atRow: outline.selectedRow) as? FileNode)?.url ?? active?.url
  }
  var editor: CodeTextView? { panes.first?.editor }

  /// Smallest window tCode opens at. Anything smaller makes the sidebar, the ruler gutter and
  /// the status bar collide.
  static let minimumContentSize = NSSize(width: 1000, height: 660)
  /// Preferred window size, clamped to whatever screen tCode is launched on.
  static func preferredContentSize() -> NSSize {
    let wanted = NSSize(width: 1560, height: 980)
    guard let visible = NSScreen.main?.visibleFrame else { return wanted }
    return NSSize(
      width: max(minimumContentSize.width, min(wanted.width, visible.width * 0.82)),
      height: max(minimumContentSize.height, min(wanted.height, visible.height * 0.88))
    )
  }
  static func frameKey(_ root: URL?) -> String { "tCode.frame." + (root?.path ?? "Welcome") }
  init(root: URL?) {
    self.root = root
    let w = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.preferredContentSize()),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init(window: w)
    w.delegate = self
    w.title = root?.lastPathComponent ?? "tCode"
    w.subtitle = root == nil ? "Native code editor" : ""
    w.minSize = NSSize(
      width: Self.minimumContentSize.width,
      height: Self.minimumContentSize.height + w.frame.height - w.contentLayoutRect.height)
    // The window frame is remembered by tCode itself rather than by AppKit so that a size saved
    // by an older build is ignored instead of being restored.
    let remembered = UserDefaults.standard.string(forKey: Self.frameKey(root)).map {
      NSRectFromString($0)
    }
    let rememberedFrame =
      remembered.flatMap {
        $0.width >= Self.minimumContentSize.width && $0.height >= w.minSize.height ? $0 : nil
      }
    let wanted =
      rememberedFrame ?? NSRect(origin: .zero, size: Self.preferredContentSize())
    let toolbar = NSToolbar(identifier: "workspace")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    w.toolbar = toolbar
    w.toolbarStyle = .unified
    setup()
    w.contentViewController = outer
    // Installing the split view controller resizes the window to the controller's idea of a good
    // size, so the chosen frame is asserted again afterwards.
    w.setFrame(wanted, display: false)
    if rememberedFrame == nil { w.center() }
    w.autorecalculatesKeyViewLoop = true
    // tCode remembers window frames itself, so AppKit session restoration stays out of it.
    w.isRestorable = false
    NotificationCenter.default.addObserver(
      self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(toolSettingsChanged), name: .tcodeToolSettingsChanged, object: nil)
    if let root { loadWorkspace(root) }
  }
  required init?(coder: NSCoder) { fatalError() }
  /// Deferred split geometry is applied once the window is on screen, where the split views
  /// finally have a height to divide.
  @objc func applyPendingLayout() {
    guard let pending = pendingLayout else { return }
    pendingLayout = nil
    window?.contentView?.layoutSubtreeIfNeeded()
    restoreLayout(pending)
  }
  func setup() {
    // Subviews are built first and the split views are assembled at the very end: a split view
    // item only sizes the view its view controller had when the item was created.
    let side = NSStackView()
    side.orientation = .vertical
    side.spacing = 8
    side.edgeInsets = Style.sidebarInsets
    sidebar.view = container(side)
    let titleRow = NSStackView()
    titleRow.orientation = .horizontal
    titleRow.spacing = 6
    titleRow.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
    sidebarBack = NSButton(
      image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to files")!,
      target: self, action: #selector(backToFiles))
    sidebarBack.bezelStyle = .accessoryBarAction
    sidebarBack.controlSize = .small
    sidebarBack.isHidden = true
    sidebarBack.toolTip = "Back to the project files"
    titleRow.addArrangedSubview(sidebarBack)
    let projectIcon = NSImageView(
      image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!)
    projectIcon.contentTintColor = .controlAccentColor
    projectIcon.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: 12, weight: .semibold)
    sidebarIcon = projectIcon
    projectIcon.setAccessibilityLabel("Project folder")
    titleRow.addArrangedSubview(projectIcon)
    let projectName = NSTextField(labelWithString: "")
    projectName.font = Style.projectTitle
    projectName.lineBreakMode = .byTruncatingMiddle
    projectName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    sidebarTitle = projectName
    titleRow.addArrangedSubview(projectName)
    titleRow.setAccessibilityLabel("Project title")
    side.addArrangedSubview(titleRow)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    filesScroll = scroll
    let column = NSTableColumn(identifier: .init("file"))
    column.title = "Files"
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.headerView = nil
    outline.rowSizeStyle = .medium
    // Source-list styling gives the sidebar its modern rounded selection and insets.
    outline.style = .sourceList
    outline.backgroundColor = .clear
    outline.dataSource = self
    outline.delegate = self
    outline.target = self
    outline.doubleAction = #selector(openSelected)
    outline.openSelection = { [weak self] in
      guard let self, let node = self.outline.item(atRow: self.outline.selectedRow) as? FileNode
      else { return }
      self.openNode(node)
    }
    outline.setAccessibilityLabel("Workspace files")
    outline.registerForDraggedTypes([.fileURL])
    outline.setDraggingSourceOperationMask(.move, forLocal: true)
    let context = NSMenu()
    for (title, id) in [
      ("New File…", "createFile"), ("New Folder…", "newFolder"), ("Rename…", "rename"),
      ("Move…", "move"), ("Duplicate", "duplicate"), ("Move to Trash…", "trash"),
      ("Reveal in Finder", "reveal"), ("Copy Path", "copyPath"),
    ] {
      let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: "")
      item.representedObject = id
      item.target = self
      context.addItem(item)
    }
    outline.menu = context
    scroll.documentView = outline
    // Everything below the project title swaps in and out here: the file tree, the test list,
    // or the "no folder" hint.
    let holder = NSView()
    holder.translatesAutoresizingMaskIntoConstraints = false
    sidebarContent = holder
    side.addArrangedSubview(holder)
    holder.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -16).isActive = true
    replaceNavigator(with: scroll)
    let hint = NSTextField(
      wrappingLabelWithString:
        "No folder open.\n\nOpen one with ⇧⌘O, or create a project with ⌥⌘N.")
    hint.textColor = .tertiaryLabelColor
    hint.font = Style.body
    hint.alignment = .center
    hint.setAccessibilityLabel("No folder open")
    // The hint floats in the middle of the sidebar instead of hugging its top edge.
    let hintHolder = NSView()
    hint.translatesAutoresizingMaskIntoConstraints = false
    hintHolder.addSubview(hint)
    NSLayoutConstraint.activate([
      hint.centerXAnchor.constraint(equalTo: hintHolder.centerXAnchor),
      hint.centerYAnchor.constraint(equalTo: hintHolder.centerYAnchor),
      hint.widthAnchor.constraint(equalTo: hintHolder.widthAnchor, constant: -24),
    ])
    sidebarEmptyState = hintHolder
    contentStack.orientation = .vertical
    contentStack.distribution = .fill
    contentStack.spacing = 0
    content.view = container(contentStack)
    tabs.orientation = .horizontal
    tabs.alignment = .centerY
    tabs.spacing = 4
    tabs.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    // The row scrolls sideways once it is wider than the bar. The scroll view may widen its
    // document view, but the tab stack inside keeps its natural width and simply stays put.
    let strip = TabStripView()
    strip.translatesAutoresizingMaskIntoConstraints = false
    contentStack.addArrangedSubview(strip)
    strip.heightAnchor.constraint(equalToConstant: Style.tabStripHeight).isActive = true
    let tabScroll = NSScrollView()
    tabScroll.hasHorizontalScroller = true
    tabScroll.hasVerticalScroller = false
    tabScroll.autohidesScrollers = true
    tabScroll.drawsBackground = false
    tabScroll.setAccessibilityLabel("Open editors")
    tabScroll.translatesAutoresizingMaskIntoConstraints = false
    strip.addSubview(tabScroll)
    NSLayoutConstraint.activate([
      tabScroll.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
      tabScroll.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
      tabScroll.topAnchor.constraint(equalTo: strip.topAnchor),
      tabScroll.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
    ])
    let tabRow = NSView()
    tabRow.frame = NSRect(x: 0, y: 0, width: 0, height: Style.tabStripHeight)
    tabScroll.documentView = tabRow
    tabBar = tabRow
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabRow.addSubview(tabs)
    tabBarWidth = tabs.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor, constant: 8),
      tabs.topAnchor.constraint(equalTo: tabRow.topAnchor, constant: 6),
      tabs.bottomAnchor.constraint(equalTo: tabRow.bottomAnchor, constant: -6),
      tabBarWidth,
    ])
    vertical.splitView.isVertical = false
    editorSplit.splitView.isVertical = true
    contentStack.addArrangedSubview(vertical.view)
    // The message sits on the left and may truncate; the cursor position, document format and
    // tool state sit on the right, flush with the panel selector above.
    let statusBar = StatusBarView()
    statusInfo = NSTextField(labelWithString: "")
    statusInfo.font = Style.statusInfo
    statusInfo.textColor = .secondaryLabelColor
    statusInfo.alignment = .right
    statusInfo.setAccessibilityLabel("Cursor position and document format")
    status.font = Style.caption
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingTail
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    statusInfo.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    for label in [status, statusInfo!] {
      label.translatesAutoresizingMaskIntoConstraints = false
      statusBar.addSubview(label)
    }
    NSLayoutConstraint.activate([
      status.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 14),
      status.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
      statusInfo.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -14),
      statusInfo.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
      statusInfo.leadingAnchor.constraint(
        greaterThanOrEqualTo: status.trailingAnchor, constant: 12),
    ])
    contentStack.addArrangedSubview(statusBar)
    statusBar.heightAnchor.constraint(equalToConstant: Style.statusBarHeight).isActive = true
    panelStack.orientation = .vertical
    panelStack.distribution = .fill
    panelStack.spacing = 0
    panel.view = panelStack
    let panelHeader = NSStackView()
    panelHeader.edgeInsets = Style.panelHeaderInsets
    panelSelector.target = self
    panelSelector.action = #selector(changePanel(_:))
    panelSelector.selectedSegment = 2
    panelSelector.setAccessibilityLabel("Bottom panel")
    panelHeader.addArrangedSubview(panelSelector)
    panelSelector.controlSize = .small
    panelSelector.font = Style.caption
    panelAddButton = NSButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New terminal")!,
      target: self, action: #selector(newTerminal))
    panelAddButton.bezelStyle = .accessoryBarAction
    panelAddButton.controlSize = .small
    panelAddButton.toolTip = "New zsh terminal"
    panelHeader.addArrangedSubview(panelAddButton)
    let glass = ConcentricGlass()
    glass.contentView = panelHeader
    glass.effectIsInteractive = true
    panelStack.addArrangedSubview(glass)
    glass.heightAnchor.constraint(equalToConstant: 43).isActive = true
    for text in [output, debugOutput, problems] {
      text.isEditable = false
      text.isRichText = false
      text.font = Style.mono
      text.textColor = Style.editorText
      text.backgroundColor = Style.editorBackground
      text.textContainerInset = Style.textInsets
      // Canonical scrollable NSTextView setup: the view grows with its text and tracks the
      // scroll view's width, so long output scrolls instead of staying clipped.
      text.isVerticallyResizable = true
      text.isHorizontallyResizable = false
      text.textContainer?.widthTracksTextView = true
      text.autoresizingMask = [.width]
      text.minSize = .zero
      text.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      text.setAccessibilityLabel(
        text === output ? "Build output" : text === problems ? "Problems" : "Debug console")
    }
    linkHandler = OutputLinkHandler(self)
    output.delegate = linkHandler
    problems.delegate = linkHandler
    debugOutput.delegate = linkHandler
    showPanelContent()
    let heading = NSTextField(labelWithString: "Document")
    heading.font = Style.sectionTitle
    heading.textColor = .secondaryLabelColor
    inspectorText.font = Style.callout
    let details = NSStackView(views: [heading, inspectorText])
    details.orientation = .vertical
    details.alignment = .leading
    details.spacing = 10
    details.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
    details.setAccessibilityLabel("Document inspector")
    inspector.view = details
    showWelcome()
    updateSidebarTitle()
    updateStatus()
    // Now that every view controller owns its view, the split views can size them all.
    outer.splitView.isVertical = true
    let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sideItem.minimumThickness = Style.sidebarMinimumWidth
    sideItem.maximumThickness = Style.sidebarMaximumWidth
    outer.addSplitViewItem(sideItem)
    outer.addSplitViewItem(NSSplitViewItem(viewController: content))
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.minimumThickness = 200
    inspectorItem.isCollapsed = true
    outer.addSplitViewItem(inspectorItem)
    vertical.addSplitViewItem(NSSplitViewItem(viewController: editorSplit))
    let bottom = NSSplitViewItem(viewController: panel)
    bottom.minimumThickness = 120
    bottom.canCollapse = true
    bottom.isCollapsed = true
    vertical.addSplitViewItem(bottom)
    // The stack centres its rows by default, so the rows are pinned to the full column width.
    for v in [strip, vertical.view, statusBar] {
      v.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }
  }
  func container(_ child: NSView) -> NSView {
    let view = NSView()
    view.addSubview(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      child.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    return view
  }
  func showWelcome() {
    let vc = NSViewController()
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 0
    let icon = NSImageView(image: NSApp.applicationIconImage)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.setAccessibilityLabel("tCode")
    icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 76).isActive = true
    let title = NSTextField(labelWithString: "tCode")
    title.font = Style.displayTitle
    let subtitle = NSTextField(labelWithString: "A quiet place to build.")
    subtitle.font = Style.body
    subtitle.textColor = .secondaryLabelColor
    let actions = NSStackView()
    actions.orientation = .vertical
    actions.spacing = 10
    for (label, id) in [
      ("Open Folder…", "openFolder"), ("Create Project…", "newProject"), ("New File", "newFile"),
    ] {
      let b = NSButton(title: label, target: self, action: #selector(welcomeAction(_:)))
      b.identifier = .init(id)
      b.bezelStyle = .rounded
      b.controlSize = .large
      b.widthAnchor.constraint(equalToConstant: 232).isActive = true
      if id == "openFolder" { b.keyEquivalent = "\r" }
      actions.addArrangedSubview(b)
    }
    stack.addArrangedSubview(icon)
    stack.setCustomSpacing(18, after: icon)
    stack.addArrangedSubview(title)
    stack.setCustomSpacing(6, after: title)
    stack.addArrangedSubview(subtitle)
    stack.setCustomSpacing(32, after: subtitle)
    stack.addArrangedSubview(actions)
    let recents =
      (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
      .filter { FileManager.default.fileExists(atPath: $0) }
      .prefix(5)
    if !recents.isEmpty {
      stack.setCustomSpacing(36, after: actions)
      stack.addArrangedSubview(recentCard(Array(recents)))
    }
    let holder = NSView()
    holder.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(greaterThanOrEqualTo: holder.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor, constant: -24),
    ])
    vc.view = holder
    editorSplit.addSplitViewItem(NSSplitViewItem(viewController: vc))
  }
  @objc func openRecentProject(_ sender: NSButton) {
    guard let path = sender.representedPath else { return }
    (NSApp.delegate as? AppDelegate)?.newWindow(URL(fileURLWithPath: path))
  }
  /// Recent projects as a soft card: the name leads, the path whispers underneath.
  func recentCard(_ paths: [String]) -> NSView {
    let card = CardView()
    let rows = NSStackView()
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 2
    for path in paths {
      let button = NSButton(title: "", target: self, action: #selector(openRecentProject(_:)))
      button.isBordered = false
      button.alignment = .left
      button.usesSingleLineMode = false
      button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
      button.imagePosition = .imageLeading
      button.attributedTitle = recentTitle(path)
      button.representedPath = path
      button.toolTip = path
      button.setAccessibilityLabel("Open recent project " + path)
      button.widthAnchor.constraint(equalToConstant: 238).isActive = true
      rows.addArrangedSubview(button)
    }
    let header = NSTextField(labelWithString: "RECENT PROJECTS")
    header.font = Style.sectionTitle
    header.textColor = .tertiaryLabelColor
    let content = NSStackView(views: [header, rows])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 10
    card.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
      content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
      content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
    ])
    return card
  }
  /// Two-line recent-project label: name in primary weight, home-relative path underneath.
  func recentTitle(_ path: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    let result = NSMutableAttributedString()
    result.append(
      NSAttributedString(
        string: URL(fileURLWithPath: path).lastPathComponent + "\n",
        attributes: [
          .font: NSFont.systemFont(ofSize: 12, weight: .medium),
          .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]))
    result.append(
      NSAttributedString(
        string: path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
        attributes: [
          .font: Style.caption, .foregroundColor: NSColor.tertiaryLabelColor,
          .paragraphStyle: paragraph,
        ]))
    return result
  }
  @objc func welcomeAction(_ sender: NSButton) {
    if sender.identifier?.rawValue == "newFile" {
      perform("newFile")
    } else {
      let item = NSMenuItem()
      item.identifier = sender.identifier
      (NSApp.delegate as? AppDelegate)?.menuAction(item)
    }
  }
  func loadWorkspace(_ url: URL) {
    if UserDefaults.standard.bool(forKey: "workspaceLanguagePacks." + url.path) {
      workspaceRegistry = LanguagePackRegistry(
        directory: languageRegistry.directory, bundledPacks: LanguagePack.bundled())
      _ = workspaceRegistry?.reload(workspace: url, allowWorkspacePacks: true)
    }
    rootNode = FileNode(url, directory: true)
    reloadTree()
    updateSidebarTitle()
    watchExpressions = UserDefaults.standard.stringArray(forKey: "watches." + url.path) ?? []
    var recent = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
    recent.removeAll { $0 == url.path }
    recent.insert(url.path, at: 0)
    UserDefaults.standard.set(Array(recent.prefix(20)), forKey: "recentProjects")
    // Tabs remembered for files that no longer exist are forgotten instead of restored empty.
    let remembered = UserDefaults.standard.stringArray(forKey: "tabs." + url.path) ?? []
    let paths = remembered.filter { FileManager.default.fileExists(atPath: $0) }
    if paths.count != remembered.count {
      UserDefaults.standard.set(paths, forKey: "tabs." + url.path)
    }
    let layout = UserDefaults.standard.data(forKey: "layout." + url.path).flatMap {
      try? JSONDecoder().decode(WorkspaceLayout.self, from: $0)
    }
    Task {
      for path in paths {
        do { add(try await DocumentPool.shared.open(URL(fileURLWithPath: path))) } catch {
          appendOutput("Could not restore \(path): \(error.localizedDescription)\n")
        }
      }
      if let layout {
        if let doc = documents.first(where: { $0.url?.path == layout.activePath }) { select(doc) }
        lastPanelHeight = layout.panelHeight
        // Split geometry is only meaningful once the window is on screen and its split views
        // have a real height.
        if window?.isVisible == true {
          restoreLayout(layout)
        } else {
          pendingLayout = layout
        }
      }
    }
    watch(url)
    let configURL = url.appendingPathComponent(".tcode/run.json")
    Task {
      if let data = try? await Task.detached(operation: { try Data(contentsOf: configURL) }).value,
        let config = try? JSONDecoder().decode(RunConfiguration.self, from: data)
      {
        configuration = config
      }
    }
  }
  func watch(_ url: URL) {
    guard watched.insert(url).inserted else { return }
    let fd = Darwin.open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler { [weak self] in Task { @MainActor in self?.reloadTree() } }
    source.setCancelHandler { Darwin.close(fd) }
    source.resume()
    watchers.append(source)
  }
  func reloadTree() {
    guard let node = rootNode else { return }
    loadChildren(node, refresh: true)
  }
  func loadChildren(_ node: FileNode, refresh: Bool = false) {
    guard !node.loading, node.directory, !node.symlink, node.children == nil || refresh else {
      return
    }
    node.loading = true
    let url = node.url
    Task {
      do {
        let exclusions = EditorConfiguration.load(root: root, file: nil).exclusions
        let entries = try await Task.detached { try FileIO.children(url, excluding: exclusions) }
          .value
        let existing = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.url, $0) })
        node.children = entries.map {
          existing[$0.url] ?? FileNode($0.url, directory: $0.directory, symlink: $0.symlink)
        }
        node.loading = false
        outline.reloadItem(node === rootNode ? nil : node, reloadChildren: true)
        if refresh {
          for child in node.children ?? [] where child.children != nil {
            loadChildren(child, refresh: true)
          }
        }
      } catch {
        node.loading = false
        report(error)
      }
    }
  }
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    ((item as? FileNode) ?? rootNode)?.children?.count ?? 0
  }
  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    ((item as? FileNode) ?? rootNode)!.children![index]
  }
  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    guard let n = item as? FileNode else { return false }
    return n.directory && !n.symlink
  }
  func outlineViewItemWillExpand(_ notification: Notification) {
    if let n = notification.userInfo?["NSObject"] as? FileNode {
      loadChildren(n)
      watch(n.url)
    }
  }
  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    guard let n = item as? FileNode else { return nil }
    let cell = NSTableCellView()
    let image = NSImageView(
      image: NSImage(
        systemSymbolName: n.directory ? "folder" : symbol(n.url.pathExtension),
        accessibilityDescription: nil)!)
    image.contentTintColor = n.directory ? .controlAccentColor : .secondaryLabelColor
    let label = NSTextField(labelWithString: n.url.lastPathComponent)
    label.lineBreakMode = .byTruncatingMiddle
    label.font = Style.body
    let stack = NSStackView(views: [image, label])
    stack.spacing = 7
    cell.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    image.widthAnchor.constraint(equalToConstant: 16).isActive = true
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    cell.textField = label
    cell.imageView = image
    return cell
  }
  func symbol(_ ext: String) -> String {
    [
      "swift": "swift", "py": "chevron.left.forwardslash.chevron.right", "cpp": "c.square",
      "h": "h.square", "json": "curlybraces", "md": "text.alignleft",
    ][ext] ?? "doc.text"
  }
  func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any)
    -> NSPasteboardWriting?
  { (item as? FileNode)?.url as NSURL? }
  func outlineView(
    _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
    proposedChildIndex index: Int
  ) -> NSDragOperation {
    let n = (item as? FileNode) ?? rootNode
    return n?.directory == true && n?.symlink == false ? .move : []
  }
  func outlineView(
    _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int
  ) -> Bool {
    guard let parent = ((item as? FileNode) ?? rootNode)?.url,
      let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
    else { return false }
    Task {
      for url in urls {
        do {
          let to = try await Task.detached {
            try FileIO.move(url, into: parent, name: url.lastPathComponent)
          }.value
          DocumentPool.shared.moved(from: url, to: to)
        } catch { report(error) }
      }
      reloadTree()
    }
    return true
  }
  @objc func openSelected() {
    if let n = outline.item(atRow: outline.clickedRow) as? FileNode { openNode(n) }
  }
  func openNode(_ node: FileNode) {
    if node.directory {
      outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
    } else {
      open(node.url)
    }
  }
  @objc func contextAction(_ item: NSMenuItem) {
    if outline.clickedRow >= 0 {
      outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false)
    }
    perform(item.representedObject as? String ?? "")
  }
  func replaceNavigator(with view: NSView) {
    for child in sidebarContent.subviews { child.removeFromSuperview() }
    view.translatesAutoresizingMaskIntoConstraints = false
    sidebarContent.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor),
      view.topAnchor.constraint(equalTo: sidebarContent.topAnchor),
      view.bottomAnchor.constraint(equalTo: sidebarContent.bottomAnchor),
    ])
  }
  func updateSidebarTitle() {
    sidebarTitle.stringValue = root?.lastPathComponent ?? "tCode"
    sidebarTitle.toolTip = root?.path ?? "No folder open"
    sidebarIcon.isHidden = false
    sidebarIcon.contentTintColor = .controlAccentColor
    sidebarBack.isHidden = true
    navigator = nil
    replaceNavigator(with: root == nil ? sidebarEmptyState : filesScroll)
  }
  @objc func backToFiles() { updateSidebarTitle() }
  func showNavigator(
    title: String, rows: [String], commands: [String] = [], select: ((Int) -> Void)? = nil
  ) {
    let list = NavigatorList(title: title, rows: rows) { [weak self] index in
      if let select {
        select(index)
      } else if index < commands.count {
        self?.perform(commands[index])
      }
    }
    navigator = list
    replaceNavigator(with: list.view)
    sidebarTitle.stringValue = title
    sidebarTitle.toolTip = title
    sidebarIcon.isHidden = true
    sidebarBack.isHidden = false
  }
  func open(
    _ url: URL, position: Position? = nil, encoding: String = "utf-16", recordHistory: Bool = true
  ) {
    Task {
      do {
        let doc = try await DocumentPool.shared.open(url)
        if position != nil, recordHistory, let old = active?.url, let editor {
          history.append(
            (
              old,
              PositionMap.position(in: editor.string, utf16Offset: editor.selectedRange().location)
            ))
        }
        add(doc, recordHistory: recordHistory && position == nil)
        if let position { panes.first?.go(to: position, encoding: encoding) }
      } catch { report(error) }
    }
  }
  func add(_ document: CodeDocument, recordHistory: Bool = true) {
    if !documents.contains(where: { $0 === document }) { documents.append(document) }
    document.listeners[listenerID] = { [weak self, weak document] in
      guard let self else { return }
      self.updateTabs()
      self.updateStatus()
      if let document {
        self.watchDocument(document)
        self.configureLanguage(document)
        if self.active === document {
          self.window?.representedURL = document.url
          for pane in self.panes {
            pane.editor.setAccessibilityLabel("Code editor, " + document.title)
            pane.editor.comment = self.recognizeLanguage(document)?.pack.editor.lineComment ?? ""
          }
        }
      }
      if UserDefaults.standard.bool(forKey: "autosave"), let document, document.url != nil {
        document.autosaveTask?.cancel()
        document.autosaveTask = Task {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, let url = document.url else { return }
          do { try await document.save(to: url) } catch {
            self.status.stringValue = error.localizedDescription
          }
        }
      }
    }
    watchDocument(document)
    select(document, recordHistory: recordHistory)
    persist()
  }
  func watchDocument(_ doc: CodeDocument) {
    guard let url = doc.url else { return }
    if let existing = fileWatchers[doc.id], existing.0 == url { return }
    fileWatchers.removeValue(forKey: doc.id)?.1.cancel()
    let fd = Darwin.open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler { [weak self, weak doc] in
      Task { @MainActor in
        guard let self, let doc else { return }
        let events = self.fileWatchers[doc.id]?.1.data
        try? await Task.sleep(for: .milliseconds(100))
        self.checkExternal(doc)
        if events?.contains(.rename) == true || events?.contains(.delete) == true {
          self.fileWatchers.removeValue(forKey: doc.id)?.1.cancel()
          self.watchDocument(doc)
        }
      }
    }
    source.setCancelHandler { Darwin.close(fd) }
    fileWatchers[doc.id] = (url, source)
    source.resume()
  }
  func checkExternal(_ doc: CodeDocument) {
    guard let url = doc.url, !doc.isSaving else { return }
    Task {
      let bytes = try? await Task.detached { try Data(contentsOf: url) }.value
      if bytes != doc.baseline {
        status.stringValue =
          "\(doc.title) changed on disk — Save to compare, or Reload from the command palette"
      }
    }
  }
  func select(_ document: CodeDocument, recordHistory: Bool = true) {
    if recordHistory, active !== document, let old = active?.url, let editor {
      history.append(
        (old, PositionMap.position(in: editor.string, utf16Offset: editor.selectedRange().location))
      )
    }
    active = document
    configureLanguage(document)
    for pane in panes { pane.detach() }
    for item in editorSplit.splitViewItems { editorSplit.removeSplitViewItem(item) }
    panes.removeAll()
    addPane(document)
    updateTabs()
    updateStatus()
    window?.representedURL = document.url
    window?.makeFirstResponder(editor)
    if languageEnabled { activateLanguage(document) }
  }
  func addPane(_ document: CodeDocument) {
    let pane = EditorPane(document: document)
    panes.append(pane)
    editorSplit.addSplitViewItem(NSSplitViewItem(viewController: pane))
    _ = pane.view
    pane.editor.comment = recognizeLanguage(document)?.pack.editor.lineComment ?? ""
    let config = EditorConfiguration.load(
      root: root, file: document.url, languageDefaults: recognizeLanguage(document)?.pack.editor)
    pane.editor.indent = config.useTabs ? "\t" : String(repeating: " ", count: config.indentSize)
    pane.editor.isHorizontallyResizable = !config.wrap
    pane.scroll.hasHorizontalScroller = !config.wrap
    pane.editor.textContainer?.widthTracksTextView = config.wrap
    if !config.wrap { pane.editor.textContainer?.containerSize.width = 100000 }
    if let url = document.url { pane.ruler.breakpoints = breakpoints[url] ?? [] }
    pane.selectionChanged = { [weak self] position in self?.updateStatus(position) }
    pane.syntaxChanged = { [weak self] in self?.updateStatus() }
    pane.ruler.breakpointChanged = { [weak self, weak pane] _ in
      guard let self, let url = pane?.document.url, let pane else { return }
      self.breakpoints[url] = pane.ruler.breakpoints
      self.debugSession?.setBreakpoints(url, lines: Array(pane.ruler.breakpoints))
    }
  }
  func updateTabs() {
    for v in tabs.arrangedSubviews {
      tabs.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    for doc in documents {
      let tab = TabButton(document: doc)
      tab.target = self
      tab.action = #selector(tabSelected(_:))
      tab.selected = active === doc
      tab.modified = doc.modified
      tab.toolTip = doc.url?.path ?? "Untitled document"
      tabs.addArrangedSubview(tab)
    }
    // Tabs keep their natural width and sit side by side from the left instead of being
    // stretched apart to fill the bar.
    let widths = tabs.arrangedSubviews.map(\.fittingSize.width)
    let natural = widths.reduce(0, +) + tabs.spacing * CGFloat(max(0, widths.count - 1))
    tabBarWidth.constant = natural
    tabBar.frame.size.width = max(natural + 16, tabBar.frame.width)
  }
  @objc func tabSelected(_ button: TabButton) {
    select(button.document)
  }
  func closeTab(_ doc: CodeDocument) {
    guard documents.contains(where: { $0 === doc }) else { return }
    if doc !== active { select(doc, recordHistory: false) }
    closeTab()
  }
  func closeOtherTabs(_ doc: CodeDocument) {
    for other in documents where other !== doc { closeTab(other) }
  }
  func closeAllTabs() { for doc in documents { closeTab(doc) } }
  func updateStatus(_ position: Position? = nil) {
    guard let doc = active else {
      status.stringValue = root?.path ?? "Open a folder or create a file to begin"
      statusInfo.stringValue = ""
      inspectorText.stringValue = ""
      return
    }
    let p =
      position
      ?? PositionMap.position(in: doc.text, utf16Offset: editor?.selectedRange().location ?? 0)
    let lineEnding = doc.text.contains("\r\n") ? "CRLF" : doc.text.contains("\r") ? "CR" : "LF"
    let indent = editor?.indent ?? "    "
    let tools =
      doc.large
      ? "Large file mode"
      : [
        doc.languageSession?.ready == true ? "LSP connected" : "",
        doc.syntaxStatus == "Tree-sitter" ? "Tree-sitter" : "",
        debugSession?.stopped == true ? "Debugger paused" : "",
      ].filter { !$0.isEmpty }.joined(separator: " · ")
    statusInfo.stringValue = [
      recognizeLanguage(doc)?.association.languageID.uppercased() ?? "TEXT",
      "Ln \(p.line+1), Col \(p.character+1)",
      indent.first == "\t" ? "Tabs: \(indent.count)" : "Spaces: \(indent.count)",
      doc.encoding == .utf8 ? "UTF-8" : "UTF-16", lineEnding, tools,
    ].filter { !$0.isEmpty }.joined(separator: "   ")
    inspectorText.attributedStringValue = inspectorSummary(doc)
    inspectorText.toolTip = doc.syntaxStatus
  }
  /// The document inspector: name first, then the facts, each line a step quieter.
  func inspectorSummary(_ doc: CodeDocument) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    let result = NSMutableAttributedString()
    result.append(
      NSAttributedString(
        string: doc.title + "\n",
        attributes: [
          .font: Style.projectTitle, .foregroundColor: NSColor.labelColor,
          .paragraphStyle: paragraph,
        ]))
    result.append(
      NSAttributedString(
        string: (doc.url?.path ?? "Unsaved document") + "\n\n",
        attributes: [
          .font: Style.callout, .foregroundColor: NSColor.secondaryLabelColor,
          .paragraphStyle: paragraph,
        ]))
    result.append(
      NSAttributedString(
        string: "\(doc.storage.length.formatted()) UTF-16 units · "
          + "\(doc.modified ? "Modified" : "Saved")\n",
        attributes: [
          .font: Style.callout, .foregroundColor: NSColor.secondaryLabelColor,
          .paragraphStyle: paragraph,
        ]))
    result.append(
      NSAttributedString(
        string: recognizeLanguage(doc)?.pack.name
          ?? "Text — choose a language with Editor → Document Language",
        attributes: [
          .font: Style.callout, .foregroundColor: NSColor.tertiaryLabelColor,
          .paragraphStyle: paragraph,
        ]))
    return result
  }
  func save(_ doc: CodeDocument, asNew: Bool = false, onSuccess: (() -> Void)? = nil) {
    var destination = asNew ? nil : doc.url
    if destination == nil {
      let p = NSSavePanel()
      p.nameFieldStringValue = doc.title
      p.directoryURL = root
      if p.runModal() != .OK { return }
      destination = p.url
    }
    guard let destination else { return }
    Task {
      do {
        try await doc.save(
          to: destination,
          overwrite: asNew && FileManager.default.fileExists(atPath: destination.path))
        reloadTree()
        if let service = doc.languageSession {
          try? await service.connection.notify(
            "textDocument/didSave", params: ["textDocument": ["uri": destination.absoluteString]])
        }
        updateTabs()
        if languageEnabled { activateLanguage(doc) }
        onSuccess?()
      } catch { resolveConflict(doc, error: error) }
    }
  }
  func resolveConflict(_ doc: CodeDocument, error: Error) {
    let alert = NSAlert()
    alert.messageText = "Save needs attention"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "Compare with Disk")
    alert.addButton(withTitle: "Keep Editing")
    alert.addButton(withTitle: "Reload from Disk")
    alert.addButton(withTitle: "Save a Copy…")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      if let url = doc.url {
        Task {
          if let text = try? await Task.detached(operation: {
            try TextFile(data: Data(contentsOf: url)).text
          }).value {
            showText(
              "Disk Version — " + doc.title,
              text: "YOUR BUFFER\n\n" + doc.text + "\n\nDISK VERSION\n\n" + text)
          }
        }
      }
    case .alertThirdButtonReturn:
      Task {
        do {
          try await CodeDocument.recovery.write(doc.recoveryRecord())
          try await doc.reload()
        } catch { report(error) }
      }
    case NSApplication.ModalResponse(rawValue: 1003): save(doc, asNew: true)
    default: break
    }
  }
  func closeTab() {
    guard let doc = active else { return }
    let sharedElsewhere =
      (NSApp.delegate as? AppDelegate)?.windows.contains {
        $0 !== self && $0.documents.contains(where: { $0 === doc })
      } ?? false
    if doc.modified && !sharedElsewhere {
      let a = NSAlert()
      a.messageText = "Save changes to \(doc.title)?"
      a.informativeText = "You can also keep an unsaved recovery copy for the next launch."
      a.addButton(withTitle: "Save…")
      a.addButton(withTitle: "Keep Recovery Copy")
      a.addButton(withTitle: "Discard Changes")
      a.addButton(withTitle: "Cancel")
      switch a.runModal() {
      case .alertFirstButtonReturn:
        save(doc, onSuccess: { [weak self] in if self?.active === doc { self?.closeTab() } })
        return
      case .alertSecondButtonReturn:
        Task { try? await CodeDocument.recovery.write(doc.recoveryRecord()) }
      case .alertThirdButtonReturn:
        doc.recoveryTask?.cancel()
        Task { try? await CodeDocument.recovery.remove(doc.id) }
        DocumentPool.shared.documents.removeAll { $0 === doc }
      default: return
      }
    }
    doc.listeners.removeValue(forKey: listenerID)
    fileWatchers.removeValue(forKey: doc.id)?.1.cancel()
    if !sharedElsewhere {
      doc.languageSession?.close(doc, url: doc.url)
      doc.languageSession = nil
      DocumentPool.shared.documents.removeAll { $0 === doc }
      Task { await SyntaxClient.shared.close(doc.id) }
    }
    documents.removeAll { $0 === doc }
    if let next = documents.last {
      select(next)
    } else {
      active = nil
      for pane in panes { pane.detach() }
      panes.removeAll()
      for item in editorSplit.splitViewItems { editorSplit.removeSplitViewItem(item) }
      showWelcome()
      updateTabs()
      updateStatus()
    }
    persist()
  }
  @objc func activated() {
    applyPendingLayout()
    reloadTree()
    if let doc = active { checkExternal(doc) }
  }
  func windowDidBecomeKey(_ notification: Notification) {
    applyPendingLayout()
  }
  @objc func toolSettingsChanged() {
    for service in services.values { service.stop() }
    services.removeAll()
    for doc in documents { doc.languageSession = nil }
    diagnosticList.removeAll()
    refreshProblems()
    languageEnabled = false
    if let root, UserDefaults.standard.bool(forKey: "workspaceLanguagePacks." + root.path) {
      if workspaceRegistry == nil {
        workspaceRegistry = LanguagePackRegistry(
          directory: languageRegistry.directory, bundledPacks: LanguagePack.bundled())
      }
      _ = workspaceRegistry?.reload(workspace: root, allowWorkspacePacks: true)
    } else {
      workspaceRegistry = nil
    }
    for doc in documents { configureLanguage(doc) }
    updateStatus()
  }
  func report(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.runModal()
  }
  func input(_ title: String, defaultValue: String = "", detail: String = "") -> String? {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = detail
    let field = NSTextField(string: defaultValue)
    field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
    a.accessoryView = field
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = field
    return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
  }
  func showText(_ title: String, text: String) {
    let content = NSRect(x: 0, y: 0, width: 800, height: 580)
    let w = NSWindow(
      contentRect: content, styleMask: [.titled, .closable, .resizable], backing: .buffered,
      defer: false)
    w.title = title
    let sc = NSScrollView(frame: content)
    sc.hasVerticalScroller = true
    sc.autohidesScrollers = true
    sc.backgroundColor = Style.editorBackground
    let tv = NSTextView(frame: sc.contentView.bounds)
    tv.string = text
    tv.isEditable = false
    tv.font = Style.mono
    tv.textColor = Style.editorText
    tv.backgroundColor = Style.editorBackground
    tv.textContainerInset = Style.textInsets
    tv.textContainer?.lineFragmentPadding = 0
    // Canonical scrollable text view setup, so long diffs and logs actually scroll.
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    tv.textContainer?.widthTracksTextView = true
    tv.minSize = NSZeroSize
    tv.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    sc.documentView = tv
    w.contentView = sc
    w.backgroundColor = Style.editorBackground
    w.minSize = NSSize(width: 480, height: 320)
    w.center()
    w.isReleasedWhenClosed = false
    w.makeKeyAndOrderFront(nil)
  }
  func choose(_ title: String, items: [String], action: @escaping (Int) -> Void) {
    palette = PaletteController(title: title, items: items, action: action)
    if let window, let p = palette?.window { window.beginSheet(p) }
  }
  func persist() {
    syncPanelHeight()
    guard let root else { return }
    UserDefaults.standard.set(documents.compactMap { $0.url?.path }, forKey: "tabs." + root.path)
    if let data = try? JSONEncoder().encode(currentLayout()) {
      UserDefaults.standard.set(data, forKey: "layout." + root.path)
    }
  }
  func cleanup(stopTools: Bool = true) {
    taskHandle?.cancel()
    taskProcess?.cancel()
    searchHandle?.cancel()
    watchers.forEach { $0.cancel() }
    watchers.removeAll()
    fileWatchers.values.forEach { $0.1.cancel() }
    fileWatchers.removeAll()
    for doc in documents { doc.listeners.removeValue(forKey: listenerID) }
    let others = (NSApp.delegate as? AppDelegate)?.windows.filter { $0 !== self } ?? []
    for doc in documents
    where !others.contains(where: { window in window.documents.contains { $0 === doc } }) {
      Task { await SyntaxClient.shared.close(doc.id) }
    }
    if stopTools {
      for s in services.values { s.stop() }
      debugSession?.stop()
    }
    terminalViews.forEach { $0.terminate() }
  }
  func shutdown() async {
    cleanup(stopTools: false)
    for service in services.values { await service.shutdown() }
    await debugSession?.shutdown()
    if let taskHandle { _ = await taskHandle.result }
  }
  func windowWillClose(_ notification: Notification) {
    if let frame = window?.frame {
      UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey(root))
    }
    persist()
    cleanup()
    (NSApp.delegate as? AppDelegate)?.windows.removeAll { $0 === self }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    for doc in documents where doc.modified {
      let record = doc.recoveryRecord()
      Task { try? await CodeDocument.recovery.write(record) }
    }
    return true
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .toggleSidebar, .flexibleSpace, .init("quickOpen"), .init("run"), .init("panel"),
      .init("inspector"),
    ]
  }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarAllowedItemIdentifiers(toolbar)
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar: Bool
  ) -> NSToolbarItem? {
    if id == .toggleSidebar { return nil }
    let names = [
      "quickOpen": ("magnifyingglass", "Quick Open"), "run": ("play", "Run"),
      "panel": ("rectangle.bottomthird.inset.filled", "Toggle Bottom Panel"),
      "inspector": ("sidebar.right", "Toggle Inspector"),
    ]
    guard let (symbol, title) = names[id.rawValue] else { return nil }
    let item = NSToolbarItem(itemIdentifier: id)
    item.label = title
    item.toolTip = title
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    item.target = self
    item.action = #selector(toolbarAction(_:))
    item.isBordered = true
    return item
  }
  @objc func toolbarAction(_ sender: NSToolbarItem) { perform(sender.itemIdentifier.rawValue) }
  @objc func changePanel(_ sender: NSSegmentedControl) {
    selectedPanel = sender.selectedSegment
    showPanelContent()
  }
  func showPanelContent() {
    while panelStack.arrangedSubviews.count > 1 {
      let v = panelStack.arrangedSubviews.last!
      panelStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    // The + button starts a terminal, so it only belongs to the Terminal segment.
    panelAddButton?.isHidden = selectedPanel != 0
    if selectedPanel == 0 {
      if let terminal = terminalViews.last {
        panelStack.addArrangedSubview(terminal)
        terminal.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
      } else {
        panelStack.addArrangedSubview(
          emptyState(
            symbol: "terminal", title: "No terminal sessions yet",
            button: "Start zsh Terminal", action: #selector(newTerminal)))
      }
    } else {
      let tv = selectedPanel == 1 ? problems : selectedPanel == 2 ? output : debugOutput
      let sc = NSScrollView()
      sc.hasVerticalScroller = true
      sc.autohidesScrollers = true
      sc.drawsBackground = true
      sc.backgroundColor = Style.editorBackground
      sc.documentView = tv
      tv.autoresizingMask = [.width]
      panelStack.addArrangedSubview(sc)
      sc.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
    }
  }
  /// Centered empty state: symbol, one-line explanation, and an optional action button.
  func emptyState(symbol: String, title: String, button: String? = nil, action: Selector? = nil)
    -> NSView
  {
    let image = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
    image.contentTintColor = .tertiaryLabelColor
    image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    let label = NSTextField(labelWithString: title)
    label.font = Style.body
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    let stack = NSStackView(views: [image, label])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    if let button, let action {
      let b = NSButton(title: button, target: self, action: action)
      b.bezelStyle = .rounded
      stack.setCustomSpacing(14, after: label)
      stack.addArrangedSubview(b)
    }
    let holder = NSView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
    ])
    return holder
  }
  func showBottom(_ index: Int) {
    vertical.splitViewItems.last?.isCollapsed = false
    selectedPanel = index
    panelSelector.selectedSegment = index
    showPanelContent()
    window?.contentView?.layoutSubtreeIfNeeded()
    applyPanelHeight(lastPanelHeight)
    syncPanelHeight()
  }
  func syncPanelHeight() {
    if vertical.splitViewItems.last?.isCollapsed == false, panel.view.bounds.height > 0 {
      lastPanelHeight = panel.view.bounds.height
    }
  }
  @objc func newTerminal() {
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
    terminal.font = Style.mono
    // The terminal shares the editor's paper so the whole workspace reads as one surface.
    terminal.nativeBackgroundColor = Style.editorBackground
    terminal.nativeForegroundColor = Style.editorText
    terminal.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
    terminal.setAccessibilityLabel("zsh terminal session \(terminalViews.count+1)")
    terminalViews.append(terminal)
    showBottom(0)
    terminal.startProcess(
      executable: "/bin/zsh", args: ["-l"],
      environment: ToolLocator.environment.map { "\($0)=\($1)" } + ["TERM=xterm-256color"],
      currentDirectory: root?.path ?? NSHomeDirectory())
    window?.makeFirstResponder(terminal)
  }
  func appendOutput(_ text: String, debug: Bool = false) {
    let tv = debug ? debugOutput : output
    tv.textStorage?.append(
      NSAttributedString(
        string: text,
        attributes: [
          .font: Style.mono,
          .foregroundColor: Style.editorText,
        ]))
    if let storage = tv.textStorage, storage.length > 2_000_000 {
      storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 1_500_000))
    }
    linkHandler.decorate(tv)
    tv.scrollToEndOfDocument(nil)
  }
}

/// The tab strip surface: a quiet band one shade away from the editor, so the selected tab
/// reads as lifted and continuous with the page below.
@MainActor final class TabStripView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    Style.tabStripBackground.setFill()
    bounds.fill()
  }
}

/// A hairline closes the window at the top of the status bar; the text stays quiet.
@MainActor final class StatusBarView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    Style.subtleSeparator.setFill()
    NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
  }
}

/// A quiet rounded card: the welcome screen's recent projects and similar grouped rows.
@MainActor final class CardView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Style.cardRadius,
      yRadius: Style.cardRadius)
    Style.card.setFill()
    path.fill()
    Style.separator.setStroke()
    path.lineWidth = 1
    path.stroke()
  }
}

/// One-line workspace message with a matching tooltip, so text that truncates in a narrow
/// window stays reachable. Every `status.stringValue = …` assignment keeps the tooltip in sync.
@MainActor final class StatusLabel: NSTextField {
  override var stringValue: String {
    didSet { toolTip = stringValue }
  }
}

private var pathAssociation: UInt8 = 0
extension NSButton {
  var representedPath: String? {
    get { objc_getAssociatedObject(self, &pathAssociation) as? String }
    set {
      objc_setAssociatedObject(
        self, &pathAssociation, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}

/// A single editor tab, drawn as a quiet rounded chip: the selected tab carries the editor's own
/// surface so it reads as part of the page below, unselected tabs fade back, and hovering lifts
/// them. A dot marks unsaved changes. Tabs carry no close button; they are dismissed with
/// \u{2318}W or from the tab context menu.
@MainActor final class TabButton: NSControl {
  let document: CodeDocument
  var modified = false {
    didSet {
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }
  var selected = false {
    didSet {
      invalidateIntrinsicContentSize()
      setAccessibilityValue(selected ? "selected" : "")
      needsDisplay = true
    }
  }
  private var hovered = false {
    didSet { needsDisplay = true }
  }
  private var hoverTracking: NSTrackingArea?
  init(document: CodeDocument) {
    self.document = document
    super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Style.tabHeight))
    setAccessibilityRole(.button)
    setAccessibilityLabel("Editor tab, " + document.title)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var intrinsicContentSize: NSSize {
    let font = Style.tabTitle(selected: selected)
    let width = ceil((document.title as NSString).size(withAttributes: [.font: font]).width)
    return NSSize(
      width: min(width + 20 + (modified ? 12 : 0), Style.tabMaxWidth), height: Style.tabHeight)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self,
      userInfo: nil)
    addTrackingArea(area)
    hoverTracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)), let action else {
      return super.mouseUp(with: event)
    }
    sendAction(action, to: target)
  }
  override func draw(_ dirtyRect: NSRect) {
    let chip = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(
      roundedRect: chip, xRadius: Style.tabRadius, yRadius: Style.tabRadius)
    if selected {
      Style.editorBackground.setFill()
      path.fill()
      Style.separator.setStroke()
      path.lineWidth = 1
      path.stroke()
    } else if hovered {
      NSColor.labelColor.withAlphaComponent(0.06).setFill()
      path.fill()
    }
    let font = Style.tabTitle(selected: selected)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: selected ? Style.editorText : NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]
    let height = ceil(font.ascender - font.descender)
    let rect = NSRect(
      x: chip.minX + 10, y: chip.midY - height / 2,
      width: max(4, chip.width - 20 - (modified ? 12 : 0)), height: height)
    (document.title as NSString).draw(in: rect, withAttributes: attributes)
    if modified {
      NSColor.controlAccentColor.setFill()
      NSBezierPath(ovalIn: NSRect(x: chip.maxX - 15, y: chip.midY - 2.5, width: 5, height: 5))
        .fill()
    }
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    for (title, id) in [
      ("Close Tab", "close"), ("Close Other Tabs", "closeOthers"), ("Close All Tabs", "closeAll"),
      ("-", ""), ("Reveal in Finder", "reveal"), ("Copy Path", "copyPath"),
    ] {
      if title == "-" {
        menu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(title: title, action: #selector(tabMenuAction(_:)), keyEquivalent: "")
      item.representedObject = id
      item.target = self
      menu.addItem(item)
    }
    return menu
  }
  @objc private func tabMenuAction(_ item: NSMenuItem) {
    guard let owner = (NSApp.delegate as? AppDelegate)?.current else { return }
    switch item.representedObject as? String {
    case "close": owner.closeTab(document)
    case "closeOthers": owner.closeOtherTabs(document)
    case "closeAll": owner.closeAllTabs()
    case "reveal":
      if let url = document.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    case "copyPath":
      guard let path = document.url?.path else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(path, forType: .string)
    default: break
    }
  }
}

@MainActor
final class PaletteController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  let items: [String], action: (Int) -> Void
  var filtered: [Int] = []
  let table = NSTableView(), search = NSSearchField(),
    empty = NSTextField(labelWithString: "No matches")
  init(title: String, items: [String], action: @escaping (Int) -> Void) {
    self.items = items
    self.action = action
    filtered = Array(items.indices)
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 430), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    w.title = title
    super.init(window: w)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    search.placeholderString = "Type to filter…"
    search.delegate = self
    search.action = nil
    search.controlSize = .large
    search.font = Style.body
    stack.addArrangedSubview(search)
    let sc = NSScrollView()
    sc.hasVerticalScroller = true
    sc.autohidesScrollers = true
    sc.drawsBackground = false
    let col = NSTableColumn(identifier: .init("value"))
    table.addTableColumn(col)
    table.headerView = nil
    table.rowHeight = 26
    table.backgroundColor = .clear
    table.style = .inset
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(accept)
    sc.documentView = table
    stack.addArrangedSubview(sc)
    // "No matches" floats in the list area instead of leaving the sheet blank.
    empty.font = Style.body
    empty.textColor = .tertiaryLabelColor
    empty.isHidden = true
    empty.translatesAutoresizingMaskIntoConstraints = false
    sc.addSubview(empty)
    NSLayoutConstraint.activate([
      empty.centerXAnchor.constraint(equalTo: sc.centerXAnchor),
      empty.centerYAnchor.constraint(equalTo: sc.centerYAnchor),
    ])
    search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    sc.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
    let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
    cancelButton.keyEquivalent = "\u{1b}"
    let openButton = NSButton(title: "Open", target: self, action: #selector(accept))
    openButton.keyEquivalent = "\r"
    // A footer pairs the keyboard hints with the standard trailing buttons.
    let hint = NSTextField(labelWithString: "↑↓ Navigate   ↵ Open   esc Close")
    hint.font = Style.caption
    hint.textColor = .tertiaryLabelColor
    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let buttons = NSStackView(views: [hint, spacer, cancelButton, openButton])
    buttons.spacing = 8
    stack.addArrangedSubview(buttons)
    buttons.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
    w.contentView = stack
    w.initialFirstResponder = search
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  }
  required init?(coder: NSCoder) { fatalError() }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let field = NSTextField(labelWithString: items[filtered[row]])
    field.font = Style.body
    field.lineBreakMode = .byTruncatingMiddle
    return field
  }
  func controlTextDidChange(_ notification: Notification) {
    let query = search.stringValue.lowercased()
    filtered = items.indices.compactMap { i -> (Int, Int)? in
      var rest = items[i].lowercased()[...]
      var score = 0
      for c in query {
        guard let index = rest.firstIndex(of: c) else { return nil }
        score += rest.distance(from: rest.startIndex, to: index)
        rest = rest[rest.index(after: index)...]
      }
      return (i, score)
    }.sorted { $0.1 < $1.1 }.map { $0.0 }
    table.reloadData()
    empty.isHidden = !filtered.isEmpty
    if !filtered.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)) {
      accept()
      return true
    }
    if selector == #selector(NSResponder.moveDown(_:)) {
      table.selectRowIndexes(
        IndexSet(integer: min(max(table.selectedRow + 1, 0), max(filtered.count - 1, 0))),
        byExtendingSelection: false)
      table.scrollRowToVisible(table.selectedRow)
      return true
    }
    if selector == #selector(NSResponder.moveUp(_:)) {
      table.selectRowIndexes(
        IndexSet(integer: max(table.selectedRow - 1, 0)), byExtendingSelection: false)
      return true
    }
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      cancel()
      return true
    }
    return false
  }
  @objc func cancel() {
    if let w = window {
      w.sheetParent?.endSheet(w)
      w.orderOut(nil)
    }
  }
  @objc func accept() {
    guard table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
    let index = filtered[table.selectedRow]
    cancel()
    action(index)
  }
}
