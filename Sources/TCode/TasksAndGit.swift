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
    let ext = active?.url?.pathExtension ?? ""
    let executable: String
    let arguments: [String]
    let python =
      configuration.python.isEmpty
      ? ToolLocator.find("python3", root: root) ?? "/usr/bin/python3" : configuration.python
    if action == "run" && !configuration.executable.isEmpty {
      executable =
        configuration.executable.hasPrefix("/")
        ? configuration.executable : root.appendingPathComponent(configuration.executable).path
      arguments = configuration.arguments
    } else if ext == "py" {
      executable = python
      arguments =
        action == "run"
        ? [active?.url?.path ?? ""]
        : action == "build"
          ? ["-m", "compileall", "-q", "."]
          : action == "discoverTests"
            ? ["-m", "pytest", "--collect-only", "-q"] : ["-m", "pytest", "-v"]
    } else if FileManager.default.fileExists(
      atPath: root.appendingPathComponent("Package.swift").path)
    {
      executable = ToolLocator.find("swift") ?? "/usr/bin/swift"
      arguments =
        action == "build"
        ? ["build"]
        : action == "run" ? ["run"] : action == "discoverTests" ? ["test", "list"] : ["test"]
    } else if FileManager.default.fileExists(
      atPath: root.appendingPathComponent("CMakeLists.txt").path)
    {
      if action == "run" {
        editConfiguration()
        return
      }
      executable =
        ToolLocator.find(action == "test" || action == "discoverTests" ? "ctest" : "cmake")
        ?? "/opt/homebrew/bin/cmake"
      arguments =
        action == "build"
        ? ["--build", "build"]
        : action == "discoverTests"
          ? ["--test-dir", "build", "-N"] : ["--test-dir", "build", "--output-on-failure"]
    } else {
      editConfiguration()
      return
    }
    let directory =
      configuration.workingDirectory.isEmpty
      ? root
      : URL(fileURLWithPath: configuration.workingDirectory, relativeTo: root).standardizedFileURL
    showBottom(2)
    appendOutput("\n› \(executable) \(arguments.joined(separator:" "))\n")
    let process = RunningProcess()
    taskProcess = process
    taskHandle = Task { [weak self] in
      guard let self else { return }
      let start = Date()
      defer {
        self.taskHandle = nil
        self.taskProcess = nil
      }
      do {
        if action == "build",
          FileManager.default.fileExists(atPath: root.appendingPathComponent("CMakeLists.txt").path)
        {
          let configureProcess = RunningProcess()
          self.taskProcess = configureProcess
          let configure = try await configureProcess.run(
            executable: executable,
            arguments: [
              "-S", ".", "-B", "build", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
              "-DCMAKE_BUILD_TYPE=Debug",
            ], directory: root,
            output: { [weak self] text in Task { @MainActor in self?.appendOutput(text) } })
          if configure.status != 0 {
            throw TCodeError.message("CMake configuration failed. See Build Output.")
          }
        }
        self.taskProcess = process
        try Task.checkCancellation()
        let result = try await process.run(
          executable: executable, arguments: arguments, directory: directory,
          environment: configuration.environment,
          output: { [weak self] text in Task { @MainActor in self?.appendOutput(text) } })
        self.appendOutput(
          "\nExited \(result.status) · \(String(format:"%.2f",Date().timeIntervalSince(start))) s\n"
        )
        self.status.stringValue = "\(action.capitalized) exited \(result.status)"
        if action == "discoverTests" || action == "test" {
          let runner =
            ext == "py"
            ? "pytest"
            : FileManager.default.fileExists(
              atPath: root.appendingPathComponent("Package.swift").path) ? "swift" : "ctest"
          await self.showTestResults(TestReports.parse(result.output, runner: runner), root: root)
        }
      } catch { self.appendOutput("\n\(error.localizedDescription)\n") }
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
      label.font = .systemFont(ofSize: 11)
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
    let python = doc.url?.pathExtension == "py"
    let program =
      configuration.debugProgram.isEmpty
      ? (python ? doc.url?.path : nil)
      : (configuration.debugProgram.hasPrefix("/")
        ? configuration.debugProgram : root.appendingPathComponent(configuration.debugProgram).path)
    guard let program else {
      editConfiguration()
      return
    }
    guard FileManager.default.fileExists(atPath: program) else {
      report(
        TCodeError.message(
          "Debug program is missing: \(program). Build the target, then update Run Configuration if needed."
        ))
      return
    }
    guard
      let adapter = python
        ? (configuration.python.isEmpty
          ? ToolLocator.find("python3", root: root) : configuration.python)
        : ToolLocator.find("lldb-dap", root: root)
    else {
      report(TCodeError.message("Debug adapter is missing. Configure its path in Settings."))
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
          adapter: adapter, arguments: python ? ["-m", "debugpy.adapter"] : [], program: program,
          python: python, root: directory, breakpoints: breakpoints,
          programArguments: configuration.arguments, environment: configuration.environment)
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
          for file in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let line = text.components(separatedBy: .newlines).firstIndex(where: {
              $0.contains("func " + symbol + "(")
                || $0.contains("func " + symbol.replacingOccurrences(of: "()", with: "") + "(")
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
