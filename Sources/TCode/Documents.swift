import AppKit
import TCodeCore

@MainActor final class CodeDocument: NSObject, @preconcurrency NSTextStorageDelegate {
  let id: UUID
  var url: URL?
  let storage: NSTextStorage
  let undo = UndoManager()
  var baseline: Data?
  var encoding = String.Encoding.utf8
  var bom = Data()
  var version = 1
  var isSaving = false
  var listeners: [UUID: () -> Void] = [:]
  func notify() { for listener in listeners.values { listener() } }
  var recoveryTask: Task<Void, Never>?
  var autosaveTask: Task<Void, Never>?
  var languageSession: LanguageSession?
  var languageOverride: String?
  var languageID: String?
  var languagePackID: String?
  var grammarID: String?
  var highlightQuery: String?
  var languageComment: String?
  var syntaxStatus = "Basic highlighting"
  var title: String { url?.lastPathComponent ?? "Untitled" }
  var text: String { storage.string }
  var modified: Bool { (try? encoded()) != baseline && !(baseline == nil && text.isEmpty) }
  var large: Bool { storage.length > 2_000_000 }
  static let recovery = RecoveryStore(
    directory: ProcessInfo.processInfo.environment["TCODE_RECOVERY_PATH"].map {
      URL(fileURLWithPath: $0)
    }
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support/tCode/Recovery"))
  init(url: URL? = nil, file: TextFile? = nil, recovery: RecoveryRecord? = nil) {
    id = recovery?.id ?? UUID()
    self.url = url
    storage = NSTextStorage(string: recovery?.text ?? file?.text ?? "")
    baseline = recovery?.baseline ?? file?.bytes
    encoding = recovery.map { String.Encoding(rawValue: $0.encoding) } ?? file?.encoding ?? .utf8
    bom = recovery?.bom ?? file?.bom ?? Data()
    super.init()
    storage.delegate = self
  }
  func encoded() throws -> Data {
    guard let bytes = text.data(using: encoding, allowLossyConversion: false) else {
      throw TCodeError.message("This text cannot be represented in its original encoding.")
    }
    return bom + bytes
  }
  func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    version += 1
    recoveryTask?.cancel()
    let record = recoveryRecord()
    let dirty = modified
    recoveryTask = Task {
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      if dirty {
        try? await Self.recovery.write(record)
      } else {
        try? await Self.recovery.remove(record.id)
      }
    }
    notify()
    languageSession?.changed(self)
  }
  func recoveryRecord() -> RecoveryRecord {
    RecoveryRecord(
      id: id, path: url?.path, text: text, baseline: baseline, encoding: encoding.rawValue, bom: bom
    )
  }
  func save(to destination: URL, overwrite: Bool = false) async throws {
    isSaving = true
    defer { isSaving = false }
    let data = try encoded()
    let expected = destination == url ? baseline : nil
    try await Task.detached {
      try FileIO.save(data, to: destination, expected: expected, allowOverwrite: overwrite)
    }.value
    let oldURL = url
    url = destination
    baseline = data
    if oldURL != url {
      languageSession?.close(self, url: oldURL)
      languageSession = nil
    }
    recoveryTask?.cancel()
    if modified {
      try await Self.recovery.write(recoveryRecord())
    } else {
      try await Self.recovery.remove(id)
    }
    notify()
  }
  func reload() async throws {
    guard let url else { return }
    let file = try await Task.detached { try TextFile(data: Data(contentsOf: url)) }.value
    if modified {
      var archive = recoveryRecord()
      archive.id = UUID()
      archive.path = nil
      try await Self.recovery.write(archive)
    }
    baseline = file.bytes
    encoding = file.encoding
    bom = file.bom
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: file.text)
    undo.removeAllActions()
    try await Self.recovery.remove(id)
    notify()
  }
}

@MainActor final class DocumentPool {
  static let shared = DocumentPool()
  var documents: [CodeDocument] = []
  func open(_ url: URL) async throws -> CodeDocument {
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    if let existing = documents.first(where: {
      $0.url?.resolvingSymlinksInPath().standardizedFileURL == canonical
    }) {
      return existing
    }
    let file = try await Task.detached {
      try TextFile(data: Data(contentsOf: canonical, options: .mappedIfSafe))
    }.value
    let doc = CodeDocument(url: url, file: file)
    documents.append(doc)
    return doc
  }
  func moved(from: URL, to: URL) {
    for doc in documents {
      guard let old = doc.url, old == from || old.path.hasPrefix(from.path + "/") else { continue }
      doc.languageSession?.close(doc, url: old)
      doc.languageSession = nil
      doc.url =
        old == from ? to : URL(fileURLWithPath: to.path + old.path.dropFirst(from.path.count))
      if doc.modified {
        let record = doc.recoveryRecord()
        Task { try? await CodeDocument.recovery.write(record) }
      }
      doc.notify()
    }
  }
}
