import AppKit
import TCodeCore

@MainActor final class LanguageSession {
  let pack: LanguagePack
  let connection = ProtocolConnection(kind: .lsp)
  var capabilities: [String: Any] = [:]
  var encoding = "utf-16"
  var ready = false
  var documents = Set<UUID>()
  var changeTasks: [UUID: Task<Void, Never>] = [:]
  var lintTasks: [UUID: Task<Void, Never>] = [:]
  var diagnostics: ((String, [[String: Any]]) -> Void)?
  var serverDiagnostics: [String: [[String: Any]]] = [:]
  var ruffDiagnostics: [String: [[String: Any]]] = [:]
  func publishDiagnostics(_ uri: String) {
    diagnostics?(uri, (serverDiagnostics[uri] ?? []) + (ruffDiagnostics[uri] ?? []))
  }
  var log: ((String) -> Void)?
  var applyEdit: (([String: Any], String) async throws -> Bool)?
  init(pack: LanguagePack) { self.pack = pack }
  func start(root: URL, pythonInterpreter: String? = nil) async throws {
    guard let server = pack.languageServer else {
      throw TCodeError.message("\(pack.name) does not configure a language server.")
    }
    let context = LanguageRuntime.context(
      root: root, file: root.appendingPathComponent("untitled"), python: pythonInterpreter)
    let command = try server.command.resolved(context)
    guard let path = ToolLocator.find(command.executable, root: root) else {
      throw TCodeError.message(
        "\(pack.name): \(pack.server) is missing. Configure it in Settings → Language Support.")
    }
    await connection.handlers(
      event: { [weak self] message in
        await MainActor.run {
          guard let self else { return }
          if message["method"] as? String == "textDocument/publishDiagnostics",
            let p = message["params"] as? [String: Any], let uri = p["uri"] as? String,
            let list = p["diagnostics"] as? [[String: Any]]
          {
            if let version = p["version"] as? Int,
              let doc = DocumentPool.shared.documents.first(where: { $0.url?.absoluteString == uri }
              ), version != doc.version
            {
              return
            }
            self.serverDiagnostics[uri] = list
            self.publishDiagnostics(uri)
          }
        }
      }, log: { [weak self] text in await MainActor.run { self?.log?(text) } },
      serverRequest: { [weak self] message in
        guard let self else { return NSNull() }
        let method = message["method"] as? String
        if method == "workspace/workspaceFolders" {
          return [["uri": root.absoluteString, "name": root.lastPathComponent]]
        }
        if method == "workspace/configuration" {
          let values = (try server.settings?.expanding(context).foundation) as? [String: Any] ?? [:]
          let initial =
            (try server.initializationOptions?.expanding(context).foundation) as? [String: Any]
            ?? [:]
          let items = (message["params"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
          return items.map { item -> Any in
            guard let section = item["section"] as? String, !section.isEmpty else { return values }
            if values.isEmpty, section == self.pack.server || section == self.pack.id {
              return initial
            }
            var selected: Any = values
            for piece in section.split(separator: ".") {
              selected = (selected as? [String: Any])?[String(piece)] ?? NSNull()
            }
            return selected
          }
        }
        guard let edit = (message["params"] as? [String: Any])?["edit"] as? [String: Any],
          let apply = await self.applyEdit
        else { return ["applied": false] }
        return ["applied": try await apply(edit, self.encoding)]
      })
    try await connection.start(
      path: path, arguments: command.arguments,
      directory: command.workingDirectory.map {
        URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
      } ?? root,
      environment: command.environment)
    let result = try await connection.request(
      "initialize",
      params: [
        "processId": ProcessInfo.processInfo.processIdentifier, "rootUri": root.absoluteString,
        "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
        "clientInfo": ["name": "tCode", "version": "0.2"],
        "capabilities": [
          "general": ["positionEncodings": ["utf-16", "utf-8"]],
          "textDocument": [
            "synchronization": ["didSave": true],
            "completion": ["completionItem": ["snippetSupport": false]],
            "publishDiagnostics": ["versionSupport": true],
          ],
          "workspace": [
            "applyEdit": true, "workspaceEdit": ["documentChanges": true], "configuration": true,
          ],
        ],
        "initializationOptions": try server.initializationOptions?.expanding(context).foundation
          ?? [:],
      ], timeout: 30)
    capabilities = (result["result"] as? [String: Any])?["capabilities"] as? [String: Any] ?? [:]
    encoding = capabilities["positionEncoding"] as? String ?? "utf-16"
    guard ["utf-16", "utf-8", "utf-32"].contains(encoding) else {
      throw TCodeError.message("Unsupported server position encoding: \(encoding)")
    }
    try await connection.notify("initialized")
    ready = true
    log?("\(pack.name) ready (\(encoding))\n")
    if let settings = server.settings {
      try await connection.notify(
        "workspace/didChangeConfiguration",
        params: ["settings": try settings.expanding(context).foundation])
    }
  }
  func open(_ document: CodeDocument) async throws {
    guard ready, let url = document.url, !documents.contains(document.id), !document.large else {
      return
    }
    try await connection.notify(
      "textDocument/didOpen",
      params: [
        "textDocument": [
          "uri": url.absoluteString, "languageId": document.languageID ?? pack.id,
          "version": document.version,
          "text": document.text,
        ]
      ])
    documents.insert(document.id)
    document.languageSession = self
    lint(document)
  }
  func changed(_ document: CodeDocument) {
    changeTasks[document.id]?.cancel()
    changeTasks[document.id] = Task { [weak self, weak document] in
      try? await Task.sleep(for: .milliseconds(180))
      guard let self, let document, !Task.isCancelled else { return }
      await self.synchronize(document)
      self.lint(document)
    }
  }
  func lint(_ document: CodeDocument) {
    guard pack.diagnosticAdapter == "ruff", let path = ToolLocator.find("ruff"),
      let url = document.url
    else {
      return
    }
    lintTasks[document.id]?.cancel()
    let version = document.version
    let text = document.text
    let negotiatedEncoding = encoding
    lintTasks[document.id] = Task { [weak self, weak document] in
      do {
        let result = try await RunningProcess().run(
          executable: path,
          arguments: ["check", "--output-format", "json", "--stdin-filename", url.path, "-"],
          directory: url.deletingLastPathComponent(), input: Data(text.utf8))
        guard let self, let document, document.version == version, !Task.isCancelled else { return }
        guard
          let values = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
            as? [[String: Any]]
        else { return }
        let diagnostics: [[String: Any]] = values.map { item in
          let start = item["location"] as? [String: Int] ?? [:]
          let end = item["end_location"] as? [String: Int] ?? [:]
          func mapped(_ point: [String: Int]) -> [String: Any] {
            let scalarPosition = Position(
              line: max(0, (point["row"] ?? 1) - 1), character: max(0, (point["column"] ?? 1) - 1))
            let offset = PositionMap.offset(in: text, position: scalarPosition, encoding: "utf-32")
            return PositionMap.position(in: text, utf16Offset: offset, encoding: negotiatedEncoding)
              .json
          }
          return [
            "range": ["start": mapped(start), "end": mapped(end)], "severity": 2, "source": "Ruff",
            "message": "\(item["code"] ?? "") \(item["message"] ?? "")",
          ]
        }
        self.ruffDiagnostics[url.absoluteString] = diagnostics
        self.publishDiagnostics(url.absoluteString)
      } catch is CancellationError {} catch { self?.log?("Ruff: \(error.localizedDescription)\n") }
    }
  }
  func synchronize(_ document: CodeDocument) async {
    guard let url = document.url, documents.contains(document.id) else { return }
    try? await connection.notify(
      "textDocument/didChange",
      params: [
        "textDocument": ["uri": url.absoluteString, "version": document.version],
        "contentChanges": [["text": document.text]],
      ])
  }
  func close(_ document: CodeDocument, url: URL?) {
    changeTasks.removeValue(forKey: document.id)?.cancel()
    lintTasks.removeValue(forKey: document.id)?.cancel()
    documents.remove(document.id)
    if let url {
      serverDiagnostics.removeValue(forKey: url.absoluteString)
      ruffDiagnostics.removeValue(forKey: url.absoluteString)
      publishDiagnostics(url.absoluteString)
      Task {
        try? await connection.notify(
          "textDocument/didClose", params: ["textDocument": ["uri": url.absoluteString]])
      }
    }
  }
  func supports(_ method: String) -> Bool {
    let names = [
      "completion": "completionProvider", "hover": "hoverProvider",
      "signatureHelp": "signatureHelpProvider", "definition": "definitionProvider",
      "references": "referencesProvider", "documentSymbol": "documentSymbolProvider",
      "rename": "renameProvider", "codeAction": "codeActionProvider",
    ]
    guard let key = names[method], let value = capabilities[key] else { return false }
    return (value as? Bool) != false
  }
  func request(_ feature: String, document: CodeDocument, offset: Int, extras: [String: Any] = [:])
    async throws -> Any
  {
    guard supports(feature), let url = document.url else {
      throw TCodeError.message(
        "\(pack.name) does not advertise \(feature) support for this document.")
    }
    changeTasks.removeValue(forKey: document.id)?.cancel()
    await synchronize(document)
    let version = document.version
    var params: [String: Any] = [
      "textDocument": ["uri": url.absoluteString],
      "position": PositionMap.position(in: document.text, utf16Offset: offset, encoding: encoding)
        .json,
    ]
    params.merge(extras) { _, new in new }
    let response = try await connection.request("textDocument/" + feature, params: params)
    guard document.version == version else {
      throw TCodeError.message("The document changed while the tool was working. Try again.")
    }
    return response["result"] ?? NSNull()
  }
  func stop() { Task { await shutdown() } }
  func shutdown() async {
    ready = false
    for task in changeTasks.values { task.cancel() }
    for task in lintTasks.values { task.cancel() }
    await connection.stop()
  }
}
