import Foundation
import XCTest

@testable import TCodeCore

final class CatalogUpdateTests: XCTestCase {
  func testPublishedPackCannotBeShadowedByOlderBundledConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try LanguagePack.rust.portableData()
    try bytes.write(to: root.appendingPathComponent("rust.json"))
    func entry(
      _ availability: LanguageCatalogEntry.Availability,
      version: String = LanguagePack.rust.version, filename: String = "rust.json"
    ) -> LanguageCatalogEntry {
      .init(
        id: "rust", name: "Rust", version: version, summary: "fixture",
        packURL: URL(
          string: "https://github.com/LucaTufariello/tCode/releases/download/v1/rust.json")!,
        packSHA256: LanguageCatalogStore.sha256(bytes), toolRecipeIDs: [], grammarArtifactIDs: [],
        availability: availability, bundledFilename: filename)
    }
    XCTAssertEqual(
      try LanguageCatalogStore.bundledPack(entry: entry(.draft), resourceDirectory: root), bytes)
    XCTAssertNil(
      try LanguageCatalogStore.bundledPack(
        entry: entry(.published, version: "99"), resourceDirectory: root))
    XCTAssertThrowsError(
      try LanguageCatalogStore.bundledPack(
        entry: entry(.draft, version: "99"), resourceDirectory: root))
    XCTAssertThrowsError(
      try LanguageCatalog(
        entries: [entry(.draft, filename: "../rust.json")], publication: "fixture"
      ).validate())
  }
}
