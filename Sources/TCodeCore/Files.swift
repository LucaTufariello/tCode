import Foundation

public enum TCodeError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    if case .message(let message) = self { return message }
    return nil
  }
}

public struct TextFile: Sendable {
  public let text: String
  public let encoding: String.Encoding
  public let bom: Data
  public let bytes: Data
  public var lineEnding: String {
    text.contains("\r\n") ? "CRLF" : text.contains("\r") ? "CR" : "LF"
  }

  public init(data: Data) throws {
    bytes = data
    let candidates: [(Data, String.Encoding)] = [
      (Data([0xEF, 0xBB, 0xBF]), .utf8), (Data([0xFF, 0xFE]), .utf16LittleEndian),
      (Data([0xFE, 0xFF]), .utf16BigEndian),
    ]
    if let (prefix, enc) = candidates.first(where: { data.starts(with: $0.0) }) {
      guard let string = String(data: data.dropFirst(prefix.count), encoding: enc) else {
        throw TCodeError.message("The text encoding is invalid.")
      }
      text = string
      encoding = enc
      bom = prefix
    } else {
      guard !data.contains(0), let string = String(data: data, encoding: .utf8) else {
        throw TCodeError.message(
          "This is a binary file or an unsupported text encoding. It has not been opened for editing."
        )
      }
      text = string
      encoding = .utf8
      bom = Data()
    }
  }
  public func encode(_ value: String) throws -> Data {
    guard let data = value.data(using: encoding, allowLossyConversion: false) else {
      throw TCodeError.message("The selected encoding cannot represent this text.")
    }
    return bom + data
  }
}

public enum FileIO {
  public static let exclusions: Set<String> = [
    ".git", ".build", "build", "node_modules", ".venv", "venv", "__pycache__", "DerivedData",
    ".tools",
  ]
  public static func validate(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
      !name.contains("\0"), !name.contains("\n")
    else {
      throw TCodeError.message("Use a nonempty filename without slash, colon, newline, or NUL.")
    }
  }
  public static func children(_ folder: URL, excluding: Set<String> = exclusions) throws
    -> [FileEntry]
  {
    try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
    )
    .filter { !excluding.contains($0.lastPathComponent) }
    .map { url in
      let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      return FileEntry(
        url: url, directory: v.isDirectory == true, symlink: v.isSymbolicLink == true)
    }.sorted {
      $0.directory != $1.directory
        ? $0.directory
        : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
          == .orderedAscending
    }
  }
  @discardableResult public static func create(in folder: URL, name: String, directory: Bool) throws
    -> URL
  {
    try validate(name)
    let destination = folder.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw TCodeError.message("An item named \(name) already exists.")
    }
    if directory {
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    } else {
      try Data().write(to: destination, options: .withoutOverwriting)
    }
    return destination
  }
  @discardableResult public static func move(_ url: URL, into parent: URL, name: String) throws
    -> URL
  {
    try validate(name)
    let destination = parent.appendingPathComponent(name)
    guard destination.standardizedFileURL != url.standardizedFileURL else { return url }
    guard !parent.resolvingSymlinksInPath().path.hasPrefix(url.resolvingSymlinksInPath().path + "/")
    else { throw TCodeError.message("A folder cannot be moved inside itself.") }
    try FileManager.default.moveItem(at: url, to: destination)
    return destination
  }
  public static func save(_ data: Data, to url: URL, expected: Data?, allowOverwrite: Bool = false)
    throws
  {
    let target = url.resolvingSymlinksInPath()
    let actual = try? Data(contentsOf: target)
    if !allowOverwrite && actual != expected {
      throw TCodeError.message("The file changed on disk. Compare or reload it before saving.")
    }
    let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[
      .posixPermissions]
    try data.write(to: target, options: .atomic)
    if let permissions {
      try FileManager.default.setAttributes(
        [.posixPermissions: permissions], ofItemAtPath: target.path)
    }
  }
  public static func indexedFiles(
    _ root: URL, excluding: Set<String> = exclusions, limit: Int = 50000
  ) throws -> [URL] {
    guard
      let e = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
    else { return [] }
    var result: [URL] = []
    for case let url as URL in e {
      if Task<Never, Never>.isCancelled { throw CancellationError() }
      let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if excluding.contains(url.lastPathComponent) || v.isSymbolicLink == true {
        e.skipDescendants()
        continue
      }
      if v.isDirectory != true { result.append(url) }
      if result.count >= limit { break }
    }
    return result
  }
}

public struct FileEntry: Sendable {
  public let url: URL
  public let directory: Bool
  public let symlink: Bool
}

public struct RecoveryRecord: Codable, Sendable {
  public var id: UUID
  public var path: String?
  public var text: String
  public var baseline: Data?
  public var encoding: UInt
  public var bom: Data
  public init(
    id: UUID, path: String?, text: String, baseline: Data?,
    encoding: UInt = String.Encoding.utf8.rawValue, bom: Data = Data()
  ) {
    self.id = id
    self.path = path
    self.text = text
    self.baseline = baseline
    self.encoding = encoding
    self.bom = bom
  }
}

public actor RecoveryStore {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }
  public func write(_ record: RecoveryRecord) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(record.id.uuidString + ".json")
    try JSONEncoder().encode(record).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  public func remove(_ id: UUID) throws {
    let u = directory.appendingPathComponent(id.uuidString + ".json")
    if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
  }
  public func read() throws -> [RecoveryRecord] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.map {
      try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: $0))
    }
  }
}
