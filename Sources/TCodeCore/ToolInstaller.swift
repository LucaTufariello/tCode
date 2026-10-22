import CryptoKit
import Foundation

private final class BoundedToolDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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

public struct ToolDownload: Codable, Equatable, Sendable {
  public let url: URL
  public let sha256: String
  public let filename: String
  public let size: Int
  public init(url: URL, sha256: String, filename: String, size: Int = 0) {
    self.url = url
    self.sha256 = sha256
    self.filename = filename
    self.size = size
  }
}
public struct ToolPrerequisite: Codable, Sendable {
  public let name: String
  public let detail: String
  public let satisfied: Bool
  public init(name: String, detail: String, satisfied: Bool) {
    self.name = name
    self.detail = detail
    self.satisfied = satisfied
  }
}
public struct ToolInstallPlan: Codable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let version: String
  public let downloads: [ToolDownload]
  public let prerequisites: [ToolPrerequisite]
  public let expectedChanges: [String]
  public let unavailableReason: String?
  public var canInstall: Bool { unavailableReason == nil && prerequisites.allSatisfy(\.satisfied) }
  public var downloadBytes: Int { downloads.reduce(0) { $0 + $1.size } }
}
public struct ToolInstallProgress: Sendable {
  public enum Phase: String, Sendable {
    case checking, downloading, verifying, installing, validating, activating, complete
  }
  public let phase: Phase
  public let fraction: Double
  public let message: String
  public init(phase: Phase, fraction: Double, message: String) {
    self.phase = phase
    self.fraction = fraction
    self.message = message
  }
}
public struct ToolInstallReceipt: Codable, Sendable {
  public let recipeID: String
  public let version: String
  public let installedAt: Date
  public let managedDirectory: String?
  public let executables: [String: String]
  public let owned: Bool
}

/// Only native, curated recipes are executable. Language packs reference their IDs, never scripts.
public struct ToolRecipe: Sendable {
  public enum Kind: String, Sendable { case external, pythonEnvironment, gzipExecutable, tarGzip }
  public let id: String
  public let name: String
  public let version: String
  public let kind: Kind
  public let downloads: [ToolDownload]
  /// Tool name to relative executable path inside an installation. For external recipes, only names are used.
  public let executables: [String: String]
  public let probeArguments: [String: [String]]
  public let requireArm64: Bool
  public let guidance: String
  public let prerequisiteTools: [String]
  public init(
    id: String, name: String, version: String, kind: Kind, downloads: [ToolDownload] = [],
    executables: [String: String], probeArguments: [String: [String]] = [:],
    requireArm64: Bool = true, guidance: String = "", prerequisiteTools: [String] = []
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.kind = kind
    self.downloads = downloads
    self.executables = executables
    self.probeArguments = probeArguments
    self.requireArm64 = requireArm64
    self.guidance = guidance
    self.prerequisiteTools = prerequisiteTools
  }
  public static var curated: [ToolRecipe] {
    [
      .init(
        id: "python-tools", name: "Python language tools", version: "2026.10.21",
        kind: .pythonEnvironment,
        downloads: PythonWheelLock.downloads.filter { !$0.filename.hasPrefix("clang_format-") },
        executables: [
          "pylsp": "bin/pylsp", "ruff": "bin/ruff", "black": "bin/black", "pytest": "bin/pytest",
          "debugpy": "bin/debugpy", "python3": "bin/python3",
        ],
        guidance:
          "Install CPython 3.12 from python.org or Homebrew. tCode creates its own isolated tool environment; project environments are left untouched."
      ),
      .init(
        id: "clang-format", name: "clang-format", version: "23.1.3", kind: .pythonEnvironment,
        downloads: PythonWheelLock.downloads.filter { $0.filename.hasPrefix("clang_format-") },
        executables: ["clang-format": "bin/clang-format"],
        guidance:
          "Install CPython 3.12 to create an isolated clang-format environment, or configure an existing working clang-format executable."
      ),
      .init(
        id: "rust-analyzer", name: "rust-analyzer", version: "2026-10-19", kind: .gzipExecutable,
        downloads: [
          ToolDownload(
            url: URL(
              string:
                "https://github.com/rust-lang/rust-analyzer/releases/download/2026-10-19/rust-analyzer-aarch64-apple-darwin.gz"
            )!, sha256: "eedad08a96f7bf92afd0890463787337d17591ea2e3df216033c6bc3ccc9d802",
            filename: "rust-analyzer.gz", size: 14_071_674)
        ], executables: ["rust-analyzer": "bin/rust-analyzer"],
        guidance:
          "Install an external Rust toolchain, then add rust-src with rustup component add rust-src. tCode manages rust-analyzer independently.",
        prerequisiteTools: ["rustc", "cargo"]),
      .init(
        id: "rust-toolchain", name: "Rust toolchain", version: "external", kind: .external,
        executables: ["rustc": "rustc", "cargo": "cargo", "rustfmt": "rustfmt"],
        guidance:
          "Install Rust from rustup.rs, then run rustup component add rustfmt rust-src. tCode does not install or remove your Rust toolchain."
      ),
      .init(
        id: "xcode-tools", name: "Xcode language tools", version: "external", kind: .external,
        executables: [
          "clangd": "clangd", "sourcekit-lsp": "sourcekit-lsp", "lldb-dap": "lldb-dap",
          "swift": "swift",
        ],
        probeArguments: ["sourcekit-lsp": ["--help"]],
        guidance:
          "Install Xcode, select its developer directory, accept its license, and install its command-line tools. tCode does not install or remove Xcode."
      ),
    ]
  }
}

public enum ToolInstallError: LocalizedError {
  case invalid(String)
  case prerequisites(String)
  case declined, busy
  case download(String)
  case checksum(String)
  case process(String)
  case unsafePath
  case badArchitecture(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let detail): return detail
    case .prerequisites(let detail): return detail
    case .declined: return "Installation was not approved. No tools were changed."
    case .busy: return "An installation is already running."
    case .download(let detail):
      return "Download failed: \(detail). The active tool version was retained."
    case .checksum(let name):
      return "SHA-256 verification failed for \(name). The active tool version was retained."
    case .process(let detail): return detail
    case .unsafePath: return "An unsafe installation or archive path was rejected."
    case .badArchitecture(let tool): return "\(tool) is not a native binary supporting arm64."
    }
  }
}

/// Receipt lookup does not execute tools. Actual health checks run only on explicit validation/setup.
public enum ManagedToolPaths {
  public static func resolve(name: String, directory: URL = ToolInstaller.defaultDirectory)
    -> String?
  {
    let fm = FileManager.default
    guard
      let receipts = try? fm.contentsOfDirectory(
        at: directory.appendingPathComponent("receipts"), includingPropertiesForKeys: nil)
    else { return nil }
    for url in receipts.sorted(by: { $0.path < $1.path }) where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
        let receipt = try? JSONDecoder().decode(ToolInstallReceipt.self, from: data),
        ToolInstaller.validComponent(receipt.recipeID),
        let path = receipt.executables[name], fm.isExecutableFile(atPath: path)
      else { continue }
      if receipt.owned {
        guard let managed = receipt.managedDirectory,
          ToolInstaller.isManagedVersion(
            URL(fileURLWithPath: managed), recipeID: receipt.recipeID, directory: directory),
          ToolInstaller.isDescendant(
            URL(fileURLWithPath: path).resolvingSymlinksInPath(),
            of: URL(fileURLWithPath: managed).resolvingSymlinksInPath()) || name == "python3"
        else { continue }
      }
      return path
    }
    return nil
  }
}

public actor ToolInstaller {
  public static var defaultDirectory: URL {
    LanguageSupportPaths.root.appendingPathComponent("ManagedTools", isDirectory: true)
  }
  public let directory: URL
  private let recipes: [String: ToolRecipe]
  private let allowLocalArtifactsForTesting: Bool
  private let preferExistingTools: Bool
  private let session: URLSession
  private var installing = false
  public init(
    directory: URL = ToolInstaller.defaultDirectory, recipes: [ToolRecipe] = ToolRecipe.curated,
    allowLocalArtifactsForTesting: Bool = false, preferExistingTools: Bool = true
  ) {
    self.directory = directory.resolvingSymlinksInPath()
    self.recipes = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
    self.allowLocalArtifactsForTesting = allowLocalArtifactsForTesting
    self.preferExistingTools = preferExistingTools
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 600
    self.session = URLSession(configuration: config)
  }
  public static func validComponent(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 100 && value != "." && value != ".."
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
      }
  }
  public static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    candidate.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
  }
  /// A receipt owns one immediate version directory for its own recipe, never a shared parent or symlink target.
  static func isManagedVersion(_ candidate: URL, recipeID: String, directory: URL) -> Bool {
    guard validComponent(recipeID) else { return false }
    let root = directory.resolvingSymlinksInPath().appendingPathComponent("versions/" + recipeID)
    return candidate.standardizedFileURL.deletingLastPathComponent().path == root.path
      && candidate.standardizedFileURL.path
        == candidate.resolvingSymlinksInPath().standardizedFileURL.path
      && validComponent(candidate.lastPathComponent)
  }
  private func checkedRecipe(_ id: String) throws -> ToolRecipe {
    guard let recipe = recipes[id], Self.validComponent(id), Self.validComponent(recipe.version)
    else {
      throw ToolInstallError.invalid(
        "Unknown or invalid curated tool recipe: \(id). Imported packs cannot supply installation commands."
      )
    }
    for (name, relative) in recipe.executables {
      guard Self.validComponent(name), !relative.isEmpty, !relative.hasPrefix("/"),
        relative.split(separator: "/").allSatisfy({ Self.validComponent(String($0)) })
      else { throw ToolInstallError.unsafePath }
    }
    for item in recipe.downloads {
      guard Self.validComponent(item.filename), LanguageCatalog.validHash(item.sha256),
        item.url.scheme == "https" || (allowLocalArtifactsForTesting && item.url.isFileURL)
      else { throw ToolInstallError.invalid("Invalid pinned download in recipe \(id).") }
    }
    return recipe
  }
  private func existing(_ recipe: ToolRecipe) async -> [String: String]? {
    guard preferExistingTools || recipe.kind == .external else { return nil }
    var paths: [String: String] = [:]
    for name in recipe.executables.keys.sorted() {
      guard let path = ToolLocator.find(name),
        (await ToolHealth.check(
          executable: path, arguments: recipe.probeArguments[name] ?? ["--version"])).isHealthy
      else { return nil }
      paths[name] = path
    }
    return paths
  }
  private func python312() async -> String? {
    for name in ["python3.12", "python3"] {
      guard let path = ToolLocator.find(name) else { continue }
      let report = await ToolHealth.check(executable: path)
      if report.isHealthy, report.version?.hasPrefix("Python 3.12.") == true { return path }
    }
    return nil
  }
  public func plan(recipeID: String) async throws -> ToolInstallPlan {
    let recipe = try checkedRecipe(recipeID)
    if let paths = await existing(recipe) {
      try Task.checkCancellation()
      return ToolInstallPlan(
        id: recipe.id, name: recipe.name, version: recipe.version, downloads: [], prerequisites: [],
        expectedChanges: ["Reuse healthy existing tools:"]
          + paths.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" },
        unavailableReason: nil)
    }
    var prerequisites: [ToolPrerequisite] = []
    if recipe.kind == .pythonEnvironment {
      let python = await python312()
      prerequisites.append(
        .init(name: "CPython 3.12", detail: python ?? recipe.guidance, satisfied: python != nil))
    }
    for tool in recipe.prerequisiteTools {
      let report =
        if let path = ToolLocator.find(tool) { await ToolHealth.check(executable: path) } else {
          ToolHealthReport(executable: tool, status: .missing, detail: recipe.guidance)
        }
      prerequisites.append(
        .init(
          name: tool, detail: report.isHealthy ? (report.version ?? tool) : recipe.guidance,
          satisfied: report.isHealthy))
    }
    let unavailable = recipe.kind == .external ? recipe.guidance : nil
    try Task.checkCancellation()
    return ToolInstallPlan(
      id: recipe.id, name: recipe.name, version: recipe.version, downloads: recipe.downloads,
      prerequisites: prerequisites,
      expectedChanges: [
        "Install version \(recipe.version) inside \(directory.path).",
        "Activate only after SHA-256, architecture, and executable health checks pass.",
        "Keep the previous working version until the new version is validated.", recipe.guidance,
      ], unavailableReason: unavailable)
  }
  public func receipts() throws -> [ToolInstallReceipt] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("receipts"), includingPropertiesForKeys: nil)) ?? []
    return urls.filter { $0.pathExtension == "json" }.compactMap {
      try? JSONDecoder().decode(ToolInstallReceipt.self, from: Data(contentsOf: $0))
    }
  }
  public func resolve(tool: String) throws -> String? {
    ManagedToolPaths.resolve(name: tool, directory: directory)
  }
  public func install(
    _ plan: ToolInstallPlan, approval: @escaping @Sendable (ToolInstallPlan) async -> Bool,
    progress: @escaping @Sendable (ToolInstallProgress) -> Void = { _ in }
  ) async throws -> ToolInstallReceipt {
    guard !installing else { throw ToolInstallError.busy }
    let recipe = try checkedRecipe(plan.id)
    guard recipe.version == plan.version,
      plan.downloads.isEmpty || plan.downloads == recipe.downloads
    else {
      throw ToolInstallError.invalid(
        "The installation plan does not match the curated recipe. Generate a fresh plan.")
    }
    guard plan.canInstall else {
      throw ToolInstallError.prerequisites(
        plan.unavailableReason
          ?? plan.prerequisites.filter { !$0.satisfied }.map(\.detail).joined(separator: "\n"))
    }
    installing = true
    defer { installing = false }
    guard await approval(plan) else { throw ToolInstallError.declined }
    try Task.checkCancellation()
    progress(.init(phase: .checking, fraction: 0, message: "Checking existing tools"))
    if let paths = await existing(recipe) {
      try Task.checkCancellation()
      let receipt = ToolInstallReceipt(
        recipeID: recipe.id, version: recipe.version, installedAt: Date(), managedDirectory: nil,
        executables: paths, owned: false)
      try write(receipt)
      progress(.init(phase: .complete, fraction: 1, message: "Reusing validated existing tools"))
      return receipt
    }
    try Task.checkCancellation()
    guard !plan.downloads.isEmpty || recipe.downloads.isEmpty else {
      throw ToolInstallError.invalid(
        "Previously detected tools are no longer healthy. Generate a new installation plan to review downloads before installing."
      )
    }
    guard recipe.kind != .external else { throw ToolInstallError.prerequisites(recipe.guidance) }
    let fresh = try await self.plan(recipeID: recipe.id)
    guard fresh.canInstall else { throw ToolInstallError.prerequisites(recipe.guidance) }
    let fm = FileManager.default
    let versionRoot = directory.appendingPathComponent("versions/\(recipe.id)", isDirectory: true)
    let candidate = versionRoot.appendingPathComponent(
      recipe.version + "-" + UUID().uuidString, isDirectory: true)
    try safeCreate(directory)
    try safeCreate(versionRoot)
    try fm.createDirectory(
      at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var activated = false
    defer { if !activated { try? fm.removeItem(at: candidate) } }
    let downloads = candidate.appendingPathComponent(".downloads", isDirectory: true)
    try fm.createDirectory(at: downloads, withIntermediateDirectories: false)
    for (index, item) in recipe.downloads.enumerated() {
      try Task.checkCancellation()
      let fraction = Double(index) / Double(max(1, recipe.downloads.count)) * 0.55
      progress(
        .init(phase: .downloading, fraction: fraction, message: "Downloading \(item.filename)"))
      let target = downloads.appendingPathComponent(item.filename)
      try await download(item, to: target)
      progress(
        .init(
          phase: .verifying, fraction: fraction + 0.02,
          message: "Verified SHA-256: \(item.filename)"))
    }
    progress(.init(phase: .installing, fraction: 0.6, message: "Preparing isolated installation"))
    switch recipe.kind {
    case .pythonEnvironment:
      guard let python = await python312() else {
        throw ToolInstallError.prerequisites(recipe.guidance)
      }
      _ = try await command(python, ["-m", "venv", candidate.path], directory: nil)
      let wheels = recipe.downloads.map { downloads.appendingPathComponent($0.filename).path }
      _ = try await command(
        candidate.appendingPathComponent("bin/python3").path,
        ["-m", "pip", "install", "--disable-pip-version-check", "--no-index", "--no-deps"] + wheels,
        directory: candidate)
      _ = try await command(
        candidate.appendingPathComponent("bin/python3").path, ["-m", "pip", "check"],
        directory: candidate)
    case .gzipExecutable:
      guard recipe.downloads.count == 1, let item = recipe.downloads.first,
        item.filename.hasSuffix(".gz"), recipe.executables.count == 1,
        let relative = recipe.executables.values.first
      else { throw ToolInstallError.invalid("Invalid gzip recipe.") }
      let compressed = downloads.appendingPathComponent(item.filename)
      _ = try await command("/usr/bin/gzip", ["-d", compressed.path], directory: downloads)
      let unpacked = compressed.deletingPathExtension()
      let executable = candidate.appendingPathComponent(relative)
      try fm.createDirectory(
        at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.moveItem(at: unpacked, to: executable)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    case .tarGzip:
      for item in recipe.downloads {
        try await unpack(downloads.appendingPathComponent(item.filename), to: candidate)
      }
    case .external: break
    }
    try Task.checkCancellation()
    progress(
      .init(
        phase: .validating, fraction: 0.8, message: "Checking executable health and architecture"))
    var paths: [String: String] = [:]
    for (name, relative) in recipe.executables {
      let path = candidate.appendingPathComponent(relative)
      guard Self.isDescendant(path, of: candidate) else { throw ToolInstallError.unsafePath }
      if recipe.requireArm64 && recipe.kind != .pythonEnvironment { try await checkArm64(path) }
      let report = await ToolHealth.check(
        executable: path.path, arguments: recipe.probeArguments[name] ?? ["--version"])
      guard report.isHealthy else {
        throw ToolInstallError.process(
          "Installed \(name) failed its health check: \(report.detail)")
      }
      paths[name] = path.path
    }
    if recipe.requireArm64 && recipe.kind == .pythonEnvironment {
      if let iterator = fm.enumerator(
        at: candidate, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
      ) {
        for file in iterator.allObjects.compactMap({ $0 as? URL }) {
          try Task.checkCancellation()
          // Check every Mach-O (including extensionless Ruff binaries), while allowing Python scripts/data.
          guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
          let magic = (try? handle.read(upToCount: 4)) ?? Data()
          try? handle.close()
          let nativeMagic: [Data] = [
            Data([0xCF, 0xFA, 0xED, 0xFE]), Data([0xFE, 0xED, 0xFA, 0xCF]),
            Data([0xCA, 0xFE, 0xBA, 0xBE]), Data([0xBE, 0xBA, 0xFE, 0xCA]),
          ]
          if nativeMagic.contains(magic) || ["so", "dylib"].contains(file.pathExtension) {
            try await checkArm64(file)
          }
        }
      }
    }
    try? fm.removeItem(at: downloads)
    try Task.checkCancellation()
    progress(.init(phase: .activating, fraction: 0.95, message: "Activating validated version"))
    try Task.checkCancellation()
    let receipt = ToolInstallReceipt(
      recipeID: recipe.id, version: recipe.version, installedAt: Date(),
      managedDirectory: candidate.path, executables: paths, owned: true)
    // Keep ownership metadata for each previously activated version as well as the active receipt.
    try JSONEncoder().encode(receipt).write(
      to: candidate.appendingPathComponent(".tcode-owned.json"), options: .atomic)
    try write(receipt)
    activated = true
    progress(.init(phase: .complete, fraction: 1, message: "\(recipe.name) is ready"))
    return receipt
  }
  private func safeCreate(_ url: URL) throws {
    guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    else { throw ToolInstallError.unsafePath }
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  private func write(_ receipt: ToolInstallReceipt) throws {
    let folder = directory.appendingPathComponent("receipts", isDirectory: true)
    try safeCreate(folder)
    let data = try JSONEncoder().encode(receipt)
    try data.write(to: folder.appendingPathComponent(receipt.recipeID + ".json"), options: .atomic)
  }
  private func download(_ item: ToolDownload, to target: URL) async throws {
    let fm = FileManager.default
    if item.url.isFileURL && allowLocalArtifactsForTesting {
      try fm.copyItem(at: item.url, to: target)
    } else {
      do {
        let delegate = BoundedToolDownload(
          maximumBytes: Int64(item.size > 0 ? item.size : 512_000_000))
        let (temporary, response) = try await session.download(
          for: URLRequest(url: item.url), delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
          response.url?.scheme == "https"
        else { throw ToolInstallError.download(item.filename) }
        try fm.moveItem(at: temporary, to: target)
      } catch is CancellationError { throw CancellationError() } catch {
        if Task.isCancelled { throw CancellationError() }
        throw ToolInstallError.download(error.localizedDescription)
      }
    }
    try Task.checkCancellation()
    let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 512_000_000, item.size == 0 || size == item.size else {
      throw ToolInstallError.download("Unexpected download size for \(item.filename)")
    }
    var digest = SHA256()
    let handle = try FileHandle(forReadingFrom: target)
    defer { try? handle.close() }
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      digest.update(data: data)
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard hash == item.sha256.lowercased() else { throw ToolInstallError.checksum(item.filename) }
  }
  private func command(_ executable: String, _ arguments: [String], directory: URL?) async throws
    -> ProcessResult
  {
    let result = try await RunningProcess().run(
      executable: executable, arguments: arguments, directory: directory)
    try Task.checkCancellation()
    guard result.status == 0 else {
      throw ToolInstallError.process(String(result.output.suffix(8000)))
    }
    return result
  }
  private func checkArm64(_ path: URL) async throws {
    let result = try await RunningProcess().run(
      executable: "/usr/bin/lipo", arguments: ["-verify_arch", "arm64", path.path], directory: nil)
    try Task.checkCancellation()
    guard result.status == 0 else { throw ToolInstallError.badArchitecture(path.lastPathComponent) }
  }
  private func unpack(_ archive: URL, to destination: URL) async throws {
    let listing = try await command("/usr/bin/tar", ["-tzf", archive.path], directory: nil)
    for path in listing.stdout.split(separator: "\n").map(String.init) {
      let components = path.split(separator: "/").filter { $0 != "." }
      guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\r"),
        components.allSatisfy({ $0 != ".." }), components.first != ".downloads"
      else { throw ToolInstallError.unsafePath }
    }
    let verbose = try await command("/usr/bin/tar", ["-tvzf", archive.path], directory: nil)
    for row in verbose.stdout.split(separator: "\n") {
      guard row.first == "-" || row.first == "d" else { throw ToolInstallError.unsafePath }
    }
    _ = try await command(
      "/usr/bin/tar",
      [
        "-xzf", archive.path, "--no-same-owner", "--no-same-permissions", "--no-xattrs", "-C",
        destination.path,
      ],
      directory: nil)
  }
  public func remove(recipeID: String) throws {
    guard !installing else { throw ToolInstallError.busy }
    _ = try checkedRecipe(recipeID)
    let fm = FileManager.default
    let receipt = directory.appendingPathComponent("receipts/" + recipeID + ".json")
    guard fm.fileExists(atPath: receipt.path),
      let value = try? JSONDecoder().decode(
        ToolInstallReceipt.self, from: Data(contentsOf: receipt)),
      value.recipeID == recipeID, value.owned, let managed = value.managedDirectory
    else {
      throw ToolInstallError.invalid(
        "No tCode-owned installation receipt exists. External tools and unowned resources were retained."
      )
    }
    guard
      Self.isManagedVersion(URL(fileURLWithPath: managed), recipeID: recipeID, directory: directory)
    else {
      throw ToolInstallError.unsafePath
    }
    let versions = directory.appendingPathComponent("versions/" + recipeID, isDirectory: true)
    guard Self.isDescendant(versions, of: directory),
      versions.standardizedFileURL.path
        == versions.resolvingSymlinksInPath().standardizedFileURL.path
    else { throw ToolInstallError.unsafePath }
    let candidates =
      (try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
    for candidate in candidates {
      guard Self.isManagedVersion(candidate, recipeID: recipeID, directory: directory),
        let bytes = try? Data(contentsOf: candidate.appendingPathComponent(".tcode-owned.json")),
        let owner = try? JSONDecoder().decode(ToolInstallReceipt.self, from: bytes), owner.owned,
        owner.recipeID == recipeID, owner.managedDirectory == candidate.path
      else { continue }
      try fm.removeItem(at: candidate)
    }
    // The active receipt also supports versions installed before per-version ownership markers were added.
    let active = URL(fileURLWithPath: managed)
    if fm.fileExists(atPath: active.path) { try fm.removeItem(at: active) }
    try fm.removeItem(at: receipt)
    if (try? fm.contentsOfDirectory(atPath: versions.path).isEmpty) == true {
      try? fm.removeItem(at: versions)
    }
  }
}
