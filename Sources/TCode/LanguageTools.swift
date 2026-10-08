import AppKit
import TCodeCore

struct LanguagePack: Codable {
  let interfaceVersion: Int
  let id: String
  let name: String
  let extensions: [String]
  let server: String
  let serverArguments: [String]
  let formatter: String
  let adapter: String
  static func discover() -> [LanguagePack] {
    guard let folder = Bundle.module.url(forResource: "Resources", withExtension: nil) else {
      return []
    }
    return
      ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
      ?? []).filter { $0.pathExtension == "json" }.compactMap {
        try? JSONDecoder().decode(Self.self, from: Data(contentsOf: $0))
      }.filter { $0.interfaceVersion == 1 }
  }
  var enabled: Bool { !UserDefaults.standard.bool(forKey: "disabled." + id) }
}

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
    guard let path = ToolLocator.find(pack.server, root: root) else {
      throw TCodeError.message(
        "\(pack.name): \(pack.server) is missing. Configure it in Language Tools settings.")
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
        guard let self, let edit = (message["params"] as? [String: Any])?["edit"] as? [String: Any],
          let apply = await self.applyEdit
        else { return ["applied": false] }
        return ["applied": try await apply(edit, self.encoding)]
      })
    var arguments = pack.serverArguments
    let buildDatabase = root.appendingPathComponent("build/compile_commands.json")
    if pack.id == "cpp", FileManager.default.fileExists(atPath: buildDatabase.path) {
      arguments.append("--compile-commands-dir=" + buildDatabase.deletingLastPathComponent().path)
    }
    try await connection.start(path: path, arguments: arguments, directory: root)
    let result = try await connection.request(
      "initialize",
      params: [
        "processId": ProcessInfo.processInfo.processIdentifier, "rootUri": root.absoluteString,
        "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
        "clientInfo": ["name": "tCode", "version": "0.1"],
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
        ], "initializationOptions": [:],
      ], timeout: 30)
    capabilities = (result["result"] as? [String: Any])?["capabilities"] as? [String: Any] ?? [:]
    encoding = capabilities["positionEncoding"] as? String ?? "utf-16"
    guard ["utf-16", "utf-8", "utf-32"].contains(encoding) else {
      throw TCodeError.message("Unsupported server position encoding: \(encoding)")
    }
    try await connection.notify("initialized")
    ready = true
    log?("\(pack.name) ready (\(encoding))\n")
    if pack.id == "python", let pythonInterpreter {
      try await connection.notify(
        "workspace/didChangeConfiguration",
        params: ["settings": ["pylsp": ["plugins": ["jedi": ["environment": pythonInterpreter]]]]])
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
          "uri": url.absoluteString, "languageId": pack.id, "version": document.version,
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
    guard pack.id == "python", let path = ToolLocator.find("ruff"), let url = document.url else {
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
