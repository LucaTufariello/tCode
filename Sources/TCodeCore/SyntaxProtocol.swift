import CryptoKit
import Foundation

/// Ranges use the editor's native UTF-16 coordinate space, never UTF-8 byte offsets.
public struct SyntaxHighlightSpan: Codable, Equatable, Sendable {
  public let location: Int
  public let length: Int
  public let capture: String
  public var range: NSRange { NSRange(location: location, length: length) }
  public init(location: Int, length: Int, capture: String) {
    self.location = location
    self.length = length
    self.capture = capture
  }
}

/// A curated catalog identifies every executable module by its exact digest.
/// Imported language packs may reference these identifiers, but cannot add modules.
public struct SyntaxGrammarDescriptor: Codable, Equatable, Sendable {
  public let id: String
  public let version: String
  public let symbol: String
  public let moduleSHA256: String
  public let querySHA256: String
  public let sourceRevision: String
  public let abi: UInt32
  public let module: String
  public let query: String
  public init(
    id: String, version: String, symbol: String, moduleSHA256: String,
    querySHA256: String, sourceRevision: String, abi: UInt32,
    module: String = "grammar.dylib", query: String = "highlights.scm"
  ) {
    self.id = id
    self.version = version
    self.symbol = symbol
    self.moduleSHA256 = moduleSHA256
    self.querySHA256 = querySHA256
    self.sourceRevision = sourceRevision
    self.abi = abi
    self.module = module
    self.query = query
  }
  public func validate() throws {
    let identifier = #"^[a-z][a-z0-9-]{0,63}$"#
    guard id.range(of: identifier, options: .regularExpression) != nil,
      version.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$"#, options: .regularExpression) != nil,
      symbol.range(of: #"^tree_sitter_[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil,
      [moduleSHA256, querySHA256].allSatisfy({
        $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
      }),
      [module, query].allSatisfy({
        $0.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,100}$"#, options: .regularExpression) != nil
      }),
      !sourceRevision.isEmpty, sourceRevision.count <= 128,
      (13...15).contains(abi)
    else { throw SyntaxFailure.invalidGrammar("Invalid grammar metadata") }
  }
}

public enum SyntaxFailure: LocalizedError {
  case unavailable
  case notInstalled(String)
  case invalidGrammar(String)
  case invalidResponse, tooLarge, stale, timeout
  public var errorDescription: String? {
    switch self {
    case .unavailable:
      return "The native syntax service is unavailable. Basic highlighting remains active."
    case .notInstalled(let id):
      return "Install the \(id) grammar in Language Support to enable parser highlighting."
    case .invalidGrammar(let reason): return "Grammar validation failed: \(reason)"
    case .invalidResponse: return "The syntax service returned an invalid result."
    case .tooLarge:
      return "Parser highlighting is disabled for documents larger than 2 million UTF-16 units."
    case .stale: return "A newer document version superseded this syntax result."
    case .timeout:
      return "The syntax service exceeded its time budget. Basic highlighting remains active."
    }
  }
}

public struct SyntaxRequest: Codable, Sendable {
  public let documentID: UUID
  public let version: Int
  public let text: String
  public let grammar: SyntaxGrammarDescriptor
  public let moduleData: Data?
  public let queryData: Data?
  public init(
    documentID: UUID, version: Int, text: String, grammar: SyntaxGrammarDescriptor,
    moduleData: Data?, queryData: Data?
  ) {
    self.documentID = documentID
    self.version = version
    self.text = text
    self.grammar = grammar
    self.moduleData = moduleData
    self.queryData = queryData
  }
}
public struct SyntaxResponse: Codable, Sendable {
  public let documentID: UUID
  public let version: Int
  public let spans: [SyntaxHighlightSpan]
  public let parseMilliseconds: Double
  public let incremental: Bool
  public let serviceProcessID: Int32
  public init(
    documentID: UUID, version: Int, spans: [SyntaxHighlightSpan], parseMilliseconds: Double,
    incremental: Bool, serviceProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
  ) {
    self.documentID = documentID
    self.version = version
    self.spans = spans
    self.parseMilliseconds = parseMilliseconds
    self.incremental = incremental
    self.serviceProcessID = serviceProcessID
  }
}

@objc public protocol SyntaxServiceProtocol {
  func highlight(_ request: Data, module: FileHandle?, reply: @escaping (Data?, String?) -> Void)
  func closeDocument(_ identifier: String)
  /// No bytes leave this diagnostic; used by the packaged isolation regression.
  func isolationProbe(_ forbiddenPath: String, reply: @escaping (Bool, Bool, Int32) -> Void)
  /// The probe deliberately closes its own connection; production editors recover independently.
  func terminateForTesting()
}

public enum SyntaxIntegrity {
  public static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  public static func validateModule(_ bytes: Data, descriptor: SyntaxGrammarDescriptor) throws {
    try descriptor.validate()
    guard bytes.count >= 32, bytes.count <= 64 * 1024 * 1024,
      sha256(bytes) == descriptor.moduleSHA256
    else {
      throw SyntaxFailure.invalidGrammar("Module size or SHA-256 mismatch")
    }
    let header = [UInt8](bytes.prefix(12))
    guard Array(header[0..<4]) == [0xcf, 0xfa, 0xed, 0xfe],
      Array(header[4..<8]) == [0x0c, 0x00, 0x00, 0x01]
    else {
      throw SyntaxFailure.invalidGrammar("Expected a native arm64 Mach-O module")
    }
  }
}

/// Does not load executable code. Only the sandboxed XPC service may dlopen these bytes.
public enum SyntaxGrammarStore {
  public static var defaultRoot: URL {
    LanguageSupportPaths.root.appendingPathComponent("grammars", isDirectory: true)
  }
  public static func directory(for descriptor: SyntaxGrammarDescriptor, root: URL = defaultRoot)
    -> URL
  {
    root.appendingPathComponent(descriptor.id).appendingPathComponent(descriptor.version)
  }
  /// Installer-owned activation metadata. Imports never write this receipt.
  public static func activatedDescriptor(
    id: String, root: URL = defaultRoot, allowLocalArtifactsForTesting: Bool = false
  ) throws
    -> SyntaxGrammarDescriptor?
  {
    guard id.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
      return nil
    }
    let receipt = root.appendingPathComponent(id).appendingPathComponent("active.json")
    guard FileManager.default.fileExists(atPath: receipt.path) else { return nil }
    let canonicalRoot = root.resolvingSymlinksInPath().path + "/"
    guard receipt.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot),
      (try receipt.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65_536
    else {
      throw SyntaxFailure.invalidGrammar("Invalid managed activation receipt")
    }
    let artifact = try JSONDecoder().decode(
      SyntaxGrammarArtifact.self, from: Data(contentsOf: receipt))
    try artifact.descriptor.validate()
    guard artifact.descriptor.id == id,
      (allowLocalArtifactsForTesting && artifact.url.isFileURL)
        || (artifact.url.scheme == "https" && artifact.url.host == "github.com"
          && artifact.url.path.hasPrefix("/LucaTufariello/tCode/releases/download/"))
    else {
      throw SyntaxFailure.invalidGrammar("Activation receipt is not a curated managed grammar")
    }
    return artifact.descriptor
  }
  public static func read(_ descriptor: SyntaxGrammarDescriptor, root: URL = defaultRoot) throws
    -> (Data, Data)
  {
    try descriptor.validate()
    let directory = directory(for: descriptor, root: root)
    let canonicalRoot = root.resolvingSymlinksInPath().path + "/"
    let files = [
      directory.appendingPathComponent(descriptor.module),
      directory.appendingPathComponent(descriptor.query),
    ]
    guard files.allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot) }) else {
      throw SyntaxFailure.invalidGrammar("Grammar files escape the managed store")
    }
    guard FileManager.default.fileExists(atPath: files[0].path) else {
      throw SyntaxFailure.notInstalled(descriptor.id)
    }
    let moduleSize = try files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let querySize = try files[1].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard (32...67_108_864).contains(moduleSize), (1...1_048_576).contains(querySize) else {
      throw SyntaxFailure.invalidGrammar("Installed grammar size limit exceeded")
    }
    let module = try Data(contentsOf: files[0], options: .mappedIfSafe)
    let query = try Data(contentsOf: files[1])
    try SyntaxIntegrity.validateModule(module, descriptor: descriptor)
    guard query.count <= 1_048_576, SyntaxIntegrity.sha256(query) == descriptor.querySHA256 else {
      throw SyntaxFailure.invalidGrammar("Query size or SHA-256 mismatch")
    }
    return (module, query)
  }
}
