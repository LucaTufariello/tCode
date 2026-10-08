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
  var sidebarStack: NSStackView!
  var filesScroll: NSScrollView!
  var navigator: NavigatorList?
  let tabs = NSStackView(), contentStack = NSStackView(), panelStack = NSStackView()
  let status = NSTextField(labelWithString: "Ready")
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
  let packs = LanguagePack.discover()
  var selectedURL: URL? {
    (outline.item(atRow: outline.selectedRow) as? FileNode)?.url ?? active?.url
  }
  var editor: CodeTextView? { panes.first?.editor }
  init(root: URL?) {
    self.root = root
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init(window: w)
    w.delegate = self
    w.title = root?.lastPathComponent ?? "tCode"
    w.subtitle = root == nil ? "Native code editor" : ""
    w.minSize = NSSize(width: 820, height: 520)
    w.setFrameAutosaveName("tCode." + (root?.path ?? "Welcome"))
    w.center()
    w.autorecalculatesKeyViewLoop = true
    w.isRestorable = true
    let toolbar = NSToolbar(identifier: "workspace")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    w.toolbar = toolbar
    w.toolbarStyle = .unified
    setup()
    w.contentViewController = outer
    NotificationCenter.default.addObserver(
      self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(toolSettingsChanged), name: .tcodeToolSettingsChanged, object: nil)
    if let root { loadWorkspace(root) }
  }
  required init?(coder: NSCoder) { fatalError() }
  func setup() {
    outer.splitView.isVertical = true
    let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sideItem.minimumThickness = 220
    sideItem.maximumThickness = 460
    outer.addSplitViewItem(sideItem)
    outer.addSplitViewItem(NSSplitViewItem(viewController: content))
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.minimumThickness = 200
    inspectorItem.isCollapsed = true
    outer.addSplitViewItem(inspectorItem)
    let side = NSStackView()
    side.orientation = .vertical
    side.spacing = 8
    side.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 8, right: 8)
    sidebar.view = container(side)
    sidebarStack = side
    let modes = NSSegmentedControl(
      labels: ["Files", "Search", "Git", "Run"], trackingMode: .selectOne, target: self,
      action: #selector(sideMode(_:)))
    modes.selectedSegment = 0
    modes.setAccessibilityLabel("Workspace navigator")
    side.addArrangedSubview(modes)
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
    side.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -16).isActive = true
    contentStack.orientation = .vertical
    contentStack.distribution = .fill
    contentStack.spacing = 0
    content.view = container(contentStack)
    tabs.orientation = .horizontal
    tabs.alignment = .centerY
    tabs.spacing = 2
    tabs.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
    let tabScroll = NSScrollView()
    tabScroll.documentView = tabs
    tabScroll.hasHorizontalScroller = true
    tabScroll.autohidesScrollers = true
    tabScroll.drawsBackground = false
    tabScroll.heightAnchor.constraint(equalToConstant: 39).isActive = true
    contentStack.addArrangedSubview(tabScroll)
    vertical.splitView.isVertical = false
    editorSplit.splitView.isVertical = true
    vertical.addSplitViewItem(NSSplitViewItem(viewController: editorSplit))
    let bottom = NSSplitViewItem(viewController: panel)
    bottom.minimumThickness = 120
    bottom.canCollapse = true
    bottom.isCollapsed = true
    vertical.addSplitViewItem(bottom)
    contentStack.addArrangedSubview(vertical.view)
    let statusBar = NSStackView(views: [status])
    statusBar.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14)
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    contentStack.addArrangedSubview(statusBar)
    statusBar.heightAnchor.constraint(equalToConstant: 25).isActive = true
    for v in [tabScroll, vertical.view, statusBar] {
      v.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }
    panelStack.orientation = .vertical
    panelStack.distribution = .fill
    panelStack.spacing = 0
    panel.view = panelStack
    let panelHeader = NSStackView()
    panelHeader.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
    panelSelector.target = self
    panelSelector.action = #selector(changePanel(_:))
    panelSelector.selectedSegment = 2
    panelHeader.addArrangedSubview(panelSelector)
    panelSelector.controlSize = .small
    panelSelector.font = .systemFont(ofSize: 11)
    let add = NSButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New terminal")!,
      target: self, action: #selector(newTerminal))
    add.bezelStyle = .accessoryBarAction
    panelHeader.addArrangedSubview(add)
    let glass = ConcentricGlass()
    glass.contentView = panelHeader
    glass.effectIsInteractive = true
    panelStack.addArrangedSubview(glass)
    glass.heightAnchor.constraint(equalToConstant: 43).isActive = true
    for text in [output, debugOutput, problems] {
      text.isEditable = false
      text.isRichText = false
      text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      text.textContainerInset = NSSize(width: 14, height: 10)
      text.setAccessibilityLabel(
        text === output ? "Build output" : text === problems ? "Problems" : "Debug console")
    }
    linkHandler = OutputLinkHandler(self)
    output.delegate = linkHandler
    problems.delegate = linkHandler
    debugOutput.delegate = linkHandler
    showPanelContent()
    let details = NSStackView(views: [NSTextField(labelWithString: "Document"), inspectorText])
    details.orientation = .vertical
    details.alignment = .leading
    details.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
    inspector.view = details
    showWelcome()
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
    let title = NSTextField(labelWithString: "tCode")
    title.font = .systemFont(ofSize: 32, weight: .semibold)
    let subtitle = NSTextField(labelWithString: "A quiet place to build.")
    subtitle.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [title, subtitle])
    stack.orientation = .vertical
    stack.spacing = 14
    for (title, id) in [
      ("Open Folder…", "openFolder"), ("Create Project…", "newProject"), ("New File", "newFile"),
    ] {
      let b = NSButton(title: title, target: self, action: #selector(welcomeAction(_:)))
      b.identifier = .init(id)
      b.bezelStyle = .rounded
      stack.addArrangedSubview(b)
    }
    let holder = NSView()
    holder.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
    ])
    vc.view = holder
    editorSplit.addSplitViewItem(NSSplitViewItem(viewController: vc))
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
    rootNode = FileNode(url, directory: true)
    reloadTree()
    watchExpressions = UserDefaults.standard.stringArray(forKey: "watches." + url.path) ?? []
    var recent = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
    recent.removeAll { $0 == url.path }
    recent.insert(url.path, at: 0)
    UserDefaults.standard.set(Array(recent.prefix(20)), forKey: "recentProjects")
    let paths = UserDefaults.standard.stringArray(forKey: "tabs." + url.path) ?? []
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
        restoreLayout(layout)
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
    label.font = .systemFont(ofSize: 12)
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
  @objc func sideMode(_ sender: NSSegmentedControl) {
    switch sender.selectedSegment {
    case 1: searchSidebar()
    case 2: gitSidebar()
    case 3:
      showNavigator(
        title: "Run & Debug",
        rows: [
          "Run Configuration…", "Run", "Build", "Test", "Discover Tests", "Start Debugging",
          "Continue", "Pause", "Step Over", "Step Into", "Step Out", "Call Stack",
          "Inspect Variables", "Evaluate Watch…", "Stop Debugging",
        ],
        commands: [
          "configuration", "run", "build", "test", "discoverTests", "debug", "continue", "pause",
          "next", "stepIn", "stepOut", "callStack", "variables", "watch", "stopDebug",
        ])
    default:
      replaceNavigator(with: filesScroll)
      navigator = nil
    }
  }
  func replaceNavigator(with view: NSView) {
    while sidebarStack.arrangedSubviews.count > 1 {
      let child = sidebarStack.arrangedSubviews.last!
      sidebarStack.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    sidebarStack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -16).isActive = true
  }
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
  }
  func searchSidebar() {
    guard let root, let query = input("Search workspace (regex)"), !query.isEmpty else { return }
    searchHandle?.cancel()
    searchHandle = Task {
      do {
        let exclusions = EditorConfiguration.load(root: root, file: nil).exclusions
        let hits = try await Background.run {
          try WorkspaceSearch.find(root: root, pattern: query, regex: true, excluding: exclusions)
        }
        guard !Task.isCancelled else { return }
        showNavigator(
          title: "\(hits.count) matches",
          rows: hits.map { "\($0.url.lastPathComponent):\($0.line+1)  \($0.preview)" }
        ) { [weak self] index in
          self?.open(hits[index].url, position: Position(line: hits[index].line, character: 0))
        }
      } catch { report(error) }
    }
  }
  func gitSidebar() {
    guard let root else { return }
    Task {
      do {
        let entries = try await Git.status(root)
        let branch = try await Git.run(root, ["branch", "--show-current"])
        let actions = [
          "Refresh Status", "Stage Selected File", "Unstage Selected File", "Show Diff", "Commit…",
          "History", "Switch Branch…",
        ]
        showNavigator(
          title: branch.trimmingCharacters(in: .whitespacesAndNewlines),
          rows: actions + ["── Changes ──"] + entries.map { "\($0.status)  \($0.path)" }
        ) { [weak self] index in
          guard let self else { return }
          if index < actions.count {
            self.perform(
              ["gitRefresh", "stage", "unstage", "diff", "commit", "history", "branch"][index])
          } else if index > actions.count {
            self.open(root.appendingPathComponent(entries[index - actions.count - 1].path))
          }
        }
      } catch { report(error) }
    }
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
        if self.active === document {
          self.window?.representedURL = document.url
          for pane in self.panes {
            pane.editor.setAccessibilityLabel("Code editor, " + document.title)
            pane.editor.comment = document.url?.pathExtension == "py" ? "#" : "//"
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
    let config = EditorConfiguration.load(root: root, file: document.url)
    pane.editor.indent = config.useTabs ? "\t" : String(repeating: " ", count: config.indentSize)
    pane.editor.isHorizontallyResizable = !config.wrap
    pane.scroll.hasHorizontalScroller = !config.wrap
    pane.editor.textContainer?.widthTracksTextView = config.wrap
    if !config.wrap { pane.editor.textContainer?.containerSize.width = 100000 }
    if let url = document.url { pane.ruler.breakpoints = breakpoints[url] ?? [] }
    pane.selectionChanged = { [weak self] position in self?.updateStatus(position) }
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
      let button = NSButton(
        title: (doc.modified ? "● " : "") + doc.title, target: self,
        action: #selector(tabSelected(_:)))
      button.bezelStyle = .accessoryBarAction
      button.state = active === doc ? .on : .off
      button.representedDocument = doc
      button.toolTip = doc.url?.path ?? "Untitled document"
      let close = NSButton(
        image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close " + doc.title)!,
        target: self, action: #selector(tabClose(_:)))
      close.bezelStyle = .accessoryBarAction
      close.controlSize = .mini
      close.representedDocument = doc
      let tab = NSStackView(views: [button, close])
      tab.spacing = 0
      tabs.addArrangedSubview(tab)
    }
    tabs.frame = NSRect(
      x: 0, y: 0, width: max(100, tabs.fittingSize.width), height: 39)
  }
  @objc func tabSelected(_ button: NSButton) {
    if let doc = button.representedDocument { select(doc) }
  }
  @objc func tabClose(_ button: NSButton) {
    if let doc = button.representedDocument {
      select(doc)
      closeTab()
    }
  }
  func updateStatus(_ position: Position? = nil) {
    guard let doc = active else {
      status.stringValue = root?.path ?? "Open a folder or create a file to begin"
      return
    }
    let p =
      position
      ?? PositionMap.position(in: doc.text, utf16Offset: editor?.selectedRange().location ?? 0)
    let lineEnding = doc.text.contains("\r\n") ? "CRLF" : doc.text.contains("\r") ? "CR" : "LF"
    status.stringValue =
      "\(doc.url?.pathExtension.uppercased() ?? "TEXT")    Ln \(p.line+1), Col \(p.character+1)    Spaces: \(editor?.indent.count ?? 4)    \(doc.encoding == .utf8 ? "UTF-8" : "UTF-16")    \(lineEnding)"
      + (doc.large
        ? "    Large file mode" : doc.languageSession?.ready == true ? "    LSP connected" : "")
    if debugSession?.stopped == true { status.stringValue += "    Debugger paused" }
    inspectorText.stringValue =
      "\(doc.title)\n\n\(doc.url?.path ?? "Unsaved document")\n\n\(doc.storage.length.formatted()) UTF-16 units\n\(doc.modified ? "Modified" : "Saved")\n\n\(doc.languageSession?.pack.name ?? "Text")"
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
    }
    persist()
  }
  @objc func activated() {
    reloadTree()
    if let doc = active { checkExternal(doc) }
  }
  @objc func toolSettingsChanged() {
    for service in services.values { service.stop() }
    services.removeAll()
    for doc in documents { doc.languageSession = nil }
    diagnosticList.removeAll()
    refreshProblems()
    if languageEnabled, let doc = active { activateLanguage(doc) }
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
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = title
    let sc = NSScrollView()
    let tv = NSTextView()
    tv.string = text
    tv.isEditable = false
    tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    tv.autoresizingMask = [.width]
    sc.documentView = tv
    sc.hasVerticalScroller = true
    w.contentView = sc
    w.center()
    w.isReleasedWhenClosed = false
    w.makeKeyAndOrderFront(nil)
  }
  func choose(_ title: String, items: [String], action: @escaping (Int) -> Void) {
    palette = PaletteController(title: title, items: items, action: action)
    if let window, let p = palette?.window { window.beginSheet(p) }
  }
  func persist() {
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
    if selectedPanel == 0 {
      if let terminal = terminalViews.last {
        panelStack.addArrangedSubview(terminal)
        terminal.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
      } else {
        let b = NSButton(title: "Start zsh Terminal", target: self, action: #selector(newTerminal))
        panelStack.addArrangedSubview(b)
      }
    } else {
      let tv = selectedPanel == 1 ? problems : selectedPanel == 2 ? output : debugOutput
      let sc = NSScrollView()
      sc.hasVerticalScroller = true
      sc.documentView = tv
      tv.autoresizingMask = [.width]
      panelStack.addArrangedSubview(sc)
      sc.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
    }
  }
  func showBottom(_ index: Int) {
    let wasHidden = vertical.splitViewItems.last?.isCollapsed ?? false
    vertical.splitViewItems.last?.isCollapsed = false
    selectedPanel = index
    panelSelector.selectedSegment = index
    showPanelContent()
    if wasHidden {
      vertical.splitView.setPosition(max(200, vertical.view.bounds.height - 240), ofDividerAt: 0)
    }
  }
  @objc func newTerminal() {
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
    terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
          .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
          .foregroundColor: NSColor.textColor,
        ]))
    if let storage = tv.textStorage, storage.length > 2_000_000 {
      storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 1_500_000))
    }
    linkHandler.decorate(tv)
    tv.scrollToEndOfDocument(nil)
  }
}

private var documentAssociation: UInt8 = 0
extension NSButton {
  var representedDocument: CodeDocument? {
    get { objc_getAssociatedObject(self, &documentAssociation) as? CodeDocument }
    set {
      objc_setAssociatedObject(
        self, &documentAssociation, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}

@MainActor
final class PaletteController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  let items: [String], action: (Int) -> Void
  var filtered: [Int] = []
  let table = NSTableView(), search = NSSearchField()
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
    stack.addArrangedSubview(search)
    let sc = NSScrollView()
    sc.hasVerticalScroller = true
    let col = NSTableColumn(identifier: .init("value"))
    table.addTableColumn(col)
    table.headerView = nil
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(accept)
    sc.documentView = table
    stack.addArrangedSubview(sc)
    search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    sc.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
    let buttons = NSStackView(views: [
      NSButton(title: "Cancel", target: self, action: #selector(cancel)),
      NSButton(title: "Open", target: self, action: #selector(accept)),
    ])
    stack.addArrangedSubview(buttons)
    w.contentView = stack
    w.initialFirstResponder = search
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  }
  required init?(coder: NSCoder) { fatalError() }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let field = NSTextField(labelWithString: items[filtered[row]])
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
