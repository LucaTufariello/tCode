import Foundation
import TCodeCore
import XCTest

@testable import TCode

private actor ControlledSyntaxTransport {
  private var requests: [SyntaxRequest] = []
  private var waiting = [CheckedContinuation<Void, Never>]()
  private var replies = [CheckedContinuation<SyntaxResponse, Error>]()
  private var automatic = false
  func send(_ request: SyntaxRequest) async throws -> SyntaxResponse {
    requests.append(request)
    let listeners = waiting
    waiting.removeAll()
    for listener in listeners { listener.resume() }
    if automatic { return response(request) }
    return try await withCheckedThrowingContinuation { replies.append($0) }
  }
  func waitUntilRequested() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func release() {
    automatic = true
    let pending = replies
    replies.removeAll()
    for (index, reply) in pending.enumerated() {
      reply.resume(returning: response(requests[index]))
    }
  }
  func count() -> Int { requests.count }
  private func response(_ request: SyntaxRequest) -> SyntaxResponse {
    SyntaxResponse(
      documentID: request.documentID, version: request.version,
      spans: [SyntaxHighlightSpan(location: 0, length: 1, capture: "keyword")],
      parseMilliseconds: 0, incremental: request.version > 1)
  }
}

final class SyntaxClientTests: XCTestCase {
  private func makeClient(_ transport: ControlledSyntaxTransport) -> SyntaxClient {
    let descriptor = SyntaxGrammarDescriptor(
      id: "rust", version: "fixture", symbol: "tree_sitter_rust",
      moduleSHA256: String(repeating: "a", count: 64),
      querySHA256: String(repeating: "b", count: 64),
      sourceRevision: "fixture", abi: 15)
    let artifact = SyntaxGrammarArtifact(
      descriptor: descriptor,
      url: URL(
        string: "https://github.com/LucaTufariello/tCode/releases/download/fixture/rust.tar.gz")!,
      sha256: String(repeating: "c", count: 64), downloadBytes: 1)
    return SyntaxClient(
      artifacts: [artifact],
      root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      requestHandler: { try await transport.send($0) },
      moduleLoader: { _, _ in (Data([1]), Data([2])) })
  }
  func testSplitViewsShareOneInFlightAndCachedResult() async throws {
    let transport = ControlledSyntaxTransport()
    let client = makeClient(transport)
    let id = UUID()
    async let left = client.highlight(
      documentID: id, version: 1, text: "fn main() {}", grammarID: "rust")
    async let right = client.highlight(
      documentID: id, version: 1, text: "fn main() {}", grammarID: "rust")
    await transport.waitUntilRequested()
    await transport.release()
    let results = try await (left, right)
    XCTAssertEqual(results.0, results.1)
    _ = try await client.highlight(
      documentID: id, version: 1, text: "fn main() {}", grammarID: "rust")
    let count = await transport.count()
    XCTAssertEqual(count, 1)
    await client.close(id)
  }
  func testClosedDocumentRejectsPendingResponse() async throws {
    let transport = ControlledSyntaxTransport()
    let client = makeClient(transport)
    let id = UUID()
    let work = Task {
      try await client.highlight(
        documentID: id, version: 1, text: "fn main() {}", grammarID: "rust")
    }
    await transport.waitUntilRequested()
    await client.close(id)
    await transport.release()
    do {
      _ = try await work.value
      XCTFail("Closed document accepted a response")
    } catch SyntaxFailure.stale {}
    let next = try await client.highlight(
      documentID: id, version: 2, text: "fn main() {}", grammarID: "rust")
    XCTAssertFalse(next.isEmpty)
    let count = await transport.count()
    XCTAssertEqual(count, 2)
    await client.close(id)
  }
  func testCancellingOneSplitDoesNotCancelSharedParse() async throws {
    let transport = ControlledSyntaxTransport()
    let client = makeClient(transport)
    let id = UUID()
    let cancelled = Task {
      try await client.highlight(
        documentID: id, version: 1, text: "fn main() {}", grammarID: "rust")
    }
    await transport.waitUntilRequested()
    cancelled.cancel()
    let other = Task {
      try await client.highlight(
        documentID: id, version: 1, text: "fn main() {}", grammarID: "rust")
    }
    await transport.release()
    do {
      _ = try await cancelled.value
      XCTFail("Cancelled split accepted a result")
    } catch is CancellationError {}
    let result = try await other.value
    XCTAssertFalse(result.isEmpty)
    let count = await transport.count()
    XCTAssertEqual(count, 1)
    await client.close(id)
  }
  func testOlderVersionsAndOversizedQueriesNeverLaunchWork() async throws {
    let transport = ControlledSyntaxTransport()
    await transport.release()
    let client = makeClient(transport)
    let id = UUID()
    _ = try await client.highlight(
      documentID: id, version: 100, text: "fn main() {}", grammarID: "rust")
    do {
      _ = try await client.highlight(
        documentID: id, version: 99, text: "fn main() {}", grammarID: "rust")
      XCTFail("Older version was accepted")
    } catch SyntaxFailure.stale {}
    do {
      _ = try await client.highlight(
        documentID: id, version: 101, text: "fn main() {}", grammarID: "rust",
        queryOverride: String(repeating: "a", count: 1_048_577))
      XCTFail("Oversized custom query was accepted")
    } catch SyntaxFailure.invalidGrammar {}
    let count = await transport.count()
    XCTAssertEqual(count, 1)
    await client.close(id)
  }
}
