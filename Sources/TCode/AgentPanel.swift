import AppKit
import TCodeCore

struct AgentDisplay {
  enum Role: String { case user, assistant, tool, error }
  let role: Role
  var text: String
  let toolName: String?
}

struct AgentConversation {
  var title: String
  var messages: [[String: Any]]
  var display: [AgentDisplay]
}

/// A native conversation surface for the coding agent. It only runs when the user sends a
/// message; no background polling, no hidden requests.
@MainActor final class AgentPanel: NSViewController, NSTextViewDelegate {
  weak var workspace: WorkspaceWindow?
  let transcript = NSTextView()
  let input = NSTextView()
  let inputScroll = NSScrollView()
  let sendButton = IndustrialButton("Send", kind: .primary)
  let stopButton = IndustrialButton("Stop", kind: .secondary)
  let newChatButton = IconButton(symbol: "square.and.pencil", label: "New conversation")
  let settingsButton = IconButton(symbol: "gearshape", label: "Agent settings")
  let conversationPopup = IndustrialPopUp()
  let statusLabel = NSTextField(labelWithString: "Ready")
  let contextLabel = NSTextField(labelWithString: "")
  let placeholder = NSTextField(labelWithString: "Ask the agent…")
  private let inputBox = NSView()
  var conversations: [AgentConversation] = []
  var activeConversation = 0
  var messages: [[String: Any]] {
    get {
      conversations.indices.contains(activeConversation)
        ? conversations[activeConversation].messages : []
    }
    set {
      guard conversations.indices.contains(activeConversation) else { return }
      conversations[activeConversation].messages = newValue
    }
  }
  var streamTask: Task<Void, Never>?
  var isRunning = false
  var assistantStarted = false

  init(workspace: WorkspaceWindow) {
    self.workspace = workspace
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = Style.chrome.cgColor
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 0
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
    root.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
    ])

    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
    let title = NSTextField(labelWithString: "Agent")
    title.font = Style.projectTitle
    statusLabel.font = Style.monoSmall
    statusLabel.textColor = .tertiaryLabelColor
    newChatButton.onClick = { [weak self] in self?.newChat() }
    settingsButton.onClick = { [weak self] in self?.openSettings() }
    conversationPopup.onSelect = { [weak self] index in self?.switchConversation(index) }
    conversationPopup.toolTip = "Conversations"
    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    header.addArrangedSubview(title)
    header.addArrangedSubview(conversationPopup)
    header.addArrangedSubview(statusLabel)
    header.addArrangedSubview(spacer)
    header.addArrangedSubview(newChatButton)
    header.addArrangedSubview(settingsButton)
    stack.addArrangedSubview(header)
    header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    header.heightAnchor.constraint(equalToConstant: 36).isActive = true
    let headerRule = HairlineView(.horizontal)
    stack.addArrangedSubview(headerRule)
    headerRule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    headerRule.heightAnchor.constraint(equalToConstant: 1).isActive = true

    contextLabel.font = Style.monoSmall
    contextLabel.textColor = .tertiaryLabelColor
    contextLabel.lineBreakMode = .byTruncatingMiddle
    contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let contextRow = NSView()
    contextLabel.translatesAutoresizingMaskIntoConstraints = false
    contextRow.addSubview(contextLabel)
    NSLayoutConstraint.activate([
      contextLabel.leadingAnchor.constraint(equalTo: contextRow.leadingAnchor, constant: 12),
      contextLabel.trailingAnchor.constraint(equalTo: contextRow.trailingAnchor, constant: -12),
      contextLabel.centerYAnchor.constraint(equalTo: contextRow.centerYAnchor),
      contextRow.heightAnchor.constraint(equalToConstant: 22),
    ])
    stack.addArrangedSubview(contextRow)
    contextRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    transcript.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
    transcript.isEditable = false
    transcript.isRichText = true
    transcript.font = Style.body
    transcript.textColor = .labelColor
    transcript.backgroundColor = Style.editorBackground
    transcript.textContainerInset = NSSize(width: 14, height: 10)
    transcript.isVerticallyResizable = true
    transcript.isHorizontallyResizable = false
    transcript.textContainer?.widthTracksTextView = true
    transcript.autoresizingMask = [.width]
    transcript.minSize = .zero
    transcript.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    transcript.setAccessibilityLabel("Agent conversation")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = Style.editorBackground
    scroll.documentView = transcript
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    inputBox.wantsLayer = true
    inputBox.layer?.backgroundColor = Style.control.cgColor
    inputBox.layer?.cornerRadius = Style.radius
    inputBox.layer?.borderWidth = 1
    inputBox.layer?.borderColor = Style.hairlineStrong.cgColor
    input.frame = NSRect(x: 0, y: 0, width: 300, height: 72)
    input.isEditable = true
    input.isRichText = false
    input.font = Style.body
    input.textColor = .labelColor
    input.backgroundColor = .clear
    input.drawsBackground = false
    input.textContainerInset = NSSize(width: 8, height: 6)
    input.isVerticallyResizable = true
    input.isHorizontallyResizable = false
    input.textContainer?.widthTracksTextView = true
    input.autoresizingMask = [.width]
    input.minSize = .zero
    input.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    input.delegate = self
    input.setAccessibilityLabel("Message the agent")
    inputScroll.documentView = input
    inputScroll.hasVerticalScroller = true
    inputScroll.autohidesScrollers = true
    inputScroll.drawsBackground = false
    inputScroll.borderType = .noBorder
    inputScroll.translatesAutoresizingMaskIntoConstraints = false
    inputBox.addSubview(inputScroll)
    NSLayoutConstraint.activate([
      inputScroll.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 6),
      inputScroll.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -6),
      inputScroll.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: 4),
      inputScroll.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: -4),
    ])
    placeholder.font = Style.body
    placeholder.textColor = .placeholderTextColor
    placeholder.isEditable = false
    placeholder.isSelectable = false
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    inputBox.addSubview(placeholder)
    NSLayoutConstraint.activate([
      placeholder.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 12),
      placeholder.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: 9),
    ])
    stack.addArrangedSubview(inputBox)
    inputBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
    inputBox.heightAnchor.constraint(equalToConstant: 84).isActive = true

    sendButton.onClick = { [weak self] in self?.sendMessage() }
    stopButton.onClick = { [weak self] in self?.stop() }
    stopButton.isHidden = true
    let footerSpacer = NSView()
    footerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    let footer = NSStackView(views: [footerSpacer, stopButton, sendButton])
    footer.orientation = .horizontal
    footer.spacing = 8
    footer.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)
    stack.addArrangedSubview(footer)
    footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    view = root
    refreshContext()
    conversations = [makeConversation()]
    activeConversation = 0
    updateConversationPopup()
    rebuildTranscript()
    updateControls()
  }

  func themeChanged() {
    transcript.backgroundColor = Style.editorBackground
    inputBox.layer?.backgroundColor = Style.control.cgColor
    inputBox.layer?.borderColor = Style.hairlineStrong.cgColor
  }

  func refreshContext() {
    if let path = workspace?.active?.url?.path {
      contextLabel.stringValue = path
      contextLabel.toolTip = path
    } else {
      contextLabel.stringValue = "No file open"
      contextLabel.toolTip = nil
    }
  }

  private func systemMessage() -> [String: Any] {
    var prompt = AgentSettings.load().systemPrompt
    if let root = workspace?.root { prompt += "\n\nWorkspace: \(root.path)" }
    if let file = workspace?.active?.url { prompt += "\nOpen file: \(file.path)" }
    if let editor = workspace?.focusedEditor {
      let range = editor.selectedRange()
      if range.length > 0 {
        let text = (editor.string as NSString).substring(with: range)
        prompt += "\n\nSelected text:\n\(text.prefix(4000))"
      }
    }
    return ["role": "system", "content": prompt]
  }

  private func makeConversation() -> AgentConversation {
    AgentConversation(title: "New chat", messages: [systemMessage()], display: [])
  }

  private func updateConversationPopup() {
    conversationPopup.titles = conversations.map(\.title)
    conversationPopup.selectedIndex = activeConversation
  }

  func switchConversation(_ index: Int) {
    guard conversations.indices.contains(index) else { return }
    cancelStream()
    activeConversation = index
    rebuildTranscript()
    refreshContext()
    updateControls()
  }

  private func cancelStream() {
    streamTask?.cancel()
    streamTask = nil
    isRunning = false
    updateControls()
  }

  private func rebuildTranscript() {
    transcript.string = ""
    guard conversations.indices.contains(activeConversation) else { return }
    if conversations[activeConversation].display.isEmpty {
      appendBody("New conversation.")
      return
    }
    for entry in conversations[activeConversation].display { render(entry) }
  }

  private func appendDisplay(
    _ role: AgentDisplay.Role, _ text: String, toolName: String? = nil
  ) {
    guard conversations.indices.contains(activeConversation) else { return }
    let entry = AgentDisplay(role: role, text: text, toolName: toolName)
    conversations[activeConversation].display.append(entry)
    render(entry)
  }

  private func render(_ entry: AgentDisplay) {
    switch entry.role {
    case .user:
      appendHeader("You", color: .secondaryLabelColor)
      appendBody(entry.text)
    case .assistant:
      appendHeader("Agent", color: .labelColor)
      append(entry.text, attributes: [.font: Style.body, .foregroundColor: NSColor.labelColor])
    case .tool:
      appendHeader("Tool · \(entry.toolName ?? "tool")", color: .secondaryLabelColor)
      append(
        String(entry.text.prefix(4000)) + "\n",
        attributes: [.font: Style.mono, .foregroundColor: NSColor.secondaryLabelColor])
    case .error:
      appendHeader("Error", color: .systemRed)
      append(entry.text + "\n", attributes: [.font: Style.body, .foregroundColor: NSColor.systemRed])
    }
  }

  @objc func sendMessage() {
    let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isRunning else { return }
    guard !AgentSettings.apiKey.isEmpty else {
      appendError("Add an API key in Settings → Agent.")
      return
    }
    input.string = ""
    updatePlaceholder()
    if conversations.indices.contains(activeConversation),
      conversations[activeConversation].title == "New chat"
    {
      conversations[activeConversation].title = String(text.prefix(36))
      updateConversationPopup()
    }
    appendUser(text)
    messages.append(["role": "user", "content": text])
    runAgent()
  }

  private func runAgent() {
    let configuration = AgentSettings.load()
    let key = AgentSettings.apiKey
    guard !key.isEmpty else {
      appendError("Add an API key in Settings → Agent.")
      return
    }
    isRunning = true
    updateControls()
    streamTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.isRunning = false
        self.updateControls()
      }
      var iterations = 0
      while iterations < configuration.maxIterations {
        if Task.isCancelled { return }
        let client = AgentClient(configuration: configuration, apiKey: key)
        var assistantText = ""
        var toolCalls: [AgentToolCall] = []
        self.assistantStarted = false
        do {
          for try await event in client.stream(
            messages: self.messages,
            tools: configuration.allowTools ? AgentTools.definitions : nil)
          {
            switch event {
            case .delta(let delta):
              assistantText += delta
              self.appendAssistantDelta(delta)
            case .toolCalls(let calls):
              toolCalls = calls
            case .done:
              break
            }
          }
        } catch is CancellationError {
          return
        } catch {
          self.appendError(error.localizedDescription)
          return
        }
        if !assistantText.isEmpty {
          self.messages.append(["role": "assistant", "content": assistantText])
          self.finishAssistant()
        }
        guard !toolCalls.isEmpty else { return }
        let payload: [[String: Any]] = toolCalls.map { call in
          [
            "id": call.id, "type": "function",
            "function": ["name": call.function.name, "arguments": call.function.arguments],
          ]
        }
        self.messages.append(["role": "assistant", "content": NSNull(), "tool_calls": payload])
        for call in toolCalls {
          if Task.isCancelled { return }
          let result = await self.execute(call)
          self.messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
          self.appendToolResult(call, result)
        }
        iterations += 1
      }
      self.appendError("Stopped after \(configuration.maxIterations) tool steps.")
    }
  }

  @objc func stop() {
    guard isRunning || streamTask != nil else { return }
    cancelStream()
    appendError("Stopped.")
  }

  @objc func newChat() {
    cancelStream()
    var conversation = makeConversation()
    if !conversations.isEmpty { conversation.title = "New chat \(conversations.count + 1)" }
    conversations.append(conversation)
    activeConversation = conversations.count - 1
    updateConversationPopup()
    rebuildTranscript()
    refreshContext()
    view.window?.makeFirstResponder(input)
  }

  @objc func openSettings() {
    (NSApp.delegate as? AppDelegate)?.showSettings()
  }

  private func updateControls() {
    sendButton.isEnabled = !isRunning
    stopButton.isHidden = !isRunning
    statusLabel.stringValue = isRunning ? "Working…" : "Ready"
  }

  private func updatePlaceholder() {
    // Focus alone should not blank the box: the hint stays until there is text to show instead.
    placeholder.isHidden = !input.string.isEmpty
  }

  func textDidChange(_ notification: Notification) {
    updatePlaceholder()
  }

  func textDidBeginEditing(_ notification: Notification) {
    updatePlaceholder()
    inputBox.layer?.borderColor = Style.accent.cgColor
  }

  func textDidEndEditing(_ notification: Notification) {
    updatePlaceholder()
    inputBox.layer?.borderColor = Style.hairlineStrong.cgColor
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      if NSEvent.modifierFlags.contains(.shift) {
        textView.insertText("\n", replacementRange: textView.selectedRange())
      } else {
        sendMessage()
      }
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      stop()
      return true
    }
    return false
  }

  private func append(_ text: String, attributes: [NSAttributedString.Key: Any]) {
    transcript.textStorage?.append(NSAttributedString(string: text, attributes: attributes))
    transcript.scrollToEndOfDocument(nil)
  }

  private func appendHeader(_ title: String, color: NSColor) {
    let prefix = (transcript.textStorage?.length ?? 0) == 0 ? "" : "\n"
    append(
      prefix + title.uppercased() + "\n",
      attributes: [.font: Style.sectionTitle, .foregroundColor: color, .kern: 0.9])
  }

  private func appendBody(_ text: String) {
    append(
      text + "\n",
      attributes: [.font: Style.body, .foregroundColor: NSColor.labelColor])
  }

  private func appendUser(_ text: String) {
    appendDisplay(.user, text)
  }

  private func appendAssistantDelta(_ text: String) {
    if conversations.indices.contains(activeConversation) {
      if let last = conversations[activeConversation].display.last,
        last.role == .assistant, last.toolName == nil
      {
        conversations[activeConversation].display[
          conversations[activeConversation].display.count - 1
        ].text += text
      } else {
        conversations[activeConversation].display.append(
          AgentDisplay(role: .assistant, text: text, toolName: nil))
      }
    }
    if !assistantStarted {
      appendHeader("Agent", color: .labelColor)
      assistantStarted = true
    }
    append(text, attributes: [.font: Style.body, .foregroundColor: NSColor.labelColor])
  }

  private func finishAssistant() {
    append("\n", attributes: [.font: Style.body, .foregroundColor: NSColor.labelColor])
    if conversations.indices.contains(activeConversation),
      let last = conversations[activeConversation].display.last,
      last.role == .assistant
    {
      conversations[activeConversation].display[
        conversations[activeConversation].display.count - 1
      ].text += "\n"
    }
    assistantStarted = false
  }

  private func appendToolResult(_ call: AgentToolCall, _ result: String) {
    appendDisplay(.tool, result, toolName: call.function.name)
  }

  private func appendError(_ message: String) {
    appendDisplay(.error, message)
  }

  private func execute(_ call: AgentToolCall) async -> String {
    guard let data = call.function.arguments.data(using: .utf8),
      let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "Invalid tool arguments." }
    switch call.function.name {
    case "read_file":
      guard let path = arguments["path"] as? String, let url = resolve(path) else {
        return "Path is outside the workspace."
      }
      do {
        let text = try await Background.run { () -> String in
          try TextFile(data: Data(contentsOf: url)).text
        }
        return String(text.prefix(200_000))
      } catch {
        return "Could not read \(path): \(error.localizedDescription)"
      }
    case "list_files":
      guard workspace?.root != nil else { return "No workspace is open." }
      let path = arguments["path"] as? String ?? "."
      guard let url = resolve(path) else { return "Path is outside the workspace." }
      do {
        let entries = try await Background.run { try FileIO.children(url) }
        return entries.prefix(200).map {
          ($0.directory ? "dir  " : "file ") + $0.url.lastPathComponent
        }.joined(separator: "\n")
      } catch {
        return error.localizedDescription
      }
    case "search_workspace":
      guard let root = workspace?.root, let pattern = arguments["pattern"] as? String else {
        return "No workspace is open."
      }
      do {
        let hits = try await Background.run {
          try WorkspaceSearch.find(root: root, pattern: pattern, regex: true, limit: 50)
        }
        return hits.map {
          "\($0.url.path.replacingOccurrences(of: root.path + "/", with: "")):\($0.line + 1)  \($0.preview)"
        }.joined(separator: "\n")
      } catch {
        return error.localizedDescription
      }
    case "write_file":
      guard let path = arguments["path"] as? String,
        let content = arguments["content"] as? String,
        let url = resolve(path)
      else { return "Path is outside the workspace." }
      let canonical = url.resolvingSymlinksInPath().standardizedFileURL
      if let doc = DocumentPool.shared.documents.first(where: { $0.canonicalURL == canonical }),
        doc.modified
      {
        return "Save or close \(doc.title) before the agent writes to it."
      }
      guard confirm("Write file?", detail: "\(path)\n\n\(content.prefix(1600))") else {
        return "The user declined the write."
      }
      do {
        let existing = try? Data(contentsOf: url)
        try FileIO.save(Data(content.utf8), to: url, expected: existing)
        if let doc = DocumentPool.shared.documents.first(where: {
          $0.canonicalURL == url.resolvingSymlinksInPath().standardizedFileURL
        }) {
          try? await doc.reload()
        }
        return "Wrote \(path)."
      } catch {
        return error.localizedDescription
      }
    case "run_command":
      guard let root = workspace?.root, let command = arguments["command"] as? String else {
        return "No workspace is open."
      }
      guard confirm("Run command?", detail: command) else {
        return "The user declined the command."
      }
      do {
        let result = try await RunningProcess().run(
          executable: "/bin/zsh", arguments: ["-lc", command], directory: root)
        return "Exit \(result.status)\n\(result.output.prefix(20_000))"
      } catch {
        return error.localizedDescription
      }
    default:
      return "Unknown tool \(call.function.name)."
    }
  }

  private func resolve(_ path: String) -> URL? {
    guard let root = workspace?.root else { return nil }
    let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
    let url = URL(fileURLWithPath: path, relativeTo: root)
      .resolvingSymlinksInPath().standardizedFileURL
    guard url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") else { return nil }
    return url
  }

  private func confirm(_ title: String, detail: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = String(detail.prefix(4000))
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
