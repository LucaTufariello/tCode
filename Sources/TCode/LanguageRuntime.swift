import AppKit
import TCodeCore

extension LanguagePack {
  static func bundled() -> [LanguagePack] {
    guard let folder = Bundle.module.url(forResource: "Resources", withExtension: nil) else {
      return []
    }
    return
      ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
      ?? [])
      .filter { $0.pathExtension == "json" }
      .compactMap { try? LanguagePackRegistry.decode(Data(contentsOf: $0)) }
      .sorted { $0.id < $1.id }
  }
  static func discover() -> [LanguagePack] { LanguagePackRegistry(bundledPacks: bundled()).packs }
}

enum LanguageRuntime {
  static func context(root: URL?, file: URL?, python: String? = nil, program: String? = nil)
    -> [String: String]
  {
    let directory =
      root ?? file?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
    let interpreter = python ?? ToolLocator.find("python3", root: root) ?? "python3"
    return [
      "workspace": directory.path,
      "file": file?.path ?? directory.appendingPathComponent("Untitled").path,
      "fileName": file?.lastPathComponent ?? "Untitled",
      "fileStem": file?.deletingPathExtension().lastPathComponent ?? "Untitled",
      "python": interpreter, "interpreter": interpreter, "program": program ?? file?.path ?? "",
      "buildDir": directory.appendingPathComponent("build").path,
    ]
  }
}

extension WorkspaceWindow {
  var languageRegistry: LanguagePackRegistry { LanguageEnvironment.shared.registry }
  func recognizeLanguage(_ document: CodeDocument) -> LanguageMatch? {
    let candidates = LanguageRecognition.matches(
      packs: packs, url: document.url,
      firstLine: String(document.text.prefix(1024)).components(separatedBy: .newlines).first ?? "",
      override: document.languageOverride)
    guard candidates.count == 1 else { return nil }
    return candidates.first
  }
  func configureLanguage(_ document: CodeDocument) {
    let match = recognizeLanguage(document)
    let old = document.languageID
    let oldPack = document.languagePackID
    document.languageID = match?.association.languageID
    document.languagePackID = match?.pack.id
    document.grammarID = match?.association.grammarID
    document.highlightQuery = match?.association.highlightQuery
    document.languageComment = match?.pack.editor.lineComment
    if old != document.languageID, let service = document.languageSession {
      service.close(document, url: document.url)
      document.languageSession = nil
    }
    for pane in panes where pane.document === document {
      pane.editor.comment = match?.pack.editor.lineComment ?? ""
      if oldPack != document.languagePackID {
        let settings = EditorConfiguration.load(
          root: root, file: document.url, languageDefaults: match?.pack.editor)
        pane.editor.indent =
          settings.useTabs ? "\t" : String(repeating: " ", count: settings.indentSize)
      }
      pane.highlight()
    }
  }
  func selectLanguage() {
    guard let document = active else { return }
    let choices = packs.filter(\.enabled).flatMap { pack in pack.associations.map { (pack, $0) } }
      .sorted { ($0.0.name + $0.1.languageID) < ($1.0.name + $1.1.languageID) }
    choose(
      "Document Language",
      items: ["Automatic", "Plain Text"] + choices.map { "\($0.0.name) — \($0.1.languageID)" }
    ) { [weak self, weak document] index in
      guard let self, let document else { return }
      document.languageOverride =
        index == 0
        ? nil
        : index == 1 ? "text" : choices[index - 2].0.id + ":" + choices[index - 2].1.languageID
      self.configureLanguage(document)
      if self.languageEnabled { self.activateLanguage(document) }
      self.updateStatus()
      self.persist()
    }
  }
  func allowWorkspaceLanguagePacks() {
    guard let root else { return }
    let alert = NSAlert()
    alert.messageText = "Enable workspace language configurations?"
    alert.informativeText =
      "Files in .tcode/languages may change the commands used by language tools, formatting, tasks, and debugging. Review this project's configuration before enabling it. Tools still run only after your command."
    alert.addButton(withTitle: "Enable Configurations")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    UserDefaults.standard.set(true, forKey: "workspaceLanguagePacks." + root.path)
    reloadLanguagePacks()
  }
  func reloadLanguagePacks() {
    LanguageEnvironment.shared.reload()
    toolSettingsChanged()
    let errors = (workspaceRegistry?.issues ?? languageRegistry.issues)
    if !errors.isEmpty {
      showText(
        "Language Configuration Errors",
        text: errors.map { "\($0.source): \($0.message)" }.joined(separator: "\n"))
    }
  }
}
