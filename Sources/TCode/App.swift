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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var windows: [WorkspaceWindow] = []
  var settings: NSWindowController?
  var current: WorkspaceWindow? { windows.first { $0.window?.isKeyWindow == true } ?? windows.last }
  func applicationDidFinishLaunching(_ notification: Notification) {
    makeMenu()
    let roots = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    Task {
      var recovered: [CodeDocument] = []
      do {
        for record in try await CodeDocument.recovery.read() {
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
      } catch { NSLog("Recovery: %@", error.localizedDescription) }
      // Without an explicit path on the command line tCode always starts on its welcome page.
      for path in roots.prefix(8) where FileManager.default.fileExists(atPath: path) {
        newWindow(URL(fileURLWithPath: path))
      }
      if windows.isEmpty { newWindow(nil) }
      for doc in recovered { current?.add(doc) }
      NSApp.appearance = UserDefaults.standard.string(forKey: "appearance").flatMap {
        $0 == "light"
          ? NSAppearance(named: .aqua) : $0 == "dark" ? NSAppearance(named: .darkAqua) : nil
      }
      NSApp.activate(ignoringOtherApps: true)
    }
  }
  func newWindow(_ root: URL?) {
    let controller = WorkspaceWindow(root: root)
    windows.append(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    if let window = controller.window { LaunchMetric.windowReady(window) }
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        newWindow(url)
      } else {
        if current == nil { newWindow(nil) }
        current?.open(url)
      }
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      do {
        for doc in DocumentPool.shared.documents where doc.modified {
          try await CodeDocument.recovery.write(doc.recoveryRecord())
        }
      } catch {
        current?.report(error)
        NSApp.reply(toApplicationShouldTerminate: false)
        return
      }
      persist()
      for w in windows { await w.shutdown() }
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
      if p.runModal() == .OK { newWindow(p.url) }
    case "newProject":
      let p = NSSavePanel()
      p.title = "Create Project Folder"
      p.nameFieldStringValue = "MyProject"
      if p.runModal() == .OK, let url = p.url {
        do {
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
          newWindow(url)
        } catch { current?.report(error) }
      }
    case "newWindow": newWindow(nil)
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
    default: current?.perform(item.identifier?.rawValue ?? "")
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
        ("-", "", "", []), ("Quit tCode", "quit", "q", .command),
      ])
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
        ("Enter Full Screen", "fullscreen", "f", [.control, .command]),
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
    menu("Window", [("Minimize", "minimize", "m", .command)])
    NSApp.windowsMenu = main.items.last?.submenu
  }
  func showSettings() {
    if settings == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 530), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      w.title = "Settings"
      w.contentViewController = NSHostingController(rootView: SettingsView())
      w.center()
      settings = NSWindowController(window: w)
    }
    settings?.showWindow(nil)
  }
}

struct SettingsView: View {
  @AppStorage("fontSize") var fontSize = 13.0
  @AppStorage("indentWidth") var indentWidth = 4
  @AppStorage("autosave") var autosave = false
  @AppStorage("appearance") var appearance = "system"
  @AppStorage("fontName") var fontName = "SF Mono"
  @State var paths: [String: String] = [:]
  @State var disabled: Set<String> = []
  let packs = LanguagePack.discover()
  var body: some View {
    TabView {
      Form {
        Section("Editor") {
          Slider(value: $fontSize, in: 10...24, step: 1) { Text("Font size: \(Int(fontSize))") }
          TextField("Monospaced font name", text: $fontName)
          Stepper("Indentation: \(indentWidth) spaces", value: $indentWidth, in: 1...8)
          Toggle("Autosave after edits (checks for disk conflicts)", isOn: $autosave)
          Picker("Appearance", selection: $appearance) {
            Text("System").tag("system")
            Text("Light").tag("light")
            Text("Dark").tag("dark")
          }.onChange(of: appearance) { _, value in
            NSApp.appearance =
              value == "light"
              ? NSAppearance(named: .aqua) : value == "dark" ? NSAppearance(named: .darkAqua) : nil
          }
          Text(
            "New editor panes use the configured monospaced font and indentation. Recovery copies are always enabled."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Privacy") {
          Text(
            "Editing works offline. tCode has no account, telemetry, or source upload. Language tools run locally when you choose Enable Language Tools in a workspace."
          )
        }
      }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(packs, id: \.id) { pack in
            GroupBox(pack.name) {
              VStack(alignment: .leading, spacing: 8) {
                Toggle(
                  "Enabled",
                  isOn: Binding(
                    get: { !disabled.contains(pack.id) },
                    set: { enabled in
                      if enabled { disabled.remove(pack.id) } else { disabled.insert(pack.id) }
                      UserDefaults.standard.set(!enabled, forKey: "disabled." + pack.id)
                      NotificationCenter.default.post(name: .tcodeToolSettingsChanged, object: nil)
                    }))
                ForEach([pack.server, pack.formatter, pack.adapter], id: \.self) { tool in
                  TextField(
                    tool + " path",
                    text: Binding(
                      get: { paths[tool] ?? ToolLocator.find(tool) ?? "" },
                      set: {
                        paths[tool] = $0
                        UserDefaults.standard.set($0, forKey: "tool." + tool)
                      })
                  ).textFieldStyle(.roundedBorder)
                }
              }.padding(6)
            }
          }
          Button("Show Tool Versions and Logs") {
            if let current = (NSApp.delegate as? AppDelegate)?.current {
              current.window?.makeKeyAndOrderFront(nil)
              current.perform("toolVersions")
            }
          }
          Text(
            "Python: select an interpreter in Run Configuration. Use a project .venv or configure pylsp / Ruff paths. Tools are never installed when you open a folder. Tool versions and logs are available from the workspace command palette."
          ).font(.caption).foregroundStyle(.secondary)
        }.padding()
      }.tabItem { Label("Language Tools", systemImage: "puzzlepiece.extension") }
      ShortcutsView().tabItem { Label("Shortcuts", systemImage: "keyboard") }
    }.padding().frame(width: 660, height: 530).onAppear {
      disabled = Set(packs.filter { !$0.enabled }.map(\.id))
    }
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
    Form {
      Text("Customize a tCode menu command. Changes apply immediately.")
        .foregroundStyle(.secondary)
      Picker("Command", selection: $command) {
        ForEach(Self.catalog) { Text($0.label).tag($0.id) }
      }
      .onChange(of: command) { _, value in
        guard let next = Self.catalog.first(where: { $0.id == value }) else { return }
        key = next.key
        modifiers = next.modifiers
      }
      LabeledContent("Current shortcut", value: current())
      TextField("Key (one character)", text: $key)
      TextField("Modifiers", text: $modifiers)
      Text("Modifiers: command, shift, option, control. Separate with spaces.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("Apply Shortcut") {
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
        Button("Reset This Command") {
          var bindings = customBindings()
          bindings.removeValue(forKey: command)
          UserDefaults.standard.set(bindings, forKey: "keybindings")
          (NSApp.delegate as? AppDelegate)?.makeMenu()
          key = entry.key
          modifiers = entry.modifiers
          result = "\(entry.label) restored to \(entry.glyph)."
        }
      }
      Button("Restore All Default Shortcuts") {
        UserDefaults.standard.removeObject(forKey: "keybindings")
        (NSApp.delegate as? AppDelegate)?.makeMenu()
        result = "Defaults restored."
      }
      Text(result).foregroundStyle(.secondary)
    }.formStyle(.grouped)
  }

  private func customBindings() -> [String: [String: String]] {
    UserDefaults.standard.dictionary(forKey: "keybindings") as? [String: [String: String]] ?? [:]
  }
}
