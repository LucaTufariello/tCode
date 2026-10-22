import AppKit
import TCodeCore

extension WorkspaceWindow {
  func runTask(_ action: String) {
    guard let root else {
      report(TCodeError.message("Open a workspace folder first."))
      return
    }
    guard taskHandle == nil else {
      status.stringValue = "A task is running. Cancel it before starting another."
      return
    }
    guard !documents.contains(where: \.modified) else {
      status.stringValue = "Save modified buffers before running a task (File → Save All)."
      return
    }
    let task: LanguageTask
    if action == "run", !configuration.executable.isEmpty {
      let executable =
        configuration.executable.hasPrefix("/")
        ? configuration.executable : root.appendingPathComponent(configuration.executable).path
      task = .init(steps: [.init(executable: executable, arguments: configuration.arguments)])
    } else {
      let current = active.flatMap { recognizeLanguage($0)?.pack }
      func available(_ task: LanguageTask) -> Bool {
        task.rootMarkers.isEmpty
          || task.rootMarkers.contains {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
          }
      }
      let candidates = packs.compactMap { pack -> LanguageTask? in
        guard pack.enabled, let task = pack.tasks[action], !task.rootMarkers.isEmpty,
          available(task)
        else { return nil }
        return task
      }
      if let selected = current?.tasks[action], available(selected) {
        task = selected
      } else if candidates.count == 1 {
        task = candidates[0]
      } else {
        status.stringValue =
          candidates.count > 1
          ? "Multiple task providers match. Select a source file or configure Run."
          : "This language pack has no matching \(action) task. Configure Run or install language support."
        return
      }
    }
    let context = LanguageRuntime.context(
      root: root, file: active?.url,
      python: configuration.python.isEmpty ? nil : configuration.python)
    let baseDirectory =
      configuration.workingDirectory.isEmpty
      ? root
      : URL(fileURLWithPath: configuration.workingDirectory, relativeTo: root).standardizedFileURL
    showBottom(2)
    taskHandle = Task { [weak self] in
      guard let self else { return }
      let started = Date()
      defer {
        self.taskHandle = nil
        self.taskProcess = nil
      }
      do {
        var resultText = ""
        for definition in task.steps {
          try Task.checkCancellation()
          let command = try definition.resolved(context)
          guard let executable = ToolLocator.find(command.executable, root: root) else {
            throw TCodeError.message(
              "Missing task tool: \(command.executable). Open Settings → Language Support.")
          }
          let directory =
            command.workingDirectory.map {
              URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
            } ?? baseDirectory
          self.appendOutput("\n› \(executable) \(command.arguments.joined(separator: " "))\n")
          let process = RunningProcess()
          self.taskProcess = process
          let result = try await process.run(
            executable: executable, arguments: command.arguments, directory: directory,
            environment: command.environment.merging(configuration.environment) { _, user in user },
            output: { [weak self] text in Task { @MainActor in self?.appendOutput(text) } })
          try Task.checkCancellation()
          resultText += result.output
          self.appendOutput("\nExited \(result.status)\n")
          guard result.status == 0 else {
            throw TCodeError.message(
              "\(action.capitalized) exited \(result.status). See Build Output.")
          }
        }
        self.status.stringValue =
          "\(action.capitalized) completed in \(String(format: "%.2f", Date().timeIntervalSince(started))) s"
        if ["test", "discoverTests"].contains(action), let parser = task.resultParser {
          await self.showTestResults(TestReports.parse(resultText, runner: parser), root: root)
        }
      } catch is CancellationError { self.appendOutput("\nTask cancelled.\n") } catch {
        self.status.stringValue = error.localizedDescription
        self.appendOutput("\n" + error.localizedDescription + "\n")
      }
    }
  }
  func editConfiguration() {
    let alert = NSAlert()
    alert.messageText = "Run Configuration"
    alert.informativeText =
      "Executed only when you choose Run or Debug. Arguments use one argument per line. Environment uses KEY=value per line."
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 7
    let names = [
      "Executable path", "Arguments (one per line)", "Working directory (empty = workspace)",
      "Environment (KEY=value per line)", "Python interpreter path", "Debug program path",
    ]
    let values = [
      configuration.executable, configuration.arguments.joined(separator: "\n"),
      configuration.workingDirectory,
      configuration.environment.sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(
        separator: "\n"), configuration.python, configuration.debugProgram,
    ]
    var fields: [NSTextField] = []
    for (name, value) in zip(names, values) {
      let label = NSTextField(labelWithString: name)
      label.font = Style.caption
      let field = NSTextField(string: value)
      field.widthAnchor.constraint(equalToConstant: 520).isActive = true
      field.cell?.wraps = true
      field.cell?.isScrollable = false
      if name.hasPrefix("Arguments") || name.hasPrefix("Environment") {
        field.heightAnchor.constraint(equalToConstant: 50).isActive = true
      }
      fields.append(field)
      stack.addArrangedSubview(label)
      stack.addArrangedSubview(field)
    }
    alert.accessoryView = stack
    alert.addButton(withTitle: "Save Configuration")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    configuration.executable = fields[0].stringValue
    configuration.arguments = fields[1].stringValue.components(separatedBy: "\n").filter {
      !$0.isEmpty
    }
    configuration.workingDirectory = fields[2].stringValue
    configuration.environment = Dictionary(
      fields[3].stringValue.components(separatedBy: "\n").compactMap { value -> (String, String)? in
        guard let index = value.firstIndex(of: "=") else { return nil }
        return (String(value[..<index]), String(value[value.index(after: index)...]))
      }, uniquingKeysWith: { _, new in new })
    configuration.python = fields[4].stringValue
    configuration.debugProgram = fields[5].stringValue
    if let root {
      let config = configuration
      Task {
        do {
          try await Task.detached {
            let folder = root.appendingPathComponent(".tcode")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(
              to: folder.appendingPathComponent("run.json"), options: .atomic)
          }.value
        } catch { report(error) }
      }
    }
  }
  func gitCommand(_ action: String) {
    guard let root else { return }
    let selected = selectedURL
    let message =
      action == "commit"
      ? input(
        "Commit staged changes",
        detail: "Only staged files are committed. Conflicts must be resolved first.") : nil
    if action == "commit" && (message == nil || message!.isEmpty) { return }
    Task {
      do {
        switch action {
        case "gitRefresh":
          let branch = try await Git.run(root, ["branch", "--show-current"])
          let entries = try await Git.status(root)
          status.stringValue =
            "Git: \(branch.trimmingCharacters(in:.whitespacesAndNewlines)) · \(entries.count) changed files"
          choose(
            "Git Status — " + branch.trimmingCharacters(in: .whitespacesAndNewlines),
            items: entries.map { "\($0.status)  \($0.path)" }
          ) { [weak self] index in self?.open(root.appendingPathComponent(entries[index].path)) }
        case "stage", "unstage":
          let entries = try await Git.status(root)
          if let selected,
            entries.contains(where: {
              root.appendingPathComponent($0.path).standardizedFileURL
                == selected.standardizedFileURL
            })
          {
            _ = try await Git.run(
              root,
              action == "stage"
                ? ["add", "--", selected.path] : ["restore", "--staged", "--", selected.path])
            status.stringValue = action.capitalized + ": " + selected.lastPathComponent
          } else {
            choose(
              action == "stage" ? "Stage File" : "Unstage File",
              items: entries.map { "\($0.status) \($0.path)" }
            ) { [weak self] index in
              Task {
                do {
                  _ = try await Git.run(
                    root,
                    action == "stage"
                      ? ["add", "--", entries[index].path]
                      : ["restore", "--staged", "--", entries[index].path])
                  self?.status.stringValue = action.capitalized + ": " + entries[index].path
                } catch { self?.report(error) }
              }
            }
          }
        case "diff":
          let suffix = selected.map { ["--", $0.path] } ?? []
          let unstaged = try await Git.run(root, ["diff", "--no-ext-diff"] + suffix)
          let staged = try await Git.run(root, ["diff", "--cached", "--no-ext-diff"] + suffix)
          showText("Git Diff", text: "UNSTAGED\n" + unstaged + "\nSTAGED\n" + staged)
        case "commit":
          let entries = try await Git.status(root)
          guard
            !entries.contains(where: {
              $0.status.contains("U") || $0.status == "AA" || $0.status == "DD"
            })
          else { throw TCodeError.message("Resolve unmerged files before committing.") }
          let result = try await Git.run(root, ["commit", "-m", message!])
          appendOutput(result)
          showBottom(2)
        case "history":
          showText(
            "Git History",
            text: try await Git.run(
              root, ["log", "-40", "--date=short", "--pretty=format:%h  %ad  %an%n%s%n"]))
        case "branch":
          guard try await Git.status(root).isEmpty, !documents.contains(where: \.modified) else {
            throw TCodeError.message(
              "Save buffers and commit or stash changes before switching branches.")
          }
          let branches = try await Git.run(
            root, ["for-each-ref", "--format=%(refname:short)", "refs/heads/"]
          ).split(separator: "\n").map(String.init)
          choose("Switch Branch", items: branches) { [weak self] i in
            Task {
              do {
                _ = try await Git.run(root, ["switch", branches[i]])
                if let self {
                  for doc in self.documents where !doc.modified { try? await doc.reload() }
                  self.activated()
                }
              } catch { self?.report(error) }
            }
          }
        default: break
        }
      } catch { report(error) }
    }
  }
  func startDebugging() {
    guard let root, let doc = active else { return }
    if doc.modified {
      status.stringValue = "Save the file before debugging"
      return
    }
    guard let debug = recognizeLanguage(doc)?.pack.debugger else {
      status.stringValue = "This language pack does not configure a debugger."
      return
    }
    let program: String
    if !configuration.debugProgram.isEmpty {
      program =
        configuration.debugProgram.hasPrefix("/")
        ? configuration.debugProgram : root.appendingPathComponent(configuration.debugProgram).path
    } else if case .string(let template) = debug.launch["program"] {
      do {
        program = try LanguageCommand.expand(
          template, context: LanguageRuntime.context(root: root, file: doc.url))
      } catch {
        report(error)
        return
      }
    } else {
      editConfiguration()
      return
    }
    guard FileManager.default.fileExists(atPath: program) else {
      report(
        TCodeError.message(
          "Debug program is missing: \(program). Build the target, then update Run Configuration."))
      return
    }
    let context = LanguageRuntime.context(
      root: root, file: doc.url, python: configuration.python.isEmpty ? nil : configuration.python,
      program: program)
    let adapterCommand: LanguageCommand
    let launch: [String: Any]
    do {
      adapterCommand = try debug.command.resolved(context)
      launch = try debug.launch.mapValues { try $0.expanding(context).foundation }
    } catch {
      report(error)
      return
    }
    guard let adapter = ToolLocator.find(adapterCommand.executable, root: root) else {
      report(
        TCodeError.message(
          "Debug adapter \(adapterCommand.executable) is missing. Open Settings → Language Support."
        ))
      return
    }
    debugSession?.stop()
    let session = DebugSession()
    debugSession = session
    debugOutput.string = ""
    session.output = { [weak self] text in self?.appendOutput(text, debug: true) }
    session.location = { [weak self] url, position in self?.open(url, position: position) }
    session.state = { [weak self] state in self?.status.stringValue = state }
    let breakpoints = self.breakpoints.mapValues { Array($0) }
    showBottom(3)
    let directory =
      configuration.workingDirectory.isEmpty
      ? root
      : URL(fileURLWithPath: configuration.workingDirectory, relativeTo: root).standardizedFileURL
    Task {
      do {
        try await session.start(
          adapter: adapter, arguments: adapterCommand.arguments, program: program,
          root: directory, breakpoints: breakpoints,
          programArguments: configuration.arguments, environment: configuration.environment,
          adapterID: debug.adapterID, launchOptions: launch)
      } catch {
        report(error)
        session.stop()
      }
    }
  }
  func inspectVariables(reference: Int? = nil) {
    guard let session = debugSession, session.stopped else {
      status.stringValue = "Pause the debugger to inspect variables"
      return
    }
    Task {
      do {
        let values = try await session.variables(reference: reference)
        choose("Variables", items: values.map { "\($0["name"] ?? "") = \($0["value"] ?? "")" }) {
          [weak self] index in
          if let ref = values[index]["variablesReference"] as? Int, ref > 0 {
            self?.inspectVariables(reference: ref)
          } else {
            self?.showText("Variable", text: "\(values[index])")
          }
        }
      } catch { report(error) }
    }
  }
  func persistWatches() {
    if let root { UserDefaults.standard.set(watchExpressions, forKey: "watches." + root.path) }
  }
  func addWatch() {
    guard let expression = input("Add watch expression"), !expression.isEmpty else { return }
    if !watchExpressions.contains(expression) {
      watchExpressions.append(expression)
      persistWatches()
    }
    inspectWatches()
  }
  func inspectWatches() {
    guard let session = debugSession, session.stopped else {
      status.stringValue = "Watches saved. Pause the debugger to evaluate them."
      return
    }
    Task {
      var values: [String] = []
      for expression in watchExpressions {
        do { values.append("\(expression) = \(try await session.evaluate(expression))") } catch {
          values.append("\(expression): \(error.localizedDescription)")
        }
      }
      choose("Watches", items: values) { [weak self] i in self?.showText("Watch", text: values[i]) }
    }
  }
  func showTestResults(_ entries: [TestEntry], root: URL) async {
    guard !entries.isEmpty else {
      status.stringValue += " · See Build Output for runner results"
      return
    }
    let exclusions = EditorConfiguration.load(root: root, file: nil).exclusions
    let locations = await Task.detached { () -> [(URL, Int)?] in
      let files = (try? FileIO.indexedFiles(root, excluding: exclusions)) ?? []
      return entries.map { entry in
        if let path = entry.path {
          let url = root.appendingPathComponent(path)
          let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
          let lines = text.components(separatedBy: .newlines)
          return (
            url, lines.firstIndex(where: { $0.contains("def " + (entry.symbol ?? "") + "(") }) ?? 0
          )
        }
        if let symbol = entry.symbol {
          for file in files where ["swift", "rs"].contains(file.pathExtension) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let line = text.components(separatedBy: .newlines).firstIndex(where: {
              $0.contains("func " + symbol + "(")
                || $0.contains("func " + symbol.replacingOccurrences(of: "()", with: "") + "(")
                || $0.contains("fn " + symbol + "(")
            }) {
              return (file, line)
            }
          }
        }
        if let file = files.first(where: { $0.lastPathComponent == "CMakeLists.txt" }),
          let text = try? String(contentsOf: file, encoding: .utf8),
          let line = text.components(separatedBy: .newlines).firstIndex(where: {
            $0.contains("add_test") && $0.contains(entry.name)
          })
        {
          return (file, line)
        }
        return nil
      }
    }.value
    showNavigator(title: "Tests · \(entries.count)", rows: entries.map(\.label)) { [weak self] i in
      if let location = locations[i] {
        self?.open(location.0, position: Position(line: location.1, character: 0))
      } else {
        self?.showBottom(2)
        self?.status.stringValue = "\(entries[i].label) · See Build Output"
      }
    }
  }
}
