import Foundation
import TCodeCore

actor SyntaxClient {
  static let shared = SyntaxClient()
  private struct WorkKey: Equatable {
    let version: Int
    let grammar: String
    let configuration: Int
  }
  private struct Pending {
    let token: UUID
    let key: WorkKey
    let task: Task<SyntaxResponse, Error>
  }
  private struct Cached {
    let key: WorkKey
    let spans: [SyntaxHighlightSpan]
  }
  private let connection = SyntaxConnection()
  private let requestHandler: (@Sendable (SyntaxRequest) async throws -> SyntaxResponse)?
  private let moduleLoader: @Sendable (SyntaxGrammarDescriptor, URL) throws -> (Data, Data)
  private var descriptors = [String: SyntaxGrammarDescriptor]()
  private var latest = [UUID: WorkKey]()
  private var pending = [UUID: Pending]()
  private var results = [UUID: Cached]()
  private var root = SyntaxGrammarStore.defaultRoot
  private var sent = Set<String>()
  private var connectionGeneration = -1
  private var configuration = 0
  private var cachedModules = [String: (Data, Data)]()
  private(set) var serviceProcessID: Int32?

  init(
    artifacts supplied: [SyntaxGrammarArtifact]? = nil, root: URL = SyntaxGrammarStore.defaultRoot,
    requestHandler: (@Sendable (SyntaxRequest) async throws -> SyntaxResponse)? = nil,
    moduleLoader: @escaping @Sendable (SyntaxGrammarDescriptor, URL) throws -> (Data, Data) = {
      try SyntaxGrammarStore.read($0, root: $1)
    }
  ) {
    self.root = root
    self.requestHandler = requestHandler
    self.moduleLoader = moduleLoader
    if let supplied {
      descriptors = Self.activated(supplied, root: root)
      return
    }
    if let url = Bundle.module.url(
      forResource: "grammars", withExtension: "json", subdirectory: "Resources/Syntax"),
      let data = try? Data(contentsOf: url),
      let artifacts = try? JSONDecoder().decode([SyntaxGrammarArtifact].self, from: data)
    {
      descriptors = Self.activated(artifacts, root: root)
    }
  }
  /// Only accepted curated catalog metadata can supply executable module identities.
  func configure(artifacts: [SyntaxGrammarArtifact], root: URL = SyntaxGrammarStore.defaultRoot) {
    configuration += 1
    descriptors = Self.activated(artifacts, root: root)
    self.root = root
    cachedModules.removeAll()
    sent.removeAll()
    results.removeAll()
    latest.removeAll()
    for work in pending.values { work.task.cancel() }
    pending.removeAll()
    connection.invalidate()
  }
  private static func activated(_ artifacts: [SyntaxGrammarArtifact], root: URL) -> [String:
    SyntaxGrammarDescriptor]
  {
    artifacts.reduce(into: [:]) { result, artifact in
      result[artifact.descriptor.id] =
        (try? SyntaxGrammarStore.activatedDescriptor(id: artifact.descriptor.id, root: root))
        ?? artifact.descriptor
    }
  }
  func highlight(
    documentID: UUID, version: Int, text: String, grammarID: String,
    queryOverride: String? = nil
  ) async throws -> [SyntaxHighlightSpan] {
    guard text.utf16.count <= 2_000_000 else { throw SyntaxFailure.tooLarge }
    guard let baseDescriptor = descriptors[grammarID] else {
      throw SyntaxFailure.notInstalled(grammarID)
    }
    let descriptor: SyntaxGrammarDescriptor
    let overrideData: Data?
    if let queryOverride {
      let data = Data(queryOverride.utf8)
      guard !data.isEmpty, data.count <= 1_048_576 else {
        throw SyntaxFailure.invalidGrammar(
          "Custom highlight queries must be between 1 byte and 1 MiB")
      }
      overrideData = data
      descriptor = SyntaxGrammarDescriptor(
        id: baseDescriptor.id, version: baseDescriptor.version,
        symbol: baseDescriptor.symbol, moduleSHA256: baseDescriptor.moduleSHA256,
        querySHA256: SyntaxIntegrity.sha256(data), sourceRevision: baseDescriptor.sourceRevision,
        abi: baseDescriptor.abi, module: baseDescriptor.module, query: baseDescriptor.query)
    } else {
      descriptor = baseDescriptor
      overrideData = nil
    }
    let grammarKey = descriptor.id + ":" + descriptor.moduleSHA256 + ":" + descriptor.querySHA256
    let key = WorkKey(version: version, grammar: grammarKey, configuration: configuration)
    if let previous = latest[documentID], previous.version > version { throw SyntaxFailure.stale }
    latest[documentID] = key
    try Task.checkCancellation()
    if let cached = results[documentID], cached.key == key { return cached.spans }

    // One request per document is in flight. Split views join the same request;
    // rapid edits coalesce to the newest version while an older parse completes.
    while let work = pending[documentID] {
      if work.key == key { return try await finish(work, documentID: documentID) }
      _ = try? await finish(work, documentID: documentID)
      guard latest[documentID] == key else { throw SyntaxFailure.stale }
    }
    let baseKey =
      baseDescriptor.id + ":" + baseDescriptor.moduleSHA256 + ":" + baseDescriptor.querySHA256
    let stored: (Data, Data)
    if let cached = cachedModules[baseKey] {
      stored = cached
    } else {
      let root = self.root
      let loader = moduleLoader
      stored = try await Background.run { try loader(baseDescriptor, root) }
      guard latest[documentID] == key else { throw SyntaxFailure.stale }
      cachedModules[baseKey] = stored
    }
    guard latest[documentID] == key else { throw SyntaxFailure.stale }
    // Another split can have started this work while the module was read off the main actor.
    while let work = pending[documentID] {
      if work.key == key { return try await finish(work, documentID: documentID) }
      _ = try? await finish(work, documentID: documentID)
      guard latest[documentID] == key else { throw SyntaxFailure.stale }
    }
    if connectionGeneration != connection.connectionGeneration {
      connectionGeneration = connection.connectionGeneration
      sent.removeAll()
    }
    let includeModule = !sent.contains(grammarKey)
    let request = SyntaxRequest(
      documentID: documentID, version: version, text: text, grammar: descriptor,
      moduleData: includeModule ? stored.0 : nil,
      queryData: includeModule ? (overrideData ?? stored.1) : nil)
    let connection = self.connection
    let handler = requestHandler
    let work = Pending(
      token: UUID(), key: key,
      task: Task {
        if let handler { return try await handler(request) }
        return try await connection.highlight(request)
      })
    pending[documentID] = work
    return try await finish(work, documentID: documentID)
  }
  private func finish(_ work: Pending, documentID: UUID) async throws -> [SyntaxHighlightSpan] {
    do {
      let response = try await work.task.value
      if pending[documentID]?.token == work.token { pending[documentID] = nil }
      guard latest[documentID] == work.key, configuration == work.key.configuration else {
        throw SyntaxFailure.stale
      }
      sent.insert(work.key.grammar)
      serviceProcessID = response.serviceProcessID
      results[documentID] = Cached(key: work.key, spans: response.spans)
      try Task.checkCancellation()
      return response.spans
    } catch {
      if pending[documentID]?.token == work.token { pending[documentID] = nil }
      if configuration == work.key.configuration { sent.remove(work.key.grammar) }
      throw error
    }
  }
  /// The document owner calls this only when its last shared view closes.
  func close(_ documentID: UUID) {
    latest[documentID] = nil
    results[documentID] = nil
    pending[documentID]?.task.cancel()
    pending[documentID] = nil
    connection.close(documentID)
  }
}
