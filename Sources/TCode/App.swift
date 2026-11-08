import AppKit
import SwiftUI
import TCodeCore

extension Notification.Name {
  static let tcodeToolSettingsChanged = Notification.Name("tCodeToolSettingsChanged")
}

@main struct TCodeMain {
  @MainActor static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  var windows: [WorkspaceWindow] = []
  var settings: NSWindowController?
  /// The workspace a menu command should act on: the key window first, then the main window
  /// (which is what stays main while an open panel or sheet is up), then the most recent one.
  var current: WorkspaceWindow? {
    windows.first { $0.window?.isKeyWindow == true }
      ?? windows.first { $0.window?.isMainWindow == true }
      ?? windows.last { $0.window?.isVisible == true }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    makeMenu()
    let roots = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    Task {
      var recovered: [CodeDocument] = []
      let result = await CodeDocument.recovery.readTolerant()
      for failure in result.failures { NSLog("Recovery: %@", failure) }
      for record in result.records {
        // A record is only worth restoring when its file is still on disk and its buffer
        // still holds unsaved work. Anything else is stale and is dropped for good.
        if record.path.map({ !FileManager.default.fileExists(atPath: $0) }) ?? false
          || (record.path == nil && record.text.isEmpty)
        {
          try? await CodeDocument.recovery.remove(record.id)
          continue
        }
        let doc = CodeDocument(
          url: record.path.map { URL(fileURLWithPath: $0) }, recovery: record)
        DocumentPool.shared.documents.append(doc)
        recovered.append(doc)
      }
      // Without an explicit path on the command line tCode always starts on its welcome page.
      for path in roots.prefix(8) where FileManager.default.fileExists(atPath: path) {
        newWindow(URL(fileURLWithPath: path))
      }
      if windows.isEmpty { newWindow(nil) }
      for doc in recovered { current?.add(doc) }
      let appearance =
        ProcessInfo.processInfo.environment["TCODE_APPEARANCE"]
        ?? UserDefaults.standard.string(forKey: "appearance")
      NSApp.appearance = appearance.flatMap {
        $0 == "light"
          ? NSAppearance(named: .aqua) : $0 == "dark" ? NSAppearance(named: .darkAqua) : nil
      }
      NSApp.activate(ignoringOtherApps: true)
      // Temporary visual-check hook: open a settings section without a menu command.
      if ProcessInfo.processInfo.environment["TCODE_SHOW_SETTINGS"] != nil { showSettings() }
      // Temporary visual-check hook: open a file in the front workspace.
      if let file = ProcessInfo.processInfo.environment["TCODE_OPEN_FILE"] {
        current?.open(URL(fileURLWithPath: file))
      }
      // Temporary visual-check hooks: reveal a chrome surface without a menu command.
      for (variable, action) in [
        ("TCODE_SHOW_AGENT", "agent"), ("TCODE_SHOW_PANEL", "panel"),
        ("TCODE_SHOW_INSPECTOR", "inspector"),
      ] where ProcessInfo.processInfo.environment[variable] != nil {
        current?.perform(action)
      }
      // Temporary visual-check hook: open a language sheet without a menu command.
      if let sheet = ProcessInfo.processInfo.environment["TCODE_LANGUAGE_SHEET"] {
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1))
          let environment = LanguageEnvironment.shared
          environment.reload()
          switch sheet {
          case "install":
            environment.prepareInstallation(id: "python")
          case "remove":
            if let pack = environment.packs.first { environment.prepareRemoval(pack) }
          case "remove-fake":
            if let pack = environment.packs.first,
              let data = """
                {"recipeID":"python-tools","version":"2026.10.21","installedAt":0,\
                "managedDirectory":"/Users/lucatufariello/Library/Application Support/tCode/tools/python-tools/2026.10.21",\
                "executables":{},"owned":true}
                """.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(ToolInstallReceipt.self, from: data)
            {
              environment.removal = LanguageRemovalRequest(
                pack: pack, receipts: [receipt], grammarIDs: ["python"],
                externalRecipeIDs: ["python3"],
                sharedImpact: [
                  "Other workspaces that use these shared downloads will need them reinstalled."
                ])
            }
          default:
            break
          }
        }
      }
      // Temporary visual-check hook: render the front window to a PNG and exit.
      if let path = ProcessInfo.processInfo.environment["TCODE_SNAPSHOT"] {
        let seconds =
          Double(ProcessInfo.processInfo.environment["TCODE_SNAPSHOT_DELAY"] ?? "") ?? 2
        try? await Task.sleep(for: .seconds(seconds))
        let target =
          ProcessInfo.processInfo.environment["TCODE_LANGUAGE_SHEET"] != nil
          ? (NSApp.windows.first { $0.sheetParent != nil }
            ?? settings?.window ?? NSApp.keyWindow ?? current?.window)
          : ProcessInfo.processInfo.environment["TCODE_SHOW_SETTINGS"] != nil
            ? (settings?.window ?? NSApp.keyWindow ?? current?.window)
            : (NSApp.keyWindow ?? current?.window)
        if let win = target {
          var lines: [String] = ["window bg=\(win.backgroundColor) frame=\(win.frame)"]
          func dump(_ v: NSView, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            var extra = ""
            if let layer = v.layer, let bg = layer.backgroundColor {
              extra = " layer=\(NSColor(cgColor: bg) ?? .clear)"
            }
            if let tv = v as? NSTextView { extra += " textbg=\(tv.backgroundColor)" }
            lines.append("\(pad)\(type(of: v)) frame=\(v.frame) hidden=\(v.isHidden)\(extra)")
            for sub in v.subviews { dump(sub, depth + 1) }
          }
          if let view = win.contentView { dump(view, 0) }
          try? lines.joined(separator: "\n").write(
            toFile: "/tmp/hierarchy.log", atomically: true, encoding: .utf8)
        }
        if let win = target,
          let view = ProcessInfo.processInfo.environment["TCODE_SNAPSHOT_FULL"] != nil
            ? win.contentView?.superview : win.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
          NSGraphicsContext.saveGraphicsState()
          if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            win.effectiveAppearance.performAsCurrentDrawingAppearance {
              (win.backgroundColor ?? .windowBackgroundColor).setFill()
              view.bounds.fill()
            }
          }
          NSGraphicsContext.restoreGraphicsState()
          view.cacheDisplay(in: view.bounds, to: rep)
          try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        }
        // A snapshot run must not wait on the unsaved-document quit prompt.
        exit(0)
      }
    }
  }
  func newWindow(_ root: URL?) {
    let controller = WorkspaceWindow(root: root)
    windows.append(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    if let window = controller.window { LaunchMetric.windowReady(window) }
  }
  /// Opens a folder in the front window, switching that window's workspace. A second window is
  /// only created when there is no workspace window to reuse.
  func presentWorkspace(_ url: URL) {
    if let window = current {
      window.openWorkspace(url)
    } else {
      newWindow(url)
    }
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        presentWorkspace(url)
      } else {
        if current == nil { newWindow(nil) }
        current?.open(url)
      }
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { newWindow(nil) }
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      var seen = Set<UUID>()
      for workspace in windows {
        let modified = workspace.documents.filter { $0.modified && !seen.contains($0.id) }
        guard !modified.isEmpty else { continue }
        switch workspace.confirmClose(modified) {
        case .cancel:
          NSApp.reply(toApplicationShouldTerminate: false)
          return
        case .discard:
          for doc in modified {
            doc.autosaveTask?.cancel()
            doc.recoveryTask?.cancel()
            try? await CodeDocument.recovery.remove(doc.id)
          }
        case .keepRecovery:
          do {
            for doc in modified {
              doc.recoveryTask?.cancel()
              try await CodeDocument.recovery.write(doc.recoveryRecord())
            }
          } catch {
            workspace.report(error)
            NSApp.reply(toApplicationShouldTerminate: false)
            return
          }
        case .save:
          do {
            for doc in modified { try await workspace.saveDocument(doc) }
          } catch is SaveCancelled {
            NSApp.reply(toApplicationShouldTerminate: false)
            return
          } catch {
            workspace.report(error)
            NSApp.reply(toApplicationShouldTerminate: false)
            return
          }
        }
        seen.formUnion(modified.map(\.id))
      }
      // Safety net for a modified buffer that is no longer attached to a window.
      for doc in DocumentPool.shared.documents where doc.modified && !seen.contains(doc.id) {
        try? await CodeDocument.recovery.write(doc.recoveryRecord())
      }
      persist()
      for workspace in windows { await workspace.shutdown() }
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
  func persist() {
    for w in windows { w.persist() }
  }
  @objc func menuAction(_ item: NSMenuItem) {
    switch item.identifier?.rawValue {
    case "openFolder":
      let p = NSOpenPanel()
      p.canChooseDirectories = true
      p.canChooseFiles = false
      if let root = current?.root { p.directoryURL = root }
      if p.runModal() == .OK, let url = p.url { presentWorkspace(url) }
    case "newProject":
      let p = NSSavePanel()
      p.title = "Create Project Folder"
      p.nameFieldStringValue = "MyProject"
      if let root = current?.root { p.directoryURL = root }
      if p.runModal() == .OK, let url = p.url {
        do {
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
          presentWorkspace(url)
        } catch { current?.report(error) }
      }
    case "newWindow": newWindow(nil)
    case "newFile":
      // New File always lands in the front window; a window is created only when none is open.
      if current == nil { newWindow(nil) }
      current?.perform("newFile")
    case "undo", "redo":
      if let text = NSApp.keyWindow?.firstResponder as? NSTextView, !(text is CodeTextView) {
        if item.identifier?.rawValue == "undo" {
          text.undoManager?.undo()
        } else {
          text.undoManager?.redo()
        }
      } else {
        current?.perform(item.identifier?.rawValue ?? "")
      }
    case "closeTab":
      if let key = NSApp.keyWindow, !windows.contains(where: { $0.window === key }) {
        key.performClose(nil)
      } else {
        current?.perform("closeTab")
      }
    case "settings": showSettings()
    case "hide": NSApp.hide(nil)
    case "hideOthers": NSApp.hideOtherApplications(nil)
    case "showAll": NSApp.unhideAllApplications(nil)
    case "zoom": current?.window?.performZoom(nil)
    case "front": NSApp.arrangeInFront(nil)
    case "help":
      if let url = URL(string: "https://github.com/LucaTufariello/tCode") {
        NSWorkspace.shared.open(url)
      }
    case "shortcuts": showSettings()
    case "issue":
      if let url = URL(string: "https://github.com/LucaTufariello/tCode/issues") {
        NSWorkspace.shared.open(url)
      }
    default: current?.perform(item.identifier?.rawValue ?? "")
    }
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let id = item.identifier?.rawValue ?? ""
    let hasWindow = current != nil
    let hasDocument = current?.active != nil
    switch id {
    case "save", "saveAs", "closeTab", "format", "comment", "duplicateLine", "multiSelect",
      "fold", "snippet", "wrap", "splitVertical", "splitHorizontal", "closeSplit",
      "completion", "hover", "signatureHelp", "definition", "references", "symbols",
      "renameSymbol", "codeAction", "breakpoint", "continue", "pause", "next", "stepIn",
      "stepOut", "variables", "watch", "watches", "removeWatch", "stopDebug", "selectLanguage",
      "enableLanguages", "find", "goLine", "debug":
      return hasDocument
    case "saveAll":
      return current?.documents.contains(where: \.modified) ?? false
    case "undo":
      return current?.active?.undo.canUndo ?? false
    case "redo":
      return current?.active?.undo.canRedo ?? false
    case "openFolder", "newWindow", "newProject", "recent", "newFile":
      return true
    case "sidebar", "panel", "inspector", "agent", "agentNewChat", "quickOpen", "palette", "search",
      "replaceProject", "openFile", "terminal", "terminalSessions", "closeTerminal",
      "gitRefresh", "stage", "unstage", "diff", "commit", "history", "branch", "discoverTests",
      "run", "build", "test", "fullscreen", "minimize", "zoom", "front", "reload",
      "configuration", "reloadLanguagePacks", "workspaceLanguagePacks", "toolVersions", "cancel":
      return hasWindow
    default:
      return true
    }
  }
  func makeMenu() {
    let main = NSMenu()
    NSApp.mainMenu = main
    func menu(_ name: String, _ entries: [(String, String, String, NSEvent.ModifierFlags)]) {
      let parent = NSMenuItem()
      parent.title = name
      let submenu = NSMenu(title: name)
      parent.submenu = submenu
      main.addItem(parent)
      for (title, action, key, flags) in entries {
        if title == "-" {
          submenu.addItem(.separator())
          continue
        }
        let custom =
          (UserDefaults.standard.dictionary(forKey: "keybindings") as? [String: [String: String]])?[
            action]
        let item = NSMenuItem(
          title: title, action: #selector(menuAction(_:)), keyEquivalent: custom?["key"] ?? key)
        item.keyEquivalentModifierMask =
          custom?["modifiers"].map { value in
            var mask: NSEvent.ModifierFlags = []
            if value.contains("command") { mask.insert(.command) }
            if value.contains("shift") { mask.insert(.shift) }
            if value.contains("option") { mask.insert(.option) }
            if value.contains("control") { mask.insert(.control) }
            return mask
          } ?? flags
        item.identifier = NSUserInterfaceItemIdentifier(action)
        item.target = self
        submenu.addItem(item)
      }
    }
    menu(
      "tCode",
      [
        ("About tCode", "about", "", []), ("Settings…", "settings", ",", .command),
        ("-", "", "", []), ("Hide tCode", "hide", "h", .command),
        ("Hide Others", "hideOthers", "h", [.command, .option]),
        ("Show All", "showAll", "", []), ("-", "", "", []),
        ("Quit tCode", "quit", "q", .command),
      ])
    if let appMenu = main.items.first?.submenu {
      let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
      services.submenu = NSMenu(title: "Services")
      NSApp.servicesMenu = services.submenu
      appMenu.insertItem(services, at: 2)
    }
    menu(
      "File",
      [
        ("New File", "newFile", "n", .command),
        ("New Window", "newWindow", "n", [.command, .shift]),
        ("New Project Folder…", "newProject", "n", [.command, .option]),
        ("Open Folder…", "openFolder", "o", [.command, .shift]),
        ("Open File…", "openFile", "o", .command), ("Recent Projects…", "recent", "", []),
        ("-", "", "", []), ("Save", "save", "s", .command),
        ("Save As…", "saveAs", "s", [.command, .shift]),
        ("Save All", "saveAll", "s", [.command, .option]), ("Close Tab", "closeTab", "w", .command),
        ("New Folder…", "newFolder", "n", [.command, .control]),
        ("Rename Selected Item…", "rename", "", []), ("Move to Trash…", "trash", "", []),
      ])
    let edit = NSMenuItem()
    edit.title = "Edit"
    edit.submenu = NSMenu(title: "Edit")
    main.addItem(edit)
    for (title, selector, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] {
      let item = edit.submenu?.addItem(withTitle: title, action: selector, keyEquivalent: key)
      if title == "Undo" || title == "Redo" {
        item?.action = #selector(menuAction(_:))
        item?.target = self
        item?.identifier = .init(title.lowercased())
      }
    }
    menu(
      "Find",
      [
        ("Find in File…", "find", "f", .command),
        ("Find in Workspace…", "search", "f", [.command, .shift]),
        ("Quick Open…", "quickOpen", "p", .command),
        ("Command Palette…", "palette", "p", [.command, .shift]),
        ("Go to Line…", "goLine", "l", .command),
        ("Document Symbols…", "symbols", "o", [.command, .shift, .option]),
        ("Navigate Back", "back", "[", [.command, .control]),
      ])
    menu(
      "Editor",
      [
        ("Enable Language Tools", "enableLanguages", "", []),
        ("Document Language…", "selectLanguage", "", []),
        ("Reload Language Packs", "reloadLanguagePacks", "", []),
        ("Enable Workspace Language Configurations…", "workspaceLanguagePacks", "", []),
        ("Add Cursor Below", "cursorBelow", "\u{F701}", [.control, .option]),
        ("Add Cursor Above", "cursorAbove", "\u{F700}", [.control, .option]),
        ("Fold Selection / Unfold All", "fold", "[", [.command, .option]),
        ("Toggle Comment", "comment", "/", .command),
        ("Duplicate Line", "duplicateLine", "d", [.command, .shift]),
        ("Add Next Occurrence", "multiSelect", "d", .command),
        ("Insert Snippet…", "snippet", "", []), ("Toggle Wrapping", "wrap", "z", .option),
        ("Split Vertically", "splitVertical", "\\", .command),
        ("Split Horizontally", "splitHorizontal", "\\", [.command, .option]),
        ("Close Split", "closeSplit", "", []), ("Complete", "completion", " ", .control),
        ("Hover Information", "hover", "", []), ("Signature Help", "signatureHelp", "", []),
        ("Go to Definition", "definition", "", []), ("Find References", "references", "", []),
        ("Rename Symbol…", "renameSymbol", "", []), ("Code Actions…", "codeAction", ".", .command),
        ("Format Document", "format", "i", [.command, .shift]),
      ])
    menu(
      "View",
      [
        ("Toggle Sidebar", "sidebar", "0", .command),
        ("Toggle Bottom Panel", "panel", "j", .command),
        ("Toggle Inspector", "inspector", "0", [.command, .option]),
        ("Toggle Agent", "agent", "a", [.command, .option]),
        ("Enter Full Screen", "fullscreen", "f", [.control, .command]),
      ])
    menu(
      "Agent",
      [
        ("Toggle Agent", "agent", "a", [.command, .option]),
        ("New Chat", "agentNewChat", "", []),
        ("Agent Settings…", "agentSettings", "", []),
      ])
    menu(
      "Run",
      [
        ("Toggle Breakpoint", "breakpoint", "y", [.command, .shift]),
        ("Run", "run", "r", .command), ("Build", "build", "b", .command),
        ("Test", "test", "u", .command), ("Discover Tests", "discoverTests", "", []),
        ("Edit Run Configuration…", "configuration", "", []),
        ("Cancel Task", "cancel", ".", [.command, .control]),
        ("New Terminal", "terminal", "`", [.command, .shift]), ("-", "", "", []),
        ("Start Debugging…", "debug", "", []), ("Continue", "continue", "", []),
        ("Pause", "pause", "", []), ("Step Over", "next", "", []), ("Step Into", "stepIn", "", []),
        ("Step Out", "stepOut", "", []), ("Inspect Variables", "variables", "", []),
        ("Add Watch…", "watch", "", []), ("Inspect Watches", "watches", "", []),
        ("Remove Watch…", "removeWatch", "", []), ("Stop Debugging", "stopDebug", "", []),
      ])
    menu(
      "Source Control",
      [
        ("Refresh Status", "gitRefresh", "", []), ("Stage Selected File", "stage", "", []),
        ("Unstage Selected File", "unstage", "", []), ("Show Diff", "diff", "", []),
        ("Commit Staged Changes…", "commit", "", []), ("History", "history", "", []),
        ("Switch Branch…", "branch", "", []),
      ])
    menu(
      "Window",
      [
        ("Minimize", "minimize", "m", .command), ("Zoom", "zoom", "", []),
        ("Bring All to Front", "front", "", []),
      ])
    menu(
      "Help",
      [
        ("tCode Help", "help", "", []), ("Keyboard Shortcuts", "shortcuts", "", []),
        ("Report an Issue", "issue", "", []),
      ])
    if let windowMenu = main.items.first(where: { $0.title == "Window" })?.submenu {
      NSApp.windowsMenu = windowMenu
    }
    NSApp.helpMenu = main.items.last?.submenu
  }
  func showSettings() {
    if settings == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered, defer: false)
      w.title = "Settings"
      w.backgroundColor = Style.chrome
      w.titlebarAppearsTransparent = true
      w.titlebarSeparatorStyle = .none
      w.contentViewController = NSHostingController(rootView: SettingsView())
      w.center()
      settings = NSWindowController(window: w)
    }
    settings?.showWindow(nil)
  }
}

struct ShortcutsView: View {
  struct Entry: Identifiable {
    let id: String
    let label: String
    let key: String
    let modifiers: String
    var glyph: String { Self.glyph(key, modifiers) }
    static func glyph(_ key: String, _ modifiers: String) -> String {
      var text = ""
      if modifiers.contains("control") { text += "\u{2303}" }
      if modifiers.contains("option") { text += "\u{2325}" }
      if modifiers.contains("shift") { text += "\u{21E7}" }
      if modifiers.contains("command") { text += "\u{2318}" }
      return text + key.uppercased()
    }
  }
  static let catalog: [Entry] = [
    .init(id: "find", label: "Find in File", key: "f", modifiers: "command"),
    .init(id: "search", label: "Find in Workspace", key: "f", modifiers: "command shift"),
    .init(id: "quickOpen", label: "Quick Open", key: "p", modifiers: "command"),
    .init(id: "palette", label: "Command Palette", key: "p", modifiers: "command shift"),
    .init(id: "goLine", label: "Go to Line", key: "l", modifiers: "command"),
    .init(id: "newFile", label: "New File", key: "n", modifiers: "command"),
    .init(id: "save", label: "Save", key: "s", modifiers: "command"),
    .init(id: "saveAll", label: "Save All", key: "s", modifiers: "command option"),
    .init(id: "closeTab", label: "Close Tab", key: "w", modifiers: "command"),
    .init(id: "comment", label: "Toggle Comment", key: "/", modifiers: "command"),
    .init(id: "format", label: "Format Document", key: "i", modifiers: "command shift"),
    .init(id: "splitVertical", label: "Split Vertically", key: "\\", modifiers: "command"),
    .init(id: "panel", label: "Toggle Bottom Panel", key: "j", modifiers: "command"),
    .init(id: "sidebar", label: "Toggle Sidebar", key: "0", modifiers: "command"),
    .init(id: "terminal", label: "New Terminal", key: "`", modifiers: "command shift"),
    .init(id: "run", label: "Run", key: "r", modifiers: "command"),
    .init(id: "build", label: "Build", key: "b", modifiers: "command"),
    .init(id: "test", label: "Test", key: "u", modifiers: "command"),
    .init(id: "completion", label: "Complete", key: " ", modifiers: "control"),
  ]
  @State private var command = "find"
  @State private var key = "f"
  @State private var modifiers = "command"
  @State private var result = ""
  private var entry: Entry { Self.catalog.first { $0.id == command } ?? Self.catalog[0] }
  private func custom(_ id: String) -> [String: String]? {
    (UserDefaults.standard.dictionary(forKey: "keybindings") as? [String: [String: String]])?[id]
  }
  private func current() -> String {
    let override = custom(entry.id)
    return Entry.glyph(override?["key"] ?? entry.key, override?["modifiers"] ?? entry.modifiers)
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        SettingsHeading("Command")
        VStack(spacing: 0) {
          SettingsRow("Command") {
            IndustrialMenuButton(title: entry.label) {
              ForEach(Self.catalog) { item in
                Button(item.label) {
                  command = item.id
                  key = item.key
                  modifiers = item.modifiers
                  result = ""
                }
              }
            }
          }
          SettingsRule()
          SettingsRow("Current shortcut") {
            Text(current())
              .font(.system(size: 11.5, design: .monospaced))
              .foregroundStyle(.secondary)
          }
          SettingsRule()
          SettingsRow("Key (one character)") {
            IndustrialTextField(text: $key, width: 60)
          }
          SettingsRule()
          SettingsRow("Modifiers") {
            IndustrialTextField(text: $modifiers, width: 220)
          }
        }
        .overlay(alignment: .top) { SettingsRule() }
        .overlay(alignment: .bottom) { SettingsRule() }
        Text("Modifiers: command, shift, option, control. Separate with spaces. Changes apply immediately.")
          .font(.system(size: 10.5))
          .foregroundStyle(.tertiary)
          .padding(.top, 10)

        HStack(spacing: 8) {
          IndustrialSwiftButton(title: "Apply Shortcut", kind: .primary, action: apply)
          IndustrialSwiftButton(title: "Reset This Command", action: reset)
          IndustrialSwiftButton(title: "Restore All Default Shortcuts", action: restoreAll)
        }
        .padding(.top, 18)
        Text(result)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.tertiary)
          .padding(.top, 12)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func apply() {
    guard key.count == 1 else {
      result = "Enter one character."
      return
    }
    var bindings = customBindings()
    bindings[command] = ["key": key, "modifiers": modifiers]
    UserDefaults.standard.set(bindings, forKey: "keybindings")
    (NSApp.delegate as? AppDelegate)?.makeMenu()
    result = "\(entry.label) is now \(current())."
  }

  private func reset() {
    var bindings = customBindings()
    bindings.removeValue(forKey: command)
    UserDefaults.standard.set(bindings, forKey: "keybindings")
    (NSApp.delegate as? AppDelegate)?.makeMenu()
    key = entry.key
    modifiers = entry.modifiers
    result = "\(entry.label) restored to \(entry.glyph)."
  }

  private func restoreAll() {
    UserDefaults.standard.removeObject(forKey: "keybindings")
    (NSApp.delegate as? AppDelegate)?.makeMenu()
    result = "Defaults restored."
  }

  private func customBindings() -> [String: [String: String]] {
    UserDefaults.standard.dictionary(forKey: "keybindings") as? [String: [String: String]] ?? [:]
  }
}
