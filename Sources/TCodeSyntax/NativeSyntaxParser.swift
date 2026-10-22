import CTreeSitter
import Darwin
import Foundation
import TCodeCore

/// Swift ownership and incremental edit binding for the pinned Tree-sitter 0.25.10 C runtime.
/// This type must only run in the sandboxed service (or isolated parser tests), never the editor.
public final class NativeSyntaxParser {
  private final class QueryBudget {
    let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
    var expired = false
    func shouldStop() -> Bool {
      if DispatchTime.now().uptimeNanoseconds >= deadline { expired = true }
      return expired
    }
  }
  private final class Grammar {
    let descriptor: SyntaxGrammarDescriptor
    let handle: UnsafeMutableRawPointer
    let language: OpaquePointer
    let query: OpaquePointer
    let moduleDescriptor: Int32?
    init(
      descriptor: SyntaxGrammarDescriptor, handle: UnsafeMutableRawPointer,
      language: OpaquePointer, query: OpaquePointer, moduleDescriptor: Int32?
    ) {
      self.descriptor = descriptor
      self.handle = handle
      self.language = language
      self.query = query
      self.moduleDescriptor = moduleDescriptor
    }
    deinit {
      ts_query_delete(query)
      dlclose(handle)
      if let moduleDescriptor { Darwin.close(moduleDescriptor) }
    }
  }
  private final class Document {
    let grammarKey: String
    let parser: OpaquePointer
    var tree: OpaquePointer?
    var bytes = [UInt8]()
    var version = -1
    var cachedResponse: SyntaxResponse?
    init(grammar: Grammar, key: String) throws {
      guard let parser = ts_parser_new() else { throw SyntaxFailure.unavailable }
      self.parser = parser
      grammarKey = key
      guard ts_parser_set_language(parser, grammar.language) else {
        ts_parser_delete(parser)
        throw SyntaxFailure.invalidGrammar("Unsupported language ABI")
      }
      ts_parser_set_timeout_micros(parser, 150_000)
    }
    deinit {
      if let tree { ts_tree_delete(tree) }
      ts_parser_delete(parser)
    }
  }
  private var grammars = [String: Grammar]()
  private var documents = [UUID: Document]()
  private let moduleDirectory: URL
  public init(moduleDirectory: URL) throws {
    self.moduleDirectory = moduleDirectory
    try FileManager.default.createDirectory(
      at: moduleDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }
  deinit {
    documents.removeAll()
    grammars.removeAll()
    try? FileManager.default.removeItem(at: moduleDirectory)
  }
  public func close(_ id: UUID) { documents[id] = nil }
  public func highlight(_ request: SyntaxRequest, moduleFileDescriptor: Int32? = nil) throws
    -> SyntaxResponse
  {
    guard request.text.utf16.count <= 2_000_000 else { throw SyntaxFailure.tooLarge }
    guard documents.count < 64 || documents[request.documentID] != nil else {
      throw SyntaxFailure.invalidGrammar("Syntax document limit reached")
    }
    let started = ContinuousClock.now
    let key =
      request.grammar.id + ":" + request.grammar.moduleSHA256 + ":" + request.grammar.querySHA256
    let grammar = try load(request, key: key, moduleFileDescriptor: moduleFileDescriptor)
    if documents[request.documentID]?.grammarKey != key {
      documents[request.documentID] = try Document(grammar: grammar, key: key)
    }
    let document = documents[request.documentID]!
    guard request.version >= document.version else { throw SyntaxFailure.stale }
    let bytes = Array(request.text.utf8)
    if request.version == document.version, bytes == document.bytes,
      let cached = document.cachedResponse
    {
      return cached
    }
    // A failed parse/query must never make the previous version appear current.
    document.cachedResponse = nil
    var incremental = false
    if let oldTree = document.tree {
      var edit = Self.edit(from: document.bytes, to: bytes)
      ts_tree_edit(oldTree, &edit)
      incremental = true
    }
    let next = request.text.withCString { pointer in
      ts_parser_parse_string(document.parser, document.tree, pointer, UInt32(bytes.count))
    }
    guard let next else {
      ts_parser_reset(document.parser)
      if let old = document.tree { ts_tree_delete(old) }
      document.tree = nil
      document.bytes = []
      document.version = -1
      throw SyntaxFailure.timeout
    }
    if let old = document.tree { ts_tree_delete(old) }
    document.tree = next
    document.bytes = bytes
    document.version = request.version
    guard let cursor = ts_query_cursor_new() else { throw SyntaxFailure.unavailable }
    defer { ts_query_cursor_delete(cursor) }
    ts_query_cursor_set_match_limit(cursor, 65_536)
    let budget = QueryBudget()
    var options = TSQueryCursorOptions(
      payload: Unmanaged.passUnretained(budget).toOpaque(),
      progress_callback: { state in
        guard let payload = state?.pointee.payload else { return true }
        return Unmanaged<QueryBudget>.fromOpaque(payload).takeUnretainedValue().shouldStop()
      })
    let offsets = Self.utf16Offsets(request.text)
    var match = TSQueryMatch()
    var captureIndex: UInt32 = 0
    var spans = [SyntaxHighlightSpan]()
    try withUnsafePointer(to: &options) { pointer in
      ts_query_cursor_exec_with_options(cursor, grammar.query, ts_tree_root_node(next), pointer)
      while ts_query_cursor_next_capture(cursor, &match, &captureIndex) {
        guard spans.count < 100_000 else {
          throw SyntaxFailure.invalidGrammar("Capture limit exceeded")
        }
        let capture = match.captures[Int(captureIndex)]
        let start = Int(ts_node_start_byte(capture.node))
        let end = Int(ts_node_end_byte(capture.node))
        guard start <= end, end < offsets.count else { throw SyntaxFailure.invalidResponse }
        var count: UInt32 = 0
        guard let name = ts_query_capture_name_for_id(grammar.query, capture.index, &count),
          count <= 128
        else {
          throw SyntaxFailure.invalidResponse
        }
        let label = String(
          decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(name).assumingMemoryBound(to: UInt8.self), count: Int(count)),
          as: UTF8.self)
        if end > start {
          spans.append(
            SyntaxHighlightSpan(
              location: offsets[start], length: offsets[end] - offsets[start], capture: label))
        }
      }
    }
    if ts_query_cursor_did_exceed_match_limit(cursor) || budget.expired {
      throw SyntaxFailure.timeout
    }
    let elapsed = started.duration(to: .now).components
    let response = SyntaxResponse(
      documentID: request.documentID, version: request.version, spans: spans,
      parseMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
      incremental: incremental)
    document.cachedResponse = response
    return response
  }
  private func load(_ request: SyntaxRequest, key: String, moduleFileDescriptor: Int32?) throws
    -> Grammar
  {
    if let loaded = grammars[key] { return loaded }
    guard grammars.count < 16 else {
      throw SyntaxFailure.invalidGrammar("Loaded grammar limit reached; restart syntax service")
    }
    guard let bytes = request.moduleData, let queryBytes = request.queryData else {
      throw SyntaxFailure.invalidGrammar("The grammar is not loaded in this service instance")
    }
    try SyntaxIntegrity.validateModule(bytes, descriptor: request.grammar)
    guard queryBytes.count <= 1_048_576,
      SyntaxIntegrity.sha256(queryBytes) == request.grammar.querySHA256,
      let source = String(data: queryBytes, encoding: .utf8)
    else {
      throw SyntaxFailure.invalidGrammar("Invalid query digest or UTF-8")
    }
    let path: String
    var ownedDescriptor: Int32?
    if let fd = moduleFileDescriptor {
      let duplicated = fcntl(fd, F_DUPFD_CLOEXEC, 0)
      guard duplicated >= 0 else {
        throw SyntaxFailure.invalidGrammar("Cannot retain grammar descriptor")
      }
      ownedDescriptor = duplicated
      path = "/dev/fd/" + String(duplicated)
    } else {
      // Direct native parser tests are isolated from production editor code.
      let file = moduleDirectory.appendingPathComponent(request.grammar.moduleSHA256 + ".dylib")
      if !FileManager.default.fileExists(atPath: file.path) {
        try bytes.write(to: file, options: .atomic)
      }
      path = file.path
    }
    var keepDescriptor = false
    defer { if !keepDescriptor, let ownedDescriptor { Darwin.close(ownedDescriptor) } }
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      throw SyntaxFailure.invalidGrammar(String(cString: dlerror()))
    }
    guard let entry = dlsym(handle, request.grammar.symbol) else {
      dlclose(handle)
      throw SyntaxFailure.invalidGrammar("Missing grammar entry point")
    }
    typealias Entry = @convention(c) () -> OpaquePointer?
    guard let language = unsafeBitCast(entry, to: Entry.self)() else {
      dlclose(handle)
      throw SyntaxFailure.invalidGrammar("Invalid grammar language")
    }
    let abi = ts_language_abi_version(language)
    guard abi == request.grammar.abi, abi >= TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION,
      abi <= TREE_SITTER_LANGUAGE_VERSION
    else {
      dlclose(handle)
      throw SyntaxFailure.invalidGrammar("Unsupported grammar ABI \(abi)")
    }
    var offset: UInt32 = 0
    var error = TSQueryErrorNone
    let query = source.withCString {
      ts_query_new(language, $0, UInt32(queryBytes.count), &offset, &error)
    }
    guard let query else {
      dlclose(handle)
      throw SyntaxFailure.invalidGrammar(
        "\(request.grammar.id) highlight query error \(error.rawValue) at byte \(offset)")
    }
    // v1 packs use structural queries; predicate directives require a future bounded evaluator.
    for index in 0..<ts_query_pattern_count(query) {
      var count: UInt32 = 0
      _ = ts_query_predicates_for_pattern(query, index, &count)
      if count > 0 {
        ts_query_delete(query)
        dlclose(handle)
        throw SyntaxFailure.invalidGrammar("Query predicates are unsupported in schema 1")
      }
    }
    let grammar = Grammar(
      descriptor: request.grammar, handle: handle, language: language, query: query,
      moduleDescriptor: ownedDescriptor)
    keepDescriptor = true
    grammars[key] = grammar
    return grammar
  }
  private static func point(_ bytes: [UInt8], at offset: Int) -> TSPoint {
    var row: UInt32 = 0
    var column: UInt32 = 0
    for byte in bytes.prefix(offset) {
      if byte == 10 {
        row += 1
        column = 0
      } else {
        column += 1
      }
    }
    return TSPoint(row: row, column: column)
  }
  private static func boundary(_ bytes: [UInt8], _ index: Int) -> Bool {
    index == bytes.count || (bytes[index] & 0xc0) != 0x80
  }
  static func edit(from old: [UInt8], to new: [UInt8]) -> TSInputEdit {
    var start = 0
    while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
    while start > 0 && (!boundary(old, start) || !boundary(new, start)) { start -= 1 }
    var oldEnd = old.count
    var newEnd = new.count
    while oldEnd > start && newEnd > start && old[oldEnd - 1] == new[newEnd - 1] {
      oldEnd -= 1
      newEnd -= 1
    }
    while oldEnd < old.count && (!boundary(old, oldEnd) || !boundary(new, newEnd)) {
      oldEnd += 1
      newEnd += 1
    }
    return TSInputEdit(
      start_byte: UInt32(start), old_end_byte: UInt32(oldEnd), new_end_byte: UInt32(newEnd),
      start_point: point(old, at: start), old_end_point: point(old, at: oldEnd),
      new_end_point: point(new, at: newEnd))
  }
  private static func utf16Offsets(_ text: String) -> [Int] {
    var result = [Int](repeating: 0, count: text.utf8.count + 1)
    var byteOffset = 0
    var units = 0
    for scalar in text.unicodeScalars {
      for _ in scalar.utf8 {
        result[byteOffset] = units
        byteOffset += 1
      }
      units += scalar.utf16.count
    }
    result[byteOffset] = units
    return result
  }
}
