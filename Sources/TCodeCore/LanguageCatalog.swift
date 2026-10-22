import CryptoKit
import Foundation

private final class BoundedCatalogDownload: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  let limit: Int64
  init(limit: Int64) { self.limit = limit }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}

public enum LanguageSupportPaths {
  public static var root: URL {
    if let override = ProcessInfo.processInfo.environment["TCODE_SUPPORT_DIRECTORY"] {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("tCode", isDirectory: true)
  }
}

public struct LanguageCatalogEntry: Codable, Identifiable, Sendable {
  public enum Availability: String, Codable, Sendable { case draft, published }
  public let id: String
  public let name: String
  public let version: String
  public let summary: String
  public let packURL: URL
  public let packSHA256: String?
  public let toolRecipeIDs: [String]
  public let grammarArtifactIDs: [String]
  public let availability: Availability
  public let bundledFilename: String?
  public init(
    id: String, name: String, version: String, summary: String, packURL: URL, packSHA256: String?,
    toolRecipeIDs: [String], grammarArtifactIDs: [String], availability: Availability,
    bundledFilename: String? = nil
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.summary = summary
    self.packURL = packURL
    self.packSHA256 = packSHA256
    self.toolRecipeIDs = toolRecipeIDs
    self.grammarArtifactIDs = grammarArtifactIDs
    self.availability = availability
    self.bundledFilename = bundledFilename
  }
}

public struct LanguageCatalog: Codable, Sendable {
  public static let defaultURL = URL(
    string:
      "https://github.com/LucaTufariello/tCode/releases/download/language-catalog-v1/catalog.json")!
  public let version: Int
  public let entries: [LanguageCatalogEntry]
  public let publication: String
  public let grammarArtifacts: [SyntaxGrammarArtifact]
  public let lastUpdated: String?
  public init(
    version: Int = 1, entries: [LanguageCatalogEntry], publication: String,
    lastUpdated: String? = nil, grammarArtifacts: [SyntaxGrammarArtifact] = []
  ) {
    self.version = version
    self.entries = entries
    self.publication = publication
    self.lastUpdated = lastUpdated
    self.grammarArtifacts = grammarArtifacts
  }
  enum CodingKeys: String, CodingKey {
    case version, entries, publication, lastUpdated, grammarArtifacts
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    entries = try values.decode([LanguageCatalogEntry].self, forKey: .entries)
    publication = try values.decode(String.self, forKey: .publication)
    lastUpdated = try values.decodeIfPresent(String.self, forKey: .lastUpdated)
    grammarArtifacts =
      try values.decodeIfPresent([SyntaxGrammarArtifact].self, forKey: .grammarArtifacts) ?? []
  }
  public static var starter: LanguageCatalog {
    let items: [(String, String, String, [String], [String])] = [
      (
        "python", "Python", "Python editing, pylsp, Ruff, Black, pytest, and debugpy.",
        ["python-tools"], ["python"]
      ),
      (
        "cpp", "C / C++", "C and C++ editing, clangd, CMake, and LLDB.",
        ["xcode-tools", "clang-format"], ["c", "cpp"]
      ),
      (
        "swift", "Swift", "Swift editing, SourceKit-LSP, SwiftPM, and LLDB.", ["xcode-tools"],
        ["swift"]
      ),
      (
        "rust", "Rust", "Rust editing, rust-analyzer, rustfmt, Cargo, and LLDB.",
        ["rust-analyzer", "rust-toolchain", "xcode-tools"], ["rust"]
      ),
    ]
    return LanguageCatalog(
      entries: items.map { id, name, summary, tools, grammars in
        LanguageCatalogEntry(
          id: id, name: name, version: "2.0.0", summary: summary,
          packURL: URL(
            string:
              "https://github.com/LucaTufariello/tCode/releases/download/language-packs-v2.0.0/\(id).json"
          )!, packSHA256: nil, toolRecipeIDs: tools, grammarArtifactIDs: grammars,
          availability: .draft,
          bundledFilename: id == "rust" ? "CatalogPacks/rust.json" : id + ".json")
      },
      publication: "Bundled starter catalog. Remote release artifacts have not yet been published.")
  }
  public func validate() throws {
    guard version == 1 else {
      throw LanguageCatalogError.invalid("Unsupported catalog interface version \(version).")
    }
    guard Set(entries.map(\.id)).count == entries.count else {
      throw LanguageCatalogError.invalid("Duplicate catalog identities.")
    }
    guard Set(grammarArtifacts.map { $0.descriptor.id }).count == grammarArtifacts.count else {
      throw LanguageCatalogError.invalid("Duplicate grammar identities in catalog.")
    }
    for artifact in grammarArtifacts {
      try artifact.descriptor.validate()
      guard Self.isCuratedReleaseURL(artifact.url),
        Self.validHash(artifact.sha256), (1...67_108_864).contains(artifact.downloadBytes)
      else {
        throw LanguageCatalogError.invalid(
          "Grammar artifacts must use pinned, versioned tCode release downloads with valid size and SHA-256."
        )
      }
    }
    for entry in entries {
      guard ToolInstaller.validComponent(entry.id), ToolInstaller.validComponent(entry.version),
        Self.isCuratedReleaseURL(entry.packURL),
        entry.toolRecipeIDs.allSatisfy(ToolInstaller.validComponent),
        entry.grammarArtifactIDs.allSatisfy(ToolInstaller.validComponent)
      else {
        throw LanguageCatalogError.invalid(
          "Catalog packs must use a versioned tCode GitHub release URL.")
      }
      if entry.availability == .published {
        guard let hash = entry.packSHA256, Self.validHash(hash) else {
          throw LanguageCatalogError.invalid("Published pack \(entry.id) has no valid SHA-256.")
        }
      }
      if let filename = entry.bundledFilename,
        ![entry.id + ".json", "CatalogPacks/" + entry.id + ".json"].contains(filename)
      {
        throw LanguageCatalogError.invalid("Invalid bundled language configuration path.")
      }
    }
  }
  static func validHash(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
  }
  static func isCuratedReleaseURL(_ url: URL) -> Bool {
    guard url.scheme == "https", url.host == "github.com", url.port == nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else { return false }
    let components = url.path.split(separator: "/", omittingEmptySubsequences: false)
    return components.count == 7
      && Array(components.prefix(5)) == ["", "LucaTufariello", "tCode", "releases", "download"]
      && components.suffix(2).allSatisfy { ToolInstaller.validComponent(String($0)) }
  }
}

public enum LanguageCatalogError: LocalizedError {
  case invalid(String)
  case unpublished, badResponse, hashMismatch
  public var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    case .unpublished:
      return
        "This catalog entry is bundled metadata. Its remote release artifact has not been published; use its bundled pack or import a local pack."
    case .badResponse:
      return "The language catalog download failed. Cached language support remains available."
    case .hashMismatch: return "SHA-256 verification failed. The downloaded pack was not activated."
    }
  }
}

/// Catalog refresh is explicit; constructing or reading this store starts no processes or network requests.
public actor LanguageCatalogStore {
  public static var defaultDirectory: URL {
    LanguageSupportPaths.root.appendingPathComponent("LanguageCatalog", isDirectory: true)
  }
  public let directory: URL
  public let remoteURL: URL
  private let bundledCatalogURL: URL?
  private let session: URLSession
  public init(
    directory: URL = LanguageCatalogStore.defaultDirectory, bundledCatalogURL: URL? = nil,
    remoteURL: URL = LanguageCatalog.defaultURL
  ) {
    self.directory = directory
    self.bundledCatalogURL = bundledCatalogURL
    self.remoteURL = remoteURL
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    self.session = URLSession(configuration: config)
  }
  public func cached() throws -> LanguageCatalog {
    let cached = directory.appendingPathComponent("catalog.json")
    for url in [cached, bundledCatalogURL].compactMap({ $0 }) {
      if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 2_000_000,
        let data = try? Data(contentsOf: url), data.count <= 2_000_000,
        let catalog = try? JSONDecoder().decode(LanguageCatalog.self, from: data),
        (try? catalog.validate()) != nil
      {
        return catalog
      }
    }
    return .starter
  }
  public func refresh() async throws -> LanguageCatalog {
    guard LanguageCatalog.isCuratedReleaseURL(remoteURL)
    else {
      throw LanguageCatalogError.invalid(
        "Catalog refresh requires the curated versioned tCode release URL.")
    }
    let data = try await download(remoteURL, maximumBytes: 2_000_000)
    let catalog = try JSONDecoder().decode(LanguageCatalog.self, from: data)
    try catalog.validate()
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
    return catalog
  }
  public func fetchPack(entry: LanguageCatalogEntry) async throws -> Data {
    guard entry.availability == .published, let hash = entry.packSHA256 else {
      throw LanguageCatalogError.unpublished
    }
    try LanguageCatalog(entries: [entry], publication: "verification").validate()
    let data = try await download(entry.packURL, maximumBytes: 1_000_000)
    try Self.validatePack(data, entry: entry, hash: hash)
    try Task.checkCancellation()
    return data
  }
  /// A published update must always use its pinned artifact, never shadow it with older app resources.
  public static func bundledPack(entry: LanguageCatalogEntry, resourceDirectory: URL) throws
    -> Data?
  {
    guard entry.availability == .draft, let filename = entry.bundledFilename else { return nil }
    try LanguageCatalog(entries: [entry], publication: "bundled verification").validate()
    let path = resourceDirectory.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 1_048_577) ?? Data()
    let pack = try LanguagePackRegistry.decode(data)
    guard pack.id == entry.id, pack.version == entry.version else {
      throw LanguageCatalogError.invalid("Bundled configuration does not match its catalog entry.")
    }
    if let hash = entry.packSHA256, sha256(data) != hash.lowercased() {
      throw LanguageCatalogError.hashMismatch
    }
    return data
  }
  static func validatePack(_ data: Data, entry: LanguageCatalogEntry, hash: String) throws {
    guard data.count <= 1_000_000 else { throw LanguageCatalogError.badResponse }
    guard Self.sha256(data) == hash.lowercased() else { throw LanguageCatalogError.hashMismatch }
    let pack = try LanguagePackRegistry.decode(data)
    guard pack.id == entry.id, pack.version == entry.version else {
      throw LanguageCatalogError.invalid(
        "The downloaded pack identity or version does not match its catalog entry.")
    }
  }
  private func download(_ url: URL, maximumBytes: Int) async throws -> Data {
    let (temporary, response) = try await session.download(
      for: URLRequest(url: url), delegate: BoundedCatalogDownload(limit: Int64(maximumBytes)))
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https",
      let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= maximumBytes
    else { throw LanguageCatalogError.badResponse }
    let handle = try FileHandle(forReadingFrom: temporary)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw LanguageCatalogError.badResponse }
    try Task.checkCancellation()
    return data
  }
  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
