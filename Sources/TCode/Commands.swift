import AppKit
import TCodeCore

extension WorkspaceWindow {
  func perform(_ command: String) {
    switch command {
    case "about":
      NSApp.orderFrontStandardAboutPanel(options: [
        .applicationName: "tCode", .applicationVersion: "0.1.0",
        .credits: NSAttributedString(string: "Native macOS IDE · Apple Silicon"),
      ])
    case "quit": NSApp.terminate(nil)
    case "minimize": window?.miniaturize(nil)
    case "fullscreen": window?.toggleFullScreen(nil)
    case "newFile":
      let doc = CodeDocument()
      DocumentPool.shared.documents.append(doc)
      add(doc)
    case "openFile":
      let p = NSOpenPanel()
      p.directoryURL = root
      if p.runModal() == .OK, let url = p.url { open(url) }
    case "recent":
      let paths = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
      choose("Recent Projects", items: paths) { i in
        (NSApp.delegate as? AppDelegate)?.newWindow(URL(fileURLWithPath: paths[i]))
      }
    case "save": if let doc = active { save(doc) }
    case "undo": active?.undo.undo()
    case "redo": active?.undo.redo()
    case "saveAs": if let doc = active { save(doc, asNew: true) }
    case "saveAll": documents.filter(\.modified).forEach { save($0) }
    case "closeTab": closeTab()
    case "reload":
      if let doc = active {
        if doc.modified {
          let a = NSAlert()
          a.messageText = "Reload from disk?"
          a.informativeText = "Your current buffer will first be kept in recovery."
          a.addButton(withTitle: "Reload")
          a.addButton(withTitle: "Cancel")
          if a.runModal() != .alertFirstButtonReturn { return }
        }
        Task {
          do {
            if doc.modified { try await CodeDocument.recovery.write(doc.recoveryRecord()) }
            try await doc.reload()
            panes.forEach { $0.highlight() }
          } catch { report(error) }
        }
      }
    case "createFile", "newFolder", "rename", "move", "duplicate", "trash", "reveal", "copyPath":
      fileCommand(command)
    case "sidebar": outer.splitViewItems.first?.isCollapsed.toggle()
    case "panel":
      if vertical.splitViewItems.last?.isCollapsed == true {
        showBottom(selectedPanel)
      } else {
        syncPanelHeight()
        vertical.splitViewItems.last?.isCollapsed = true
      }
    case "inspector": outer.splitViewItems.last?.isCollapsed.toggle()
    case "splitVertical", "splitHorizontal":
      guard let doc = active else { return }
      editorSplit.splitView.isVertical = command == "splitVertical"
      addPane(doc)
    case "closeSplit":
      if panes.count > 1, let item = editorSplit.splitViewItems.last {
        editorSplit.removeSplitViewItem(item)
        panes.removeLast()
      }
    case "wrap":
      guard let e = focusedEditor else { return }
      e.isHorizontallyResizable.toggle()
      e.enclosingScrollView?.hasHorizontalScroller = e.isHorizontallyResizable
      e.textContainer?.widthTracksTextView = !e.isHorizontallyResizable
      e.textContainer?.containerSize.width = e.isHorizontallyResizable ? 100000 : e.bounds.width
    case "comment": focusedEditor?.toggleComment(nil)
    case "duplicateLine": focusedEditor?.duplicateLine(nil)
    case "multiSelect": focusedEditor?.selectNextOccurrence(nil)
    case "cursorBelow": focusedEditor?.addCursorBelow(nil)
    case "cursorAbove": focusedEditor?.addCursorAbove(nil)
    case "fold": focusedEditor?.foldSelection(nil)
    case "snippet": snippet()
    case "find":
      guard let target = focusedEditor, let scroll = target.enclosingScrollView else {
        status.stringValue = "Open a file to search inside it."
        return
      }
      if scroll.findBarPosition != .aboveContent { scroll.findBarPosition = .aboveContent }
      window?.makeFirstResponder(target)
      target.scrollRangeToVisible(target.selectedRange())
      let item = NSMenuItem()
      item.tag = NSTextFinder.Action.showFindInterface.rawValue
      target.performFindPanelAction(item)
    case "regexReplace": regexReplace()
    case "goLine":
      if let input = input("Go to line", defaultValue: "1"), let line = Int(input) {
        panes.first?.go(to: Position(line: max(0, line - 1), character: 0))
      }
    case "back":
      if let (url, position) = history.popLast() {
        open(url, position: position, recordHistory: false)
      }
    case "quickOpen": quickOpen()
    case "palette": commandPalette()
    case "search", "replaceProject": searchProject(replace: command == "replaceProject")
    case "enableLanguages":
      languageEnabled = true
      if let doc = active { activateLanguage(doc) }
      status.stringValue = "Language tools enabled for this workspace"
    case "toolVersions": toolVersions()
    case "completion", "hover", "signatureHelp", "definition", "references", "symbols",
      "renameSymbol", "codeAction":
      languageCommand(command)
    case "format": formatDocument()
    case "terminal": newTerminal()
    case "terminalSessions":
      choose("Terminal Sessions", items: terminalViews.indices.map { "zsh \($0+1)" }) {
        [weak self] index in
        guard let self else { return }
        let terminal = self.terminalViews.remove(at: index)
        self.terminalViews.append(terminal)
        self.showBottom(0)
        self.window?.makeFirstResponder(terminal)
      }
    case "closeTerminal":
      terminalViews.popLast()?.terminate()
      showPanelContent()
    case "run", "build", "test", "discoverTests": runTask(command)
    case "cancel":
      taskHandle?.cancel()
      taskProcess?.cancel()
    case "configuration": editConfiguration()
    case "gitRefresh", "stage", "unstage", "diff", "commit", "history", "branch":
      gitCommand(command)
    case "debug": startDebugging()
    case "breakpoint":
      guard let doc = active, let url = doc.url, let pane = panes.first else { return }
      let line =
        PositionMap.position(
          in: doc.text, utf16Offset: focusedEditor?.selectedRange().location ?? 0
        ).line + 1
      var lines = breakpoints[url] ?? []
      if lines.contains(line) { lines.remove(line) } else { lines.insert(line) }
      breakpoints[url] = lines
      pane.ruler.breakpoints = lines
      pane.ruler.needsDisplay = true
      debugSession?.setBreakpoints(url, lines: Array(lines))
      status.stringValue = "Breakpoint toggled at line \(line)"
    case "continue", "pause", "next", "stepIn", "stepOut":
      Task { do { try await debugSession?.command(command) } catch { report(error) } }
    case "stopDebug":
      debugSession?.stop()
      debugSession = nil
    case "variables": inspectVariables()
    case "watch": addWatch()
    case "watches": inspectWatches()
    case "removeWatch":
      choose("Remove Watch", items: watchExpressions) { [weak self] index in
        self?.watchExpressions.remove(at: index)
        self?.persistWatches()
      }
    case "callStack":
      if let session = debugSession {
        choose(
          "Call Stack",
          items: session.frames.map { "\($0["name"] ?? "frame") : \($0["line"] ?? 0)" }
        ) { session.select(session.frames[$0]) }
      }
    default: break
    }
  }
  var focusedEditor: CodeTextView? { (window?.firstResponder as? CodeTextView) ?? editor }
  func fileCommand(_ command: String) {
    let selection = selectedURL
    var parent = selection?.deletingLastPathComponent() ?? root
    if let node = outline.item(atRow: outline.selectedRow) as? FileNode, node.directory {
      parent = node.url
    }
    switch command {
    case "createFile", "newFolder":
      guard let parent else {
        report(TCodeError.message("Open a project folder first."))
        return
      }
      guard let name = input(command == "createFile" ? "New file name" : "New folder name") else {
        return
      }
      Task {
        do {
          let url = try await Task.detached {
            try FileIO.create(in: parent, name: name, directory: command == "newFolder")
          }.value
          reloadTree()
          if command == "createFile" { open(url) }
        } catch { report(error) }
      }
    case "rename", "move":
      guard let selection else { return }
      let destination: URL
      let name: String
      if command == "rename" {
        guard let value = input("Rename", defaultValue: selection.lastPathComponent) else { return }
        name = value
        destination = selection.deletingLastPathComponent()
      } else {
        let p = NSOpenPanel()
        p.title = "Move item to folder"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        if p.runModal() != .OK { return }
        guard let folder = p.url else { return }
        destination = folder
        name = selection.lastPathComponent
      }
      Task {
        do {
          let to = try await Task.detached {
            try FileIO.move(selection, into: destination, name: name)
          }.value
          DocumentPool.shared.moved(from: selection, to: to)
          reloadTree()
          updateTabs()
          if languageEnabled, let doc = active { activateLanguage(doc) }
        } catch { report(error) }
      }
    case "duplicate":
      guard let selection,
        let name = input(
          "Duplicate as",
          defaultValue: selection.deletingPathExtension().lastPathComponent + " copy"
            + (selection.pathExtension.isEmpty ? "" : "." + selection.pathExtension))
      else { return }
      Task {
        do {
          try await Task.detached {
            try FileIO.validate(name)
            try FileManager.default.copyItem(
              at: selection, to: selection.deletingLastPathComponent().appendingPathComponent(name))
          }.value
          reloadTree()
        } catch { report(error) }
      }
    case "trash":
      guard let selection else { return }
      let a = NSAlert()
      a.messageText = "Move \(selection.lastPathComponent) to Trash?"
      a.informativeText = "Open buffers will be kept as unsaved documents."
      a.addButton(withTitle: "Move to Trash")
      a.addButton(withTitle: "Cancel")
      guard a.runModal() == .alertFirstButtonReturn else { return }
      Task {
        do {
          try await Task.detached {
            try FileManager.default.trashItem(at: selection, resultingItemURL: nil)
          }.value
          for doc in DocumentPool.shared.documents
          where doc.url == selection || doc.url?.path.hasPrefix(selection.path + "/") == true {
            doc.languageSession?.close(doc, url: doc.url)
            doc.languageSession = nil
            doc.url = nil
            doc.baseline = nil
            try await CodeDocument.recovery.write(doc.recoveryRecord())
          }
          reloadTree()
          updateTabs()
        } catch { report(error) }
      }
    case "reveal": if let selection { NSWorkspace.shared.activateFileViewerSelecting([selection]) }
    case "copyPath":
      if let selection {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selection.path, forType: .string)
      }
    default: break
    }
  }
  func commandPalette() {
    let commands: [(String, String)] = [
      ("Enable Language Tools in Workspace", "enableLanguages"), ("Quick Open", "quickOpen"),
      ("Find in Workspace…", "search"), ("Replace in Workspace…", "replaceProject"),
      ("Find / Replace with Regex", "regexReplace"),
      ("Create File in Sidebar Folder", "createFile"), ("Create Nested Folder", "newFolder"),
      ("Reload from Disk", "reload"), ("Save All", "saveAll"), ("Format Document", "format"),
      ("Go to Symbol", "symbols"), ("Document Completion", "completion"),
      ("Toggle Comment", "comment"), ("Split Vertically", "splitVertical"),
      ("Split Horizontally", "splitHorizontal"), ("Run", "run"), ("Build", "build"),
      ("Test", "test"), ("Discover Tests", "discoverTests"), ("Start Debugging", "debug"),
      ("Call Stack", "callStack"), ("Inspect Variables", "variables"),
      ("Add Watch Expression", "watch"), ("Inspect Watches", "watches"),
      ("Remove Watch Expression", "removeWatch"), ("Stop Debugging", "stopDebug"),
      ("New Terminal", "terminal"), ("Switch Terminal Session", "terminalSessions"),
      ("Close Current Terminal", "closeTerminal"), ("Git Status", "gitRefresh"),
      ("Stage File", "stage"), ("Unstage File", "unstage"), ("Commit Staged Changes", "commit"),
      ("Language Tool Versions and Logs", "toolVersions"),
    ]
    choose("Command Palette", items: commands.map(\.0)) { [weak self] index in
      self?.perform(commands[index].1)
    }
  }
  func quickOpen() {
    guard let root else {
      perform("openFile")
      return
    }
    searchHandle?.cancel()
    searchHandle = Task {
      do {
        let exclusions = EditorConfiguration.load(root: root, file: nil).exclusions
        let urls = try await Background.run { try FileIO.indexedFiles(root, excluding: exclusions) }
        guard !Task.isCancelled else { return }
        choose("Quick Open", items: urls.map { String($0.path.dropFirst(root.path.count + 1)) }) {
          [weak self] index in self?.open(urls[index])
        }
      } catch { report(error) }
    }
  }
  func regexReplace() {
    guard let e = focusedEditor, let pattern = input("Find regular expression"),
      let replacement = input("Replacement template", detail: "Use $1, $2 for capture groups.")
    else { return }
    do {
      let expression = try NSRegularExpression(pattern: pattern)
      let range = NSRange(location: 0, length: e.string.utf16.count)
      let value = expression.stringByReplacingMatches(
        in: e.string, range: range, withTemplate: replacement)
      let a = NSAlert()
      a.messageText = "Replace \(expression.numberOfMatches(in:e.string,range:range)) matches?"
      a.addButton(withTitle: "Replace All")
      a.addButton(withTitle: "Cancel")
      if a.runModal() == .alertFirstButtonReturn {
        e.replace(range, with: value, action: "Regex Replace")
      }
    } catch { report(error) }
  }
  func snippet() {
    let options: [(String, String)]
    switch active?.url?.pathExtension {
    case "py":
      options = [
        ("Function", "def name():\n    pass\n"),
        ("Main guard", "if __name__ == \"__main__\":\n    main()\n"),
      ]
    case "cpp", "cc", "c", "h", "hpp":
      options = [
        ("Function", "void name() {\n    \n}\n"), ("Main", "int main() {\n    return 0;\n}\n"),
      ]
    default: options = [("Function", "func name() {\n    \n}\n"), ("Comment", "// MARK: - \n")]
    }
    choose("Insert Snippet", items: options.map(\.0)) { [weak self] index in
      guard let e = self?.focusedEditor else { return }
      e.insertText(options[index].1, replacementRange: e.selectedRange())
    }
  }
  func searchProject(replace: Bool) {
    guard let root,
      let pattern = input(
        replace
          ? "Replace in Workspace — search pattern" : "Find in Workspace — search pattern",
        detail:
          "Regular expressions are supported. Dependency and build folders are excluded. Files above 2 MB are skipped."
      ), !pattern.isEmpty
    else { return }
    let replacement =
      replace
      ? input("Replacement template", detail: "You will review all changed files before applying.")
      : nil
    if replace && replacement == nil { return }
    searchHandle?.cancel()
    status.stringValue = "Searching…"
    let exclusions = EditorConfiguration.load(root: root, file: nil).exclusions
    searchHandle = Task {
      do {
        if let replacement {
          if DocumentPool.shared.documents.contains(where: {
            $0.modified && $0.url?.path.hasPrefix(root.path + "/") == true
          }) {
            throw TCodeError.message(
              "Save or close modified workspace buffers before a project replacement.")
          }
          let changes = try await Background.run {
            try WorkspaceSearch.replacements(
              root: root, pattern: pattern, replacement: replacement, regex: true,
              excluding: exclusions)
          }
          guard !Task.isCancelled else { return }
          if review(changes, title: "Review Workspace Replacement") {
            try await Task.detached { try WorkspaceSearch.apply(changes) }.value
            for doc in documents where changes.contains(where: { $0.url == doc.url }) {
              try await doc.reload()
            }
            panes.forEach { $0.highlight() }
            appendOutput("Replaced text in \(changes.count) files.\n")
          }
        } else {
          let hits = try await Background.run {
            try WorkspaceSearch.find(
              root: root, pattern: pattern, regex: true, excluding: exclusions)
          }
          guard !Task.isCancelled else { return }
          choose(
            "\(hits.count) Results",
            items: hits.map { "\($0.url.lastPathComponent):\($0.line+1)  \($0.preview)" }
          ) { [weak self] index in
            self?.open(hits[index].url, position: Position(line: hits[index].line, character: 0))
          }
        }
        updateStatus()
      } catch is CancellationError {} catch { report(error) }
    }
  }
  func review(_ changes: [FileChange], title: String) -> Bool {
    guard !changes.isEmpty else {
      status.stringValue = "No changes"
      return false
    }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText =
      "\(changes.count) files. All original bytes are checked again before saving."
    let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 360))
    sc.hasVerticalScroller = true
    sc.autohidesScrollers = true
    let tv = NSTextView(frame: sc.bounds)
    tv.isEditable = false
    tv.font = Style.mono
    tv.textColor = Style.editorText
    tv.backgroundColor = Style.editorBackground
    tv.textContainerInset = Style.textInsets
    tv.textContainer?.lineFragmentPadding = 0
    // Same scrollable setup as the output panels: long previews scroll instead of clipping.
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    tv.textContainer?.widthTracksTextView = true
    tv.minSize = NSZeroSize
    tv.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    tv.string = changes.map { c in
      "FILE: \(c.url.path)\n\nBEFORE\n\((try? TextFile(data:c.before).text) ?? "")\n\nAFTER\n\(c.text)\n\n────────────────────────────\n"
    }.joined()
    sc.documentView = tv
    alert.accessoryView = sc
    alert.addButton(withTitle: "Apply Reviewed Changes")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
  func activateLanguage(_ doc: CodeDocument) {
    guard let root, let url = doc.url,
      let pack = packs.first(where: { $0.enabled && $0.extensions.contains(url.pathExtension) }),
      !doc.large
    else { return }
    Task {
      do {
        if services[pack.id] == nil {
          let service = LanguageSession(pack: pack)
          services[pack.id] = service
          service.log = { [weak self] text in self?.appendOutput(text) }
          service.applyEdit = { [weak self] edit, encoding in
            guard let self else { return false }
            return try await self.applyWorkspaceEdit(edit, encoding: encoding)
          }
          service.diagnostics = { [weak self] uri, list in
            self?.diagnosticList[uri] = list
            self?.refreshProblems()
          }
          try await service.start(
            root: root,
            pythonInterpreter: configuration.python.isEmpty
              ? ToolLocator.find("python3", root: root) : configuration.python)
        }
        if let service = services[pack.id], service.ready { try await service.open(doc) }
        updateStatus()
      } catch {
        services.removeValue(forKey: pack.id)?.stop()
        appendOutput(error.localizedDescription + "\n")
        status.stringValue = error.localizedDescription
      }
    }
  }
  func refreshProblems() {
    let entries = diagnosticList.sorted { $0.key < $1.key }.flatMap { uri, list in
      list.map { d -> String in
        let p = (d["range"] as? [String: Any])?["start"] as? [String: Int]
        return
          "\(URL(string:uri)?.path ?? uri):\((p?["line"] ?? 0)+1):\((p?["character"] ?? 0)+1)  \(d["message"] ?? "")"
      }
    }
    problems.string =
      entries.isEmpty ? "No problems detected." : entries.joined(separator: "\n\n")
    linkHandler.decorate(problems)
    panelSelector.setLabel(
      entries.isEmpty ? "Problems" : "Problems (\(entries.count))", forSegment: 1)
    for pane in panes {
      guard let uri = pane.document.url?.absoluteString, let lm = pane.editor.layoutManager else {
        continue
      }
      lm.removeTemporaryAttribute(
        .underlineStyle,
        forCharacterRange: NSRange(location: 0, length: pane.document.storage.length))
      for d in diagnosticList[uri] ?? [] {
        if let json = d["range"] as? [String: Any],
          let range = PositionMap.range(
            in: pane.document.text, json: json,
            encoding: pane.document.languageSession?.encoding ?? "utf-16")
        {
          // Errors, warnings, information and hints stay visually distinct in the editor.
          lm.addTemporaryAttributes(
            [
              .underlineStyle: NSUnderlineStyle.patternDot.rawValue
                | NSUnderlineStyle.single.rawValue,
              .underlineColor: Style.diagnostic(severity: d["severity"] as? Int),
            ], forCharacterRange: range)
        }
      }
    }
  }
  func languageCommand(_ command: String) {
    guard let doc = active, let editor = focusedEditor else { return }
    guard let service = doc.languageSession, service.ready else {
      languageEnabled = true
      activateLanguage(doc)
      status.stringValue = "Starting language tools. Retry the command when connected."
      return
    }
    let feature = ["symbols": "documentSymbol", "renameSymbol": "rename"][command] ?? command
    var extras: [String: Any] = [:]
    if command == "renameSymbol" {
      guard let name = input("New symbol name"), !name.isEmpty else { return }
      extras["newName"] = name
    }
    if command == "references" { extras["context"] = ["includeDeclaration": true] }
    if command == "codeAction" {
      let p = PositionMap.position(
        in: doc.text, utf16Offset: editor.selectedRange().location, encoding: service.encoding
      ).json
      extras["range"] = ["start": p, "end": p]
      extras["context"] = ["diagnostics": diagnosticList[doc.url?.absoluteString ?? ""] ?? []]
    }
    Task {
      do {
        let result = try await service.request(
          feature, document: doc, offset: editor.selectedRange().location, extras: extras)
        switch command {
        case "completion":
          let items =
            (result as? [[String: Any]]) ?? (result as? [String: Any])?["items"] as? [[String: Any]]
            ?? []
          let version = doc.version
          let selection = editor.selectedRange()
          choose("Completion", items: items.map { $0["label"] as? String ?? "" }) {
            [weak self] index in
            guard doc.version == version else {
              self?.status.stringValue = "Completion expired after an edit"
              return
            }
            let item = items[index]
            do {
              try self?.applyCompletion(
                item, editor: editor, document: doc, selection: selection,
                encoding: service.encoding)
            } catch { self?.report(error) }
          }
        case "definition", "references":
          let locations =
            result as? [[String: Any]] ?? (result as? [String: Any]).map { [$0] } ?? []
          choose(
            command == "definition" ? "Definitions" : "References",
            items: locations.map { "\($0["uri"] ?? $0["targetUri"] ?? "")" }
          ) { [weak self] index in
            let location = locations[index]
            if let uri = (location["uri"] ?? location["targetUri"]) as? String,
              let url = URL(string: uri),
              let range = (location["range"] ?? location["targetSelectionRange"]) as? [String: Any],
              let start = range["start"] as? [String: Int]
            {
              self?.open(
                url,
                position: Position(line: start["line"] ?? 0, character: start["character"] ?? 0),
                encoding: service.encoding)
            }
          }
        case "symbols":
          func flatten(_ symbols: [[String: Any]]) -> [[String: Any]] {
            symbols.flatMap { [$0] + flatten($0["children"] as? [[String: Any]] ?? []) }
          }
          let symbols = flatten(result as? [[String: Any]] ?? [])
          choose("Document Symbols", items: symbols.map { $0["name"] as? String ?? "" }) {
            [weak self] index in
            let s = symbols[index]
            let r =
              (s["selectionRange"] ?? s["range"] ?? (s["location"] as? [String: Any])?["range"])
              as? [String: Any]
            if let start = r?["start"] as? [String: Int] {
              self?.panes.first?.go(
                to: Position(line: start["line"] ?? 0, character: start["character"] ?? 0),
                encoding: service.encoding)
            }
          }
        case "renameSymbol":
          if let edit = result as? [String: Any] {
            try await applyWorkspaceEdit(edit, encoding: service.encoding)
          }
        case "codeAction":
          let actions = result as? [[String: Any]] ?? []
          choose("Code Actions", items: actions.map { $0["title"] as? String ?? "" }) {
            [weak self] index in
            guard let self else { return }
            Task {
              do {
                var action = actions[index]
                if action["edit"] == nil, action["command"] == nil,
                  (service.capabilities["codeActionProvider"] as? [String: Any])?["resolveProvider"]
                    as? Bool == true
                {
                  let response = try await service.connection.request(
                    "codeAction/resolve", params: action)
                  action = response["result"] as? [String: Any] ?? action
                }
                if let edit = action["edit"] as? [String: Any],
                  !(try await self.applyWorkspaceEdit(edit, encoding: service.encoding))
                {
                  return
                }
                let command =
                  (action["command"] as? [String: Any])
                  ?? (action["command"] as? String).map {
                    ["command": $0, "arguments": action["arguments"] ?? []]
                  }
                if let command, let name = command["command"] as? String {
                  let advertised =
                    (service.capabilities["executeCommandProvider"] as? [String: Any])?["commands"]
                    as? [String] ?? []
                  guard advertised.contains(name) else {
                    throw TCodeError.message("The server did not advertise this command.")
                  }
                  let alert = NSAlert()
                  alert.messageText = action["title"] as? String ?? "Language Server Command"
                  alert.informativeText =
                    "Run \(name) using the local \(service.pack.name) server? File edits requested by the server will be reviewed separately."
                  alert.addButton(withTitle: "Run Command")
                  alert.addButton(withTitle: "Cancel")
                  if alert.runModal() == .alertFirstButtonReturn {
                    _ = try await service.connection.request(
                      "workspace/executeCommand", params: command)
                  }
                }
              } catch { self.report(error) }
            }
          }
        default:
          showText(
            command == "hover" ? "Hover" : "Signature Help", text: languageInformation(result))
        }
      } catch { report(error) }
    }
  }
  @discardableResult func applyWorkspaceEdit(_ edit: [String: Any], encoding: String) async throws
    -> Bool
  {
    var edits = edit["changes"] as? [String: [[String: Any]]] ?? [:]
    for change in edit["documentChanges"] as? [[String: Any]] ?? [] {
      guard change["kind"] == nil, let td = change["textDocument"] as? [String: Any],
        let uri = td["uri"] as? String, let values = change["edits"] as? [[String: Any]]
      else {
        throw TCodeError.message(
          "Resource creation, rename and deletion require the project file list.")
      }
      if let version = td["version"] as? Int,
        let doc = DocumentPool.shared.documents.first(where: { $0.url?.absoluteString == uri }),
        version != doc.version
      {
        throw TCodeError.message("The server edit targets an old document version.")
      }
      edits[uri] = values
    }
    var changes: [FileChange] = []
    for (uri, values) in edits {
      guard let url = URL(string: uri), url.isFileURL else {
        throw TCodeError.message("Only local file edits are supported.")
      }
      if let doc = DocumentPool.shared.documents.first(where: { $0.url == url }), doc.modified {
        throw TCodeError.message("Save \(doc.title) before applying a workspace edit.")
      }
      let before = try await Task.detached { try Data(contentsOf: url) }.value
      let file = try TextFile(data: before)
      var text = file.text
      let replacements = try values.map { item -> (NSRange, String) in
        guard let json = item["range"] as? [String: Any],
          let range = PositionMap.range(in: file.text, json: json, encoding: encoding),
          let value = item["newText"] as? String
        else { throw TCodeError.message("Invalid server edit.") }
        return (range, value)
      }.sorted { $0.0.location > $1.0.location }
      var last = text.utf16.count
      for (range, value) in replacements {
        guard NSMaxRange(range) <= last else {
          throw TCodeError.message("Overlapping edits rejected.")
        }
        text = (text as NSString).replacingCharacters(in: range, with: value)
        last = range.location
      }
      changes.append(FileChange(url: url, before: before, after: try file.encode(text), text: text))
    }
    if review(changes, title: "Review Language Server Edits") {
      try await Task.detached { try WorkspaceSearch.apply(changes) }.value
      for doc in DocumentPool.shared.documents where changes.contains(where: { $0.url == doc.url })
      { try await doc.reload() }
      panes.forEach { $0.highlight() }
      return true
    }
    return false
  }
  func applyCompletion(
    _ item: [String: Any], editor: CodeTextView, document: CodeDocument, selection: NSRange,
    encoding: String
  ) throws {
    var primary: (NSRange, String)
    if let edit = item["textEdit"] as? [String: Any],
      let json = (edit["range"] ?? edit["replace"]) as? [String: Any],
      let range = PositionMap.range(in: document.text, json: json, encoding: encoding),
      let value = edit["newText"] as? String
    {
      primary = (range, value)
    } else {
      let ns = document.text as NSString
      var start = selection.location
      while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)),
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar)
      { start -= 1 }
      primary = (
        NSRange(location: start, length: selection.location - start),
        item["insertText"] as? String ?? item["label"] as? String ?? ""
      )
    }
    var replacements = [primary]
    for edit in item["additionalTextEdits"] as? [[String: Any]] ?? [] {
      guard let json = edit["range"] as? [String: Any],
        let range = PositionMap.range(in: document.text, json: json, encoding: encoding),
        let text = edit["newText"] as? String
      else { throw TCodeError.message("Invalid completion edit.") }
      replacements.append((range, text))
    }
    replacements.sort { $0.0.location > $1.0.location }
    var last = document.storage.length
    for (range, _) in replacements {
      guard NSMaxRange(range) <= last else {
        throw TCodeError.message("Overlapping completion edits rejected.")
      }
      last = range.location
    }
    let shift = replacements.filter { $0.0.location < primary.0.location }.reduce(0) {
      $0 + $1.1.utf16.count - $1.0.length
    }
    document.undo.beginUndoGrouping()
    defer { document.undo.endUndoGrouping() }
    for (range, text) in replacements { editor.replace(range, with: text, action: "Complete") }
    editor.setSelectedRange(
      NSRange(location: primary.0.location + primary.1.utf16.count + shift, length: 0))
  }
  func languageInformation(_ value: Any) -> String {
    if value is NSNull { return "No information at this location." }
    if let text = value as? String { return text }
    if let list = value as? [Any] { return list.map(languageInformation).joined(separator: "\n\n") }
    if let object = value as? [String: Any] {
      if let content = object["contents"] ?? object["value"] { return languageInformation(content) }
      if let signatures = object["signatures"] as? [[String: Any]] {
        return signatures.map {
          ($0["label"] as? String ?? "") + "\n" + languageInformation($0["documentation"] ?? "")
        }.joined(separator: "\n\n")
      }
    }
    return String(describing: value)
  }
  func formatDocument() {
    guard let doc = active, let ext = doc.url?.pathExtension,
      let pack = packs.first(where: { $0.extensions.contains(ext) }),
      let tool = ToolLocator.find(pack.formatter, root: root), let e = focusedEditor
    else {
      status.stringValue = "Formatter missing — configure its path in Settings"
      return
    }
    let text = doc.text
    let version = doc.version
    let args =
      pack.id == "python"
      ? ["format", "--stdin-filename", doc.url?.path ?? "file.py", "-"]
      : pack.id == "swift" ? ["format"] : ["--assume-filename=" + (doc.url?.path ?? "file.cpp")]
    Task {
      do {
        let result = try await RunningProcess().run(
          executable: tool, arguments: args, directory: root, input: Data(text.utf8))
        guard result.status == 0 else { throw TCodeError.message(result.output) }
        guard doc.version == version else {
          throw TCodeError.message("The buffer changed while formatting.")
        }
        e.replace(
          NSRange(location: 0, length: doc.storage.length), with: result.stdout,
          action: "Format Document")
      } catch { report(error) }
    }
  }
  func toolVersions() {
    showBottom(2)
    Task {
      for name in Set(
        packs.flatMap { [$0.server, $0.formatter, $0.adapter] } + ["python3", "cmake", "swift"])
      {
        if let path = ToolLocator.find(name, root: root) {
          appendOutput("\n\(name): \(path)\n")
          do {
            let result = try await RunningProcess().run(
              executable: path, arguments: name == "sourcekit-lsp" ? ["--help"] : ["--version"],
              directory: nil)
            appendOutput(result.output)
          } catch { appendOutput(error.localizedDescription) }
        } else {
          appendOutput("\n\(name): missing — configure path in Settings\n")
        }
      }
    }
  }
}
