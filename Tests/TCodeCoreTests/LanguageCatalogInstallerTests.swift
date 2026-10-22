import Foundation
import XCTest

@testable import TCodeCore

final class LanguageCatalogInstallerTests: XCTestCase {
  func temporary() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode-installer-" + UUID().uuidString
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  func nativeArchive(in root: URL, version: String = "1", exit: Int = 0) async throws -> URL {
    let folder = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("probe.c")
    try Data(
      "#include <stdio.h>\nint main(void) { puts(\"tCode fixture \(version)\"); return \(exit); }\n"
        .utf8
    ).write(to: source)
    let executable = folder.appendingPathComponent("fixture")
    let compile = try await RunningProcess().run(
      executable: "/usr/bin/xcrun",
      arguments: ["clang", "-arch", "arm64", source.path, "-o", executable.path], directory: nil)
    guard compile.status == 0 else {
      throw NSError(
        domain: "FixtureCompile", code: 1, userInfo: [NSLocalizedDescriptionKey: compile.output])
    }
    let compressed = try await RunningProcess().run(
      executable: "/usr/bin/gzip", arguments: ["-k", executable.path], directory: nil)
    XCTAssertEqual(compressed.status, 0)
    return executable.appendingPathExtension("gz")
  }
  func recipe(archive: URL, version: String = "1", hash: String? = nil) throws -> ToolRecipe {
    let bytes = try Data(contentsOf: archive)
    return ToolRecipe(
      id: "fixture", name: "Fixture", version: version, kind: .gzipExecutable,
      downloads: [
        ToolDownload(
          url: archive, sha256: hash ?? LanguageCatalogStore.sha256(bytes), filename: "fixture.gz",
          size: bytes.count)
      ], executables: ["fixture": "bin/fixture"])
  }
  func testBundledOfflineCatalogAndInvalidCacheFallback() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LanguageCatalogStore(directory: root)
    let first = try await store.cached()
    XCTAssertEqual(Set(first.entries.map(\.id)), ["python", "cpp", "swift", "rust"])
    XCTAssertTrue(first.entries.allSatisfy { $0.availability == .draft })
    try Data("{\"version\":999}".utf8).write(to: root.appendingPathComponent("catalog.json"))
    let fallback = try await store.cached()
    XCTAssertEqual(fallback.entries.count, 4)
    do {
      _ = try await store.fetchPack(entry: first.entries[0])
      XCTFail("Unpublished catalog entry was fetched")
    } catch { XCTAssertTrue(error.localizedDescription.contains("not been published")) }
  }
  func testPublishedCatalogRequiresPinnedCuratedArtifact() throws {
    let entry = LanguageCatalogEntry(
      id: "rust", name: "Rust", version: "2", summary: "Rust",
      packURL: URL(string: "https://evil.invalid/pack.json")!,
      packSHA256: String(repeating: "0", count: 64), toolRecipeIDs: [], grammarArtifactIDs: [],
      availability: .published)
    XCTAssertThrowsError(try LanguageCatalog(entries: [entry], publication: "test").validate())
    XCTAssertNoThrow(try LanguageCatalog.starter.validate())
  }
  func testCuratedReleaseURLRejectsTraversalCredentialsAndOtherRoutes() {
    for value in [
      "https://github.com/LucaTufariello/tCode/releases/download/v1/../pack.json",
      "https://github.com/LucaTufariello/tCode/releases/download/v1/%2E%2E%2Fpack.json",
      "https://github.com/LucaTufariello/tCode/releases/download/v1/pack.json?download=1",
      "https://user@github.com/LucaTufariello/tCode/releases/download/v1/pack.json",
      "https://github.com/LucaTufariello/tCode/releases/download/v1/nested/pack.json",
      "https://github.com/other/tCode/releases/download/v1/pack.json",
    ] {
      XCTAssertFalse(LanguageCatalog.isCuratedReleaseURL(URL(string: value)!), value)
    }
    XCTAssertTrue(LanguageCatalog.isCuratedReleaseURL(LanguageCatalog.defaultURL))
  }
  func testHashedPackMustMatchCatalogIdentityAndVersion() throws {
    let bytes = try LanguagePack.rust.portableData()
    let hash = LanguageCatalogStore.sha256(bytes)
    func entry(id: String = "rust", version: String = LanguagePack.rust.version)
      -> LanguageCatalogEntry
    {
      .init(
        id: id, name: "Rust", version: version, summary: "Fixture",
        packURL: URL(
          string: "https://github.com/LucaTufariello/tCode/releases/download/v1/rust.json")!,
        packSHA256: hash, toolRecipeIDs: [], grammarArtifactIDs: [], availability: .published)
    }
    XCTAssertNoThrow(try LanguageCatalogStore.validatePack(bytes, entry: entry(), hash: hash))
    XCTAssertThrowsError(
      try LanguageCatalogStore.validatePack(bytes, entry: entry(id: "python"), hash: hash))
    XCTAssertThrowsError(
      try LanguageCatalogStore.validatePack(bytes, entry: entry(version: "99.0.0"), hash: hash))
    XCTAssertThrowsError(
      try LanguageCatalogStore.validatePack(
        bytes, entry: entry(), hash: String(repeating: "0", count: 64)))
  }
  func testCatalogCarriesNewCuratedGrammarWithoutAppChangesAndDecodesLegacy() throws {
    let legacy = try JSONSerialization.data(withJSONObject: [
      "version": 1, "entries": [], "publication": "old cache",
    ])
    XCTAssertTrue(
      try JSONDecoder().decode(LanguageCatalog.self, from: legacy).grammarArtifacts.isEmpty)
    let descriptor = SyntaxGrammarDescriptor(
      id: "futurelang", version: "rev1", symbol: "tree_sitter_futurelang",
      moduleSHA256: String(repeating: "a", count: 64),
      querySHA256: String(repeating: "b", count: 64), sourceRevision: "123456789abcdef", abi: 15)
    func artifact(
      _ url: String =
        "https://github.com/LucaTufariello/tCode/releases/download/language-grammars-v2/futurelang.tar.gz",
      size: Int = 12345
    ) -> SyntaxGrammarArtifact {
      SyntaxGrammarArtifact(
        descriptor: descriptor, url: URL(string: url)!, sha256: String(repeating: "c", count: 64),
        downloadBytes: size)
    }
    let catalog = LanguageCatalog(
      entries: [], publication: "curated future grammar", grammarArtifacts: [artifact()])
    XCTAssertNoThrow(try catalog.validate())
    XCTAssertEqual(
      try JSONDecoder().decode(LanguageCatalog.self, from: JSONEncoder().encode(catalog))
        .grammarArtifacts.first?.descriptor.id, "futurelang")
    XCTAssertThrowsError(
      try LanguageCatalog(
        entries: [], publication: "bad", grammarArtifacts: [artifact(), artifact()]
      ).validate())
    XCTAssertThrowsError(
      try LanguageCatalog(
        entries: [], publication: "bad",
        grammarArtifacts: [
          artifact("https://github.com/other/repository/releases/download/v1/grammar.tar.gz")
        ]
      ).validate())
    XCTAssertThrowsError(
      try LanguageCatalog(entries: [], publication: "bad", grammarArtifacts: [artifact(size: 0)])
        .validate())
  }
  func testDeclineAndUnknownRecipeDoNotWrite() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try await nativeArchive(in: root)
    let directory = root.appendingPathComponent("tools")
    let installer = ToolInstaller(
      directory: directory, recipes: [try recipe(archive: archive)],
      allowLocalArtifactsForTesting: true, preferExistingTools: false)
    do {
      _ = try await installer.plan(recipeID: "untrusted-install-script")
      XCTFail()
    } catch {}
    let plan = try await installer.plan(recipeID: "fixture")
    do {
      _ = try await installer.install(plan, approval: { _ in false })
      XCTFail()
    } catch { XCTAssertTrue(error.localizedDescription.contains("not approved")) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }
  func testNativeInstallBadHashAndFailedUpdatePreserveWorkingVersion() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("tools")
    let archive = try await nativeArchive(in: root)
    let installer = ToolInstaller(
      directory: directory, recipes: [try recipe(archive: archive)],
      allowLocalArtifactsForTesting: true, preferExistingTools: false)
    let plan = try await installer.plan(recipeID: "fixture")
    XCTAssertTrue(plan.canInstall)
    let receipt = try await installer.install(plan, approval: { _ in true })
    XCTAssertTrue(receipt.owned)
    let path = try XCTUnwrap(receipt.executables["fixture"])
    XCTAssertEqual(ManagedToolPaths.resolve(name: "fixture", directory: directory), path)
    let report = await ToolHealth.check(executable: path)
    XCTAssertTrue(report.isHealthy)
    let corrupt = ToolInstaller(
      directory: directory,
      recipes: [
        try recipe(archive: archive, version: "2", hash: String(repeating: "0", count: 64))
      ], allowLocalArtifactsForTesting: true, preferExistingTools: false)
    do {
      _ = try await corrupt.install(corrupt.plan(recipeID: "fixture"), approval: { _ in true })
      XCTFail()
    } catch { XCTAssertTrue(error.localizedDescription.contains("SHA-256")) }
    XCTAssertEqual(ManagedToolPaths.resolve(name: "fixture", directory: directory), path)
    let failedArchive = try await nativeArchive(in: root, version: "3", exit: 17)
    let failed = ToolInstaller(
      directory: directory, recipes: [try recipe(archive: failedArchive, version: "3")],
      allowLocalArtifactsForTesting: true, preferExistingTools: false)
    do {
      _ = try await failed.install(failed.plan(recipeID: "fixture"), approval: { _ in true })
      XCTFail()
    } catch { XCTAssertTrue(error.localizedDescription.contains("health check")) }
    XCTAssertEqual(ManagedToolPaths.resolve(name: "fixture", directory: directory), path)
    let versions = try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent("versions/fixture"), includingPropertiesForKeys: nil)
    XCTAssertEqual(versions.count, 1, "Failed candidates must be removed")
    try await installer.remove(recipeID: "fixture")
    XCTAssertNil(ManagedToolPaths.resolve(name: "fixture", directory: directory))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: archive.path), "Only tCode-owned resources are removed"
    )
  }
  func testCancellationDoesNotActivateCandidate() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try await nativeArchive(in: root)
    let directory = root.appendingPathComponent("tools")
    let installer = ToolInstaller(
      directory: directory, recipes: [try recipe(archive: archive)],
      allowLocalArtifactsForTesting: true, preferExistingTools: false)
    let plan = try await installer.plan(recipeID: "fixture")
    let operation = Task {
      try await installer.install(
        plan, approval: { _ in true },
        progress: { update in
          if update.phase == .verifying { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do {
      _ = try await operation.value
      XCTFail("Cancelled installation activated")
    } catch {}
    XCTAssertNil(ManagedToolPaths.resolve(name: "fixture", directory: directory))
    let versions =
      (try? FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("versions/fixture"), includingPropertiesForKeys: nil))
      ?? []
    XCTAssertTrue(versions.isEmpty)
  }
  func testCancellationAtActivationPreservesPreviousReceipt() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try await nativeArchive(in: root)
    let directory = root.appendingPathComponent("tools")
    let original = ToolInstaller(
      directory: directory, recipes: [try recipe(archive: archive)],
      allowLocalArtifactsForTesting: true, preferExistingTools: false)
    let receipt = try await original.install(
      original.plan(recipeID: "fixture"), approval: { _ in true })
    let update = ToolInstaller(
      directory: directory, recipes: [try recipe(archive: archive, version: "2")],
      allowLocalArtifactsForTesting: true, preferExistingTools: false)
    let plan = try await update.plan(recipeID: "fixture")
    let operation = Task {
      try await update.install(
        plan, approval: { _ in true },
        progress: { progress in
          if progress.phase == .activating { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do {
      _ = try await operation.value
      XCTFail("Cancelled update activated")
    } catch {}
    XCTAssertEqual(
      ManagedToolPaths.resolve(name: "fixture", directory: directory),
      receipt.executables["fixture"])
    let versions = try FileManager.default.contentsOfDirectory(
      atPath: directory.appendingPathComponent("versions/fixture").path)
    XCTAssertEqual(versions.count, 1)
  }
  func testArchiveSymlinkRejectedBeforeExtraction() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("input")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: input.appendingPathComponent("escape"), withDestinationURL: root)
    let archive = root.appendingPathComponent("unsafe.tar.gz")
    let tar = try await RunningProcess().run(
      executable: "/usr/bin/tar", arguments: ["-czf", archive.path, "-C", input.path, "escape"],
      directory: nil)
    XCTAssertEqual(tar.status, 0)
    let bytes = try Data(contentsOf: archive)
    let unsafeRecipe = ToolRecipe(
      id: "fixture", name: "Fixture", version: "1", kind: .tarGzip,
      downloads: [
        ToolDownload(
          url: archive, sha256: LanguageCatalogStore.sha256(bytes), filename: "unsafe.tar.gz",
          size: bytes.count)
      ], executables: ["fixture": "bin/fixture"])
    let installer = ToolInstaller(
      directory: root.appendingPathComponent("tools"), recipes: [unsafeRecipe],
      allowLocalArtifactsForTesting: true, preferExistingTools: false)
    let plan = try await installer.plan(recipeID: "fixture")
    do {
      _ = try await installer.install(plan, approval: { _ in true })
      XCTFail()
    } catch { XCTAssertTrue(error.localizedDescription.contains("unsafe")) }
  }
  func testArchiveParentTraversalRejectedBeforeExtraction() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var header = Data(repeating: 0, count: 512)
    func field(_ text: String, at offset: Int, length: Int) {
      header.replaceSubrange(
        offset..<(offset + min(text.utf8.count, length)), with: text.utf8.prefix(length))
    }
    field("../escape", at: 0, length: 100)
    field("0000644\0", at: 100, length: 8)
    field("0000000\0", at: 108, length: 8)
    field("0000000\0", at: 116, length: 8)
    field("00000000001\0", at: 124, length: 12)
    field("00000000000\0", at: 136, length: 12)
    field("        ", at: 148, length: 8)
    field("0", at: 156, length: 1)
    field("ustar\0", at: 257, length: 6)
    field("00", at: 263, length: 2)
    let checksum = header.reduce(0) { $0 + Int($1) }
    field(String(format: "%06o\0 ", checksum), at: 148, length: 8)
    var tar = header
    tar.append(Data("x".utf8))
    tar.append(Data(repeating: 0, count: 511 + 1_024))
    let raw = root.appendingPathComponent("unsafe.tar")
    try tar.write(to: raw)
    let compression = try await RunningProcess().run(
      executable: "/usr/bin/gzip", arguments: ["-k", raw.path], directory: nil)
    XCTAssertEqual(compression.status, 0)
    let archive = raw.appendingPathExtension("gz")
    let bytes = try Data(contentsOf: archive)
    let recipe = ToolRecipe(
      id: "fixture", name: "Fixture", version: "1", kind: .tarGzip,
      downloads: [
        .init(
          url: archive, sha256: LanguageCatalogStore.sha256(bytes), filename: "unsafe.tar.gz",
          size: bytes.count)
      ],
      executables: ["fixture": "bin/fixture"])
    let directory = root.appendingPathComponent("tools")
    let installer = ToolInstaller(
      directory: directory, recipes: [recipe], allowLocalArtifactsForTesting: true,
      preferExistingTools: false)
    do {
      _ = try await installer.install(installer.plan(recipeID: "fixture"), approval: { _ in true })
      XCTFail("Traversal archive was installed")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("unsafe"), error.localizedDescription)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    XCTAssertNil(ManagedToolPaths.resolve(name: "fixture", directory: directory))
  }
  func testExecutableShimFailureIsNotHealthy() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let shim = root.appendingPathComponent("rust-analyzer")
    try Data(
      "#!/bin/sh\necho 'rust-analyzer is not installed for this toolchain' >&2\nexit 1\n".utf8
    ).write(to: shim)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    let health = await ToolHealth.check(executable: shim.path)
    XCTAssertFalse(health.isHealthy)
    XCTAssertEqual(health.status, .failed)
  }
  func testVersionProbeTimeoutIsNotHealthyEvenWhenTerminatedToolExitsZero() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = root.appendingPathComponent("slow-version")
    try Data("#!/bin/sh\ntrap 'echo fixture-1; exit 0' TERM\nsleep 20\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let report = await ToolHealth.check(executable: tool.path, timeout: 0.15)
    XCTAssertEqual(report.status, .timedOut)
    XCTAssertFalse(report.isHealthy)
  }
  func testRemoveRetainsUnownedVersionsAndExternalFiles() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try await nativeArchive(in: root)
    let directory = root.appendingPathComponent("tools")
    let installer = ToolInstaller(
      directory: directory, recipes: [try recipe(archive: archive)],
      allowLocalArtifactsForTesting: true, preferExistingTools: false)
    let active = try await installer.install(
      installer.plan(recipeID: "fixture"), approval: { _ in true })
    let unowned = directory.appendingPathComponent("versions/fixture/unowned")
    try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
    let privateFile = unowned.appendingPathComponent("notes.txt")
    try Data("retain this unowned directory".utf8).write(to: privateFile)
    try await installer.remove(recipeID: "fixture")
    XCTAssertTrue(FileManager.default.fileExists(atPath: privateFile.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(active.managedDirectory)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
  }
  func testReceiptCannotRemoveAnotherRecipeOrEscapeThroughSymlink() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("tools")
    let receipts = directory.appendingPathComponent("receipts")
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let protected = outside.appendingPathComponent("fixture")
    try Data("#!/bin/sh\necho fixture\n".utf8).write(to: protected)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protected.path)
    let recipe = ToolRecipe(
      id: "fixture", name: "Fixture", version: "1", kind: .external,
      executables: ["fixture": "fixture"])
    let installer = ToolInstaller(directory: directory, recipes: [recipe])
    let other = directory.appendingPathComponent("versions/other/version1")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    func writeReceipt(_ managed: URL) throws {
      let value = ToolInstallReceipt(
        recipeID: "fixture", version: "1", installedAt: Date(),
        managedDirectory: managed.path,
        executables: ["fixture": managed.appendingPathComponent("fixture").path], owned: true)
      try JSONEncoder().encode(value).write(to: receipts.appendingPathComponent("fixture.json"))
    }
    try writeReceipt(other)
    do {
      try await installer.remove(recipeID: "fixture")
      XCTFail("Cross-recipe receipt removed resources")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    let recipeRoot = directory.appendingPathComponent("versions/fixture")
    try FileManager.default.createDirectory(at: recipeRoot, withIntermediateDirectories: true)
    let link = recipeRoot.appendingPathComponent("version1")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    try writeReceipt(link)
    XCTAssertNil(ManagedToolPaths.resolve(name: "fixture", directory: directory))
    do {
      try await installer.remove(recipeID: "fixture")
      XCTFail("Symlink receipt removed resources")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: receipts.appendingPathComponent("fixture.json").path))
  }
  func testRecipeRejectsUnpinnedDownloadAndUnsafeExecutablePath() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bad = ToolRecipe(
      id: "fixture", name: "Fixture", version: "1", kind: .gzipExecutable,
      downloads: [
        ToolDownload(
          url: URL(string: "http://example.invalid/tool.gz")!, sha256: "", filename: "../escape")
      ], executables: ["fixture": "../bin/fixture"])
    let installer = ToolInstaller(directory: root, recipes: [bad])
    do {
      _ = try await installer.plan(recipeID: "fixture")
      XCTFail()
    } catch {}
  }
  func testHealthyExistingXcodeToolsProduceAnAvailableReusePlan() async throws {
    guard ProcessInfo.processInfo.environment["TCODE_INTEGRATION"] == "1" else {
      throw XCTSkip("Set TCODE_INTEGRATION=1 to validate the actual Xcode tool reuse plan.")
    }
    for name in ["clangd", "lldb-dap", "swift"] {
      guard let path = ToolLocator.find(name), (await ToolHealth.check(executable: path)).isHealthy
      else {
        throw XCTSkip("A healthy existing \(name) is required for the Xcode reuse case.")
      }
    }
    guard let sourcekit = ToolLocator.find("sourcekit-lsp"),
      (await ToolHealth.check(executable: sourcekit, arguments: ["--help"])).isHealthy
    else {
      throw XCTSkip("A working sourcekit-lsp --help is required for the Xcode reuse case.")
    }
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ToolInstaller(directory: root.appendingPathComponent("managed"))
    let plan = try await installer.plan(recipeID: "xcode-tools")
    XCTAssertTrue(
      plan.canInstall, plan.unavailableReason ?? "Healthy Xcode tools were not reusable.")
    XCTAssertTrue(plan.downloads.isEmpty)
    XCTAssertTrue(plan.expectedChanges.contains { $0.contains("sourcekit-lsp:") })
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("managed").path),
      "Planning must not install or activate tools.")
  }
  func recordInstallMetrics(_ receipt: ToolInstallReceipt, plan: ToolInstallPlan, started: Date)
    throws
  {
    let files =
      receipt.managedDirectory.flatMap {
        FileManager.default.enumerator(
          at: URL(fileURLWithPath: $0),
          includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])?.allObjects as? [URL]
      } ?? []
    let bytes = files.reduce(0) { total, url in
      total
        + ((try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).flatMap {
          $0.isRegularFile == true ? $0.fileSize : nil
        } ?? 0)
    }
    let row: [String: Any] = [
      "recipeID": receipt.recipeID, "version": receipt.version, "downloadBytes": plan.downloadBytes,
      "installedBytes": bytes, "elapsedSeconds": Date().timeIntervalSince(started),
    ]
    print(
      "TCODE_INSTALLER_METRICS "
        + String(
          decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
          as: UTF8.self))
  }
  func testPinnedPythonToolDownloadsAndIsolatedEnvironment() async throws {
    guard ProcessInfo.processInfo.environment["TCODE_DOWNLOAD_INTEGRATION"] == "1" else {
      throw XCTSkip(
        "Set TCODE_DOWNLOAD_INTEGRATION=1 to validate the real pinned Python wheel downloads.")
    }
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ToolInstaller(
      directory: root.appendingPathComponent("tools"), preferExistingTools: false)
    let plan = try await installer.plan(recipeID: "python-tools")
    guard plan.canInstall else {
      throw XCTSkip(plan.prerequisites.map(\.detail).joined(separator: "\n"))
    }
    let started = Date()
    let receipt = try await installer.install(plan, approval: { _ in true })
    try recordInstallMetrics(receipt, plan: plan, started: started)
    XCTAssertTrue(receipt.owned)
    XCTAssertNotNil(receipt.executables["pylsp"])
    XCTAssertNotNil(receipt.executables["debugpy"])
    let python = try XCTUnwrap(receipt.executables["python3"])
    let check = try await RunningProcess().run(
      executable: python, arguments: ["-m", "pip", "check"], directory: nil)
    XCTAssertEqual(check.status, 0, check.output)
  }
  func testPinnedOfficialRustAnalyzerDownload() async throws {
    guard ProcessInfo.processInfo.environment["TCODE_DOWNLOAD_INTEGRATION"] == "1" else {
      throw XCTSkip(
        "Set TCODE_DOWNLOAD_INTEGRATION=1 to validate the real pinned rust-analyzer download.")
    }
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = ToolInstaller(
      directory: root.appendingPathComponent("tools"), preferExistingTools: false)
    let plan = try await installer.plan(recipeID: "rust-analyzer")
    guard plan.canInstall else {
      throw XCTSkip(plan.prerequisites.map(\.detail).joined(separator: "\n"))
    }
    let started = Date()
    let receipt = try await installer.install(plan, approval: { _ in true })
    try recordInstallMetrics(receipt, plan: plan, started: started)
    let tool = try XCTUnwrap(receipt.executables["rust-analyzer"])
    let report = await ToolHealth.check(executable: tool)
    XCTAssertTrue(report.isHealthy, report.detail)
    XCTAssertTrue(
      report.version?.contains("2026-10-19") == true || report.version?.contains("5ec20d0") == true)
  }

}
