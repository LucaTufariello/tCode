import Foundation

private final class BoundedSyntaxDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable
{
  let maximumBytes: Int64
  init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
      downloadTask.cancel()
    }
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}

public struct SyntaxGrammarArtifact: Codable, Equatable, Sendable {
  public let descriptor: SyntaxGrammarDescriptor
  public let url: URL
  public let sha256: String
  public let downloadBytes: Int
  public init(descriptor: SyntaxGrammarDescriptor, url: URL, sha256: String, downloadBytes: Int) {
    self.descriptor = descriptor
    self.url = url
    self.sha256 = sha256
    self.downloadBytes = downloadBytes
  }
}
public struct SyntaxGrammarInstallPlan: Sendable {
  public let items: [SyntaxGrammarArtifact]
  public let destinations: [URL]
  public var downloadBytes: Int { items.reduce(0) { $0 + $1.downloadBytes } }
}

/// Only a curated catalog supplies this installer. User pack imports never contribute recipes or module URLs.
public struct SyntaxGrammarInstaller: Sendable {
  public let root: URL
  public let artifacts: [SyntaxGrammarArtifact]
  private let allowLocalArtifactsForTesting: Bool
  private let localArtifactDirectoryForTesting: URL?
  public init(
    root: URL = SyntaxGrammarStore.defaultRoot, artifacts: [SyntaxGrammarArtifact],
    allowLocalArtifactsForTesting: Bool = false, localArtifactDirectoryForTesting: URL? = nil
  ) {
    self.root = root
    self.artifacts = artifacts
    self.allowLocalArtifactsForTesting = allowLocalArtifactsForTesting
    self.localArtifactDirectoryForTesting =
      allowLocalArtifactsForTesting ? localArtifactDirectoryForTesting : nil
  }
  public func installed(_ id: String) -> Bool {
    guard let artifact = artifacts.first(where: { $0.descriptor.id == id }) else { return false }
    return (try? SyntaxGrammarStore.read(artifact.descriptor, root: root)) != nil
  }
  public func plan(ids: [String]) throws -> SyntaxGrammarInstallPlan {
    var items = [SyntaxGrammarArtifact]()
    for id in Set(ids).sorted() {
      guard let artifact = artifacts.first(where: { $0.descriptor.id == id }) else {
        throw SyntaxFailure.invalidGrammar(
          "No curated grammar artifact for \(id). Refresh the catalog.")
      }
      try artifact.descriptor.validate()
      guard
        (artifact.url.scheme == "https" && artifact.url.host == "github.com"
          && artifact.url.path.hasPrefix("/LucaTufariello/tCode/releases/download/"))
          || (allowLocalArtifactsForTesting && artifact.url.isFileURL),
        artifact.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
        (1...67_108_864).contains(artifact.downloadBytes)
      else {
        throw SyntaxFailure.invalidGrammar("Invalid curated grammar download")
      }
      if !installed(id) { items.append(artifact) }
    }
    return SyntaxGrammarInstallPlan(
      items: items,
      destinations: items.map { SyntaxGrammarStore.directory(for: $0.descriptor, root: root) })
  }
  public func install(
    _ plan: SyntaxGrammarInstallPlan,
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws {
    for item in plan.items {
      try Task.checkCancellation()
      guard artifacts.contains(item) else {
        throw SyntaxFailure.invalidGrammar("The install plan is not from this catalog")
      }
      progress("Downloading \(item.descriptor.id) grammar (\(item.downloadBytes) bytes)…")
      let bytes: Data
      let localURL =
        localArtifactDirectoryForTesting?.appendingPathComponent(item.url.lastPathComponent)
        ?? (allowLocalArtifactsForTesting && item.url.isFileURL ? item.url : nil)
      if let localURL {
        guard
          (try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == item.downloadBytes
        else {
          throw SyntaxFailure.invalidGrammar("Local test artifact size differs from catalog")
        }
        bytes = try Data(contentsOf: localURL)
      } else {
        let (download, response) = try await URLSession.shared.download(
          for: URLRequest(url: item.url),
          delegate: BoundedSyntaxDownload(maximumBytes: Int64(item.downloadBytes)))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
          response.url?.scheme == "https",
          ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
            .contains(response.url?.host ?? "")
        else {
          throw SyntaxFailure.invalidGrammar(
            "Grammar download unavailable. Catalog artifacts may not yet be published; installed support remains available offline."
          )
        }
        guard
          (try download.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == item.downloadBytes
        else {
          throw SyntaxFailure.invalidGrammar("Downloaded archive size differs from catalog")
        }
        bytes = try Data(contentsOf: download)
      }
      try Task.checkCancellation()
      guard bytes.count == item.downloadBytes, SyntaxIntegrity.sha256(bytes) == item.sha256 else {
        throw SyntaxFailure.invalidGrammar("Downloaded archive size or SHA-256 mismatch")
      }
      progress("Verifying \(item.descriptor.id) grammar…")
      let stagingRoot = root.appendingPathComponent(".staging-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: stagingRoot, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: stagingRoot) }
      let archive = stagingRoot.appendingPathComponent("download.tar.gz")
      try bytes.write(to: archive, options: .atomic)
      let listing = try await RunningProcess().run(
        executable: "/usr/bin/tar", arguments: ["-tvzf", archive.path], directory: nil)
      let lines = listing.stdout.split(separator: "\n").map(String.init)
      let expected = Set([
        "descriptor.json", item.descriptor.module, item.descriptor.query, "LICENSE",
      ])
      guard listing.status == 0, lines.count == expected.count,
        lines.allSatisfy({ line in
          let fields = line.split(separator: " ")
          guard line.hasPrefix("-"), fields.count >= 6, let size = Int(fields[4]), size >= 0 else {
            return false
          }
          let limit =
            fields.last.map(String.init) == item.descriptor.module ? 67_108_864 : 1_048_576
          return size <= limit
        }),
        Set(lines.compactMap { $0.split(separator: " ").last.map(String.init) }) == expected
      else {
        throw SyntaxFailure.invalidGrammar(
          "The grammar archive contains unsupported files or links")
      }
      let extracted = stagingRoot.appendingPathComponent("verified")
      try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
      let result = try await RunningProcess().run(
        executable: "/usr/bin/tar",
        arguments: ["-xzf", archive.path, "-C", extracted.path, "--no-same-owner"], directory: nil)
      guard result.status == 0 else {
        throw SyntaxFailure.invalidGrammar("Unable to unpack grammar")
      }
      let decoded = try JSONDecoder().decode(
        SyntaxGrammarDescriptor.self,
        from: Data(contentsOf: extracted.appendingPathComponent("descriptor.json")))
      guard decoded == item.descriptor else {
        throw SyntaxFailure.invalidGrammar("Artifact metadata differs from the curated catalog")
      }
      for name in expected {
        let attributes = try FileManager.default.attributesOfItem(
          atPath: extracted.appendingPathComponent(name).path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
          throw SyntaxFailure.invalidGrammar("Only regular grammar files are supported")
        }
      }
      let module = try Data(contentsOf: extracted.appendingPathComponent(decoded.module))
      try SyntaxIntegrity.validateModule(module, descriptor: decoded)
      let query = try Data(contentsOf: extracted.appendingPathComponent(decoded.query))
      guard query.count <= 1_048_576, SyntaxIntegrity.sha256(query) == decoded.querySHA256 else {
        throw SyntaxFailure.invalidGrammar("Query digest mismatch")
      }
      progress("Validating grammar ABI and queries in the sandboxed syntax service…")
      let validationConnection = SyntaxConnection()
      let validationID = UUID()
      _ = try await validationConnection.highlight(
        SyntaxRequest(
          documentID: validationID, version: 0,
          text: "", grammar: decoded, moduleData: module, queryData: query))
      validationConnection.close(validationID)
      validationConnection.invalidate()
      try Task.checkCancellation()
      let destination = SyntaxGrammarStore.directory(for: decoded, root: root)
      let parent = destination.deletingLastPathComponent()
      let canonicalRoot = root.resolvingSymlinksInPath().path + "/"
      guard parent.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot),
        destination.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot)
      else {
        throw SyntaxFailure.invalidGrammar("Managed grammar path escapes the store")
      }
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let backup = parent.appendingPathComponent(".previous-" + UUID().uuidString)
      let replacing = FileManager.default.fileExists(atPath: destination.path)
      if replacing { try FileManager.default.moveItem(at: destination, to: backup) }
      do {
        try FileManager.default.moveItem(at: extracted, to: destination)
        // Activation changes only after every download and sandbox validation succeeded.
        try JSONEncoder().encode(item).write(
          to: parent.appendingPathComponent("active.json"), options: .atomic)
        if replacing { try? FileManager.default.removeItem(at: backup) }
      } catch {
        try? FileManager.default.removeItem(at: destination)
        if replacing { try? FileManager.default.moveItem(at: backup, to: destination) }
        throw error
      }
      progress("Installed \(decoded.id) grammar \(decoded.version)")
    }
  }
  public func remove(id: String) throws {
    guard artifacts.contains(where: { $0.descriptor.id == id }),
      id.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
    else {
      throw SyntaxFailure.invalidGrammar("Only managed catalog grammars may be removed")
    }
    let directory = root.appendingPathComponent(id)
    guard
      directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    else {
      throw SyntaxFailure.invalidGrammar("Refusing to remove an external directory")
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }
}
