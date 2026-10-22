import Foundation

public struct LanguagePackIssue: Equatable, Sendable, Identifiable {
  public var id: String { source + message }
  public var source: String
  public var message: String
  public init(source: String, message: String) {
    self.source = source
    self.message = message
  }
}

/// Atomic user-pack activation. A malformed replacement cannot erase a working pack.
public final class LanguagePackRegistry: @unchecked Sendable {
  private struct Activation: Codable {
    let id: String
    let version: String
    let sha256: String
  }
  public static var supportDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["TCODE_SUPPORT_DIRECTORY"] {
      return URL(fileURLWithPath: path)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/tCode", isDirectory: true)
  }
  public static var defaultDirectory: URL {
    supportDirectory.appendingPathComponent("LanguagePacks", isDirectory: true)
  }
  public let directory: URL
  private let bundled: [LanguagePack]
  private let lock = NSRecursiveLock()
  private var current: [LanguagePack] = []
  private var errors: [LanguagePackIssue] = []
  private var lastGood: [String: LanguagePack] = [:]
  private var activeWorkspace: URL?
  private var workspacePacksEnabled = false
  public var packs: [LanguagePack] {
    lock.lock()
    defer { lock.unlock() }
    return current
  }
  public var issues: [LanguagePackIssue] {
    lock.lock()
    defer { lock.unlock() }
    return errors
  }
  public init(directory: URL = defaultDirectory, bundledPacks: [LanguagePack]) {
    self.directory = directory
    self.bundled = bundledPacks
    _ = reload()
  }
  @discardableResult public func reload(workspace: URL? = nil, allowWorkspacePacks: Bool = false)
    -> [LanguagePack]
  {
    lock.lock()
    defer { lock.unlock() }
    activeWorkspace = workspace
    workspacePacksEnabled = allowWorkspacePacks
    errors = []
    var values = Dictionary(bundled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var folders = [directory]
    if allowWorkspacePacks, let workspace {
      folders.append(workspace.appendingPathComponent(".tcode/languages", isDirectory: true))
    }
    for folder in folders {
      guard FileManager.default.fileExists(atPath: folder.path) else { continue }
      do {
        let files = try FileManager.default.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { $0.pathExtension == "json" }.sorted {
          $0.lastPathComponent < $1.lastPathComponent
        }
        var seen = Set<String>()
        if files.count > 512 {
          errors.append(
            .init(
              source: folder.path,
              message: "Only the first 512 language pack files are loaded from a directory."))
        }
        for file in files.prefix(512) {
          let source = file.path
          do {
            let attributes = try file.resourceValues(forKeys: [
              .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
              throw TCodeError.message("Language pack must be a regular file.")
            }
            guard (attributes.fileSize ?? Int.max) <= 1_048_576 else {
              throw TCodeError.message("Language pack exceeds the 1 MB configuration limit.")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            // Retain the decode limit even if a file grows after its size was inspected.
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            let pack = try Self.decode(data)
            guard seen.insert(pack.id).inserted else {
              throw TCodeError.message("Duplicate pack id \(pack.id) in this directory.")
            }
            values[pack.id] = pack
            lastGood[source] = pack
          } catch {
            errors.append(.init(source: source, message: error.localizedDescription))
            let previous = lastGood[source] ?? restoredUserPack(file: file, folder: folder)
            if let previous, seen.insert(previous.id).inserted {
              values[previous.id] = previous
            }
          }
        }
      } catch { errors.append(.init(source: folder.path, message: error.localizedDescription)) }
    }
    current = values.values.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    return current
  }
  public static func decode(_ data: Data) throws -> LanguagePack {
    guard data.count <= 1_048_576 else {
      throw TCodeError.message("Language pack exceeds the 1 MB configuration limit.")
    }
    return try JSONDecoder().decode(LanguagePack.self, from: data)
  }
  @discardableResult public func importPack(data: Data, replace: Bool = false) throws
    -> LanguagePack
  {
    let pack = try Self.decode(data)
    lock.lock()
    defer { lock.unlock() }
    let target = directory.appendingPathComponent(pack.id + ".json")
    if FileManager.default.fileExists(atPath: target.path), !replace {
      throw TCodeError.message("\(pack.name) is already installed. Choose Replace to update it.")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try encoder.encode(pack)
    let history = try prepareHistory(pack: pack, data: encoded)
    let prior = try? Self.readBounded(target, limit: 1_048_576)
    let priorActivation = try? Self.readBounded(history.active, limit: 4_096)
    do {
      try encoded.write(to: target, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      try history.activation.write(to: history.active, options: .atomic)
    } catch {
      if let prior {
        try? prior.write(to: target, options: .atomic)
      } else {
        try? FileManager.default.removeItem(at: target)
      }
      if let priorActivation {
        try? priorActivation.write(to: history.active, options: .atomic)
      } else {
        try? FileManager.default.removeItem(at: history.active)
      }
      throw error
    }
    pruneHistory(id: pack.id, keeping: history.versionDirectory)
    _ = reload(workspace: activeWorkspace, allowWorkspacePacks: workspacePacksEnabled)
    return pack
  }
  public func exportPack(id: String) throws -> Data {
    guard let pack = packs.first(where: { $0.id == id }) else {
      throw TCodeError.message("Language pack is not installed.")
    }
    return try pack.portableData()
  }
  public func isUserInstalled(id: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(id + ".json").path)
  }
  public func removePack(id: String) throws {
    try FileIO.validate(id)
    guard id.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$"#, options: .regularExpression) != nil
    else { throw TCodeError.message("Invalid pack identifier.") }
    lock.lock()
    defer { lock.unlock() }
    let file = directory.appendingPathComponent(id + ".json")
    guard isUserInstalled(id: id) else {
      throw TCodeError.message("Bundled defaults cannot be removed. Disable the pack instead.")
    }
    try removeHistory(id: id)
    try FileManager.default.removeItem(at: file)
    lastGood.removeValue(forKey: file.path)
    _ = reload(workspace: activeWorkspace, allowWorkspacePacks: workspacePacksEnabled)
  }
  private static func readBounded(_ url: URL, limit: Int) throws -> Data {
    let attributes = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
      (attributes.fileSize ?? Int.max) <= limit
    else { throw TCodeError.message("Invalid or oversized language configuration history.") }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else {
      throw TCodeError.message("Language configuration history exceeds its size limit.")
    }
    return data
  }
  private func historyRoot(id: String) -> URL {
    directory.appendingPathComponent("versions/" + id, isDirectory: true)
  }
  private func prepareHistory(pack: LanguagePack, data: Data) throws -> (
    active: URL, activation: Data, versionDirectory: URL
  ) {
    let hash = LanguageCatalogStore.sha256(data)
    let root = historyRoot(id: pack.id)
    guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path
    else {
      throw TCodeError.message("A symbolic link cannot be used for language configuration history.")
    }
    let version = root.appendingPathComponent(pack.version + "-" + hash, isDirectory: true)
    try FileManager.default.createDirectory(
      at: version, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard
      version.standardizedFileURL.path == version.resolvingSymlinksInPath().standardizedFileURL.path
    else {
      throw TCodeError.message("A symbolic link cannot be used for language configuration history.")
    }
    let path = version.appendingPathComponent("pack.json")
    if (try? Self.readBounded(path, limit: 1_048_576)) != data {
      try data.write(to: path, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    let activation = try JSONEncoder().encode(
      Activation(id: pack.id, version: pack.version, sha256: hash))
    return (root.appendingPathComponent("active.json"), activation, version)
  }
  private func restoredUserPack(file: URL, folder: URL) -> LanguagePack? {
    // Workspace overrides never use user history, and deleted configurations are not resurrected.
    guard folder.standardizedFileURL == directory.standardizedFileURL,
      file.lastPathComponent == file.deletingPathExtension().lastPathComponent + ".json"
    else { return nil }
    let id = file.deletingPathExtension().lastPathComponent
    let root = historyRoot(id: id)
    guard ToolInstaller.validComponent(id),
      root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
      let data = try? Self.readBounded(
        historyRoot(id: id).appendingPathComponent("active.json"), limit: 4_096),
      let active = try? JSONDecoder().decode(Activation.self, from: data), active.id == id,
      ToolInstaller.validComponent(active.version), LanguageCatalog.validHash(active.sha256),
      let bytes = try? Self.readBounded(
        historyRoot(id: id).appendingPathComponent(
          active.version + "-" + active.sha256 + "/pack.json"), limit: 1_048_576),
      LanguageCatalogStore.sha256(bytes) == active.sha256,
      let pack = try? Self.decode(bytes), pack.id == active.id, pack.version == active.version
    else { return nil }
    return pack
  }
  private func pruneHistory(id: String, keeping active: URL) {
    let root = historyRoot(id: id)
    let versions =
      ((try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [])
      .filter { ownedHistory($0, id: id) }
      .sorted {
        ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
          > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
      }
    for version in versions.dropFirst(16) where version != active {
      try? FileManager.default.removeItem(at: version)
    }
  }
  private func ownedHistory(_ version: URL, id: String) -> Bool {
    guard
      version.standardizedFileURL.deletingLastPathComponent()
        == historyRoot(id: id).standardizedFileURL,
      version.standardizedFileURL.path
        == version.resolvingSymlinksInPath().standardizedFileURL.path,
      let bytes = try? Self.readBounded(
        version.appendingPathComponent("pack.json"), limit: 1_048_576),
      let pack = try? Self.decode(bytes), pack.id == id
    else { return false }
    return version.lastPathComponent == pack.version + "-" + LanguageCatalogStore.sha256(bytes)
  }
  private func removeHistory(id: String) throws {
    let root = historyRoot(id: id)
    guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path
    else { return }
    for version
      in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? [] where ownedHistory(version, id: id)
    {
      try FileManager.default.removeItem(at: version)
    }
    // This bounded pointer refers only to tCode's own versioned configuration data.
    let active = root.appendingPathComponent("active.json")
    if let bytes = try? Self.readBounded(active, limit: 4_096),
      let value = try? JSONDecoder().decode(Activation.self, from: bytes), value.id == id
    {
      try FileManager.default.removeItem(at: active)
    }
    if (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
