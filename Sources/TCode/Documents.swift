import AppKit
import TCodeCore

/// Per-pane editor state. It lives with the document so switching tabs can rebuild a pane
/// without losing the caret, scroll position, folds, or secondary cursors.
struct EditorViewState {
  var selection = NSRange(location: 0, length: 0)
  var additionalCursors: [Int] = []
  var folded: [NSRange] = []
  var scrollOrigin = NSPoint.zero
}

@MainActor final class CodeDocument: NSObject, @preconcurrency NSTextStorageDelegate {
  let id: UUID
  var url: URL?
  /// Resolved identity used by the document pool and workspace edits.
  var canonicalURL: URL?
  let storage: NSTextStorage
  let undo = UndoManager()
  var baseline: Data?
  var encoding = String.Encoding.utf8
  var bom = Data()
  var version = 1
  var isSaving = false
  /// Cheap UI dirtiness. Exact `modified` is reserved for save/close/quit decisions.
  var isDirty = false
  var lineIndex: LineIndex
  var lineEnding = "LF"
  var viewStates: [EditorViewState] = []
  var splitCount = 1
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
  var languageKey: String?
  var cachedMatch: LanguageMatch?
  var syntaxStatus = "Basic highlighting"
  var title: String { url?.lastPathComponent ?? "Untitled" }
  var text: String { storage.string }
  /// Exact comparison. This encodes the whole buffer, so it must stay off the keystroke path.
  var modified: Bool { (try? encoded()) != baseline && !(baseline == nil && text.isEmpty) }
  var large: Bool { storage.length > 2_000_000 }
  static let recovery = RecoveryStore(
    directory: ProcessInfo.processInfo.environment["TCODE_RECOVERY_PATH"].map {
      URL(fileURLWithPath: $0)
    }
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support/tCode/Recovery"))
  init(url: URL? = nil, file: TextFile? = nil, recovery: RecoveryRecord? = nil) {
    let initialText = recovery?.text ?? file?.text ?? ""
    id = recovery?.id ?? UUID()
    self.url = url
    storage = NSTextStorage(string: initialText)
    lineIndex = LineIndex(text: initialText)
    baseline = recovery?.baseline ?? file?.bytes
    encoding = recovery.map { String.Encoding(rawValue: $0.encoding) } ?? file?.encoding ?? .utf8
    bom = recovery?.bom ?? file?.bom ?? Data()
    super.init()
    canonicalURL = url?.resolvingSymlinksInPath().standardizedFileURL
    isDirty = recovery != nil
    lineEnding = Self.detectLineEnding(storage.mutableString)
    storage.delegate = self
  }
  private static func detectLineEnding(_ text: NSString) -> String {
    var index = 0
    while index < text.length {
      let unit = text.character(at: index)
      if unit == 13 {
        return index + 1 < text.length && text.character(at: index + 1) == 10 ? "CRLF" : "CR"
      }
      if unit == 10 { return "LF" }
      index += 1
    }
    return "LF"
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
    isDirty = true
    version += 1
    let text = storage.mutableString
    lineIndex.applyEdit(text: text, editedRange: editedRange, delta: delta)
    var index = min(max(0, editedRange.location), text.length)
    let end = min(NSMaxRange(editedRange), text.length)
    var hasLineBreak = false
    while index < end {
      let unit = text.character(at: index)
      if unit == 10 || unit == 13 {
        hasLineBreak = true
        break
      }
      index += 1
    }
    if hasLineBreak { lineEnding = Self.detectLineEnding(text) }
    recoveryTask?.cancel()
    notify()
    languageSession?.changed(self)
    // Snapshot only after the debounce. Building a recovery record on every keystroke copied
    // the full buffer and baseline even when the user was still typing.
    recoveryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard let self, !Task.isCancelled else { return }
      let record = self.recoveryRecord()
      if self.isDirty {
        try? await Self.recovery.write(record)
      } else {
        try? await Self.recovery.remove(record.id)
      }
    }
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
    canonicalURL = destination.resolvingSymlinksInPath().standardizedFileURL
    baseline = data
    isDirty = false
    if oldURL != url {
      languageSession?.close(self, url: oldURL)
      languageSession = nil
    }
    recoveryTask?.cancel()
    try? await Self.recovery.remove(id)
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
    lineIndex = LineIndex(text: storage.mutableString)
    lineEnding = Self.detectLineEnding(storage.mutableString)
    isDirty = false
    recoveryTask?.cancel()
    undo.removeAllActions()
    try? await Self.recovery.remove(id)
    notify()
  }
}

@MainActor final class DocumentPool {
  static let shared = DocumentPool()
  var documents: [CodeDocument] = []
  func open(_ url: URL) async throws -> CodeDocument {
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    if let existing = documents.first(where: { $0.canonicalURL == canonical }) {
      return existing
    }
    let file = try await Task.detached {
      try TextFile(data: Data(contentsOf: canonical, options: .mappedIfSafe))
    }.value
    // A second open can pass the check above while this read is in flight; re-check so the
    // same file never ends up as two documents (and two tabs).
    if let existing = documents.first(where: { $0.canonicalURL == canonical }) {
      return existing
    }
    let doc = CodeDocument(url: url, file: file)
    doc.canonicalURL = canonical
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
      doc.canonicalURL = doc.url?.resolvingSymlinksInPath().standardizedFileURL
      if doc.modified {
        let record = doc.recoveryRecord()
        Task { try? await CodeDocument.recovery.write(record) }
      }
      doc.notify()
    }
  }
}
