import Darwin
import Foundation
import TCodeCore

func largeFixture(language: String) -> String {
  if language == "python" {
    return "# café 👩🏽‍💻\r\n"
      + (0..<9_999).map { "value_\($0) = 42\r\n" }.joined()
  }
  let declaration = language == "c" || language == "cpp" ? "int" : "let"
  let entry = language == "swift" ? "func main()" : language == "rust" ? "fn main()" : "int main()"
  return "// café 👩🏽‍💻\r\n\(entry) {\r\n"
    + (0..<9_997).map { "    \(declaration) value_\($0) = 42;\r\n" }.joined()
    + "}\r\n"
}

// This executable is packaged in its own test app so launchd resolves the same real XPC service.
func probe() async throws {
  let arguments = CommandLine.arguments
  guard arguments.count >= 4 else {
    throw SyntaxFailure.invalidGrammar(
      "Usage: TCodeSyntaxProbe <grammar-directory> <forbidden-file> <output-json>")
  }
  guard FileManager.default.fileExists(atPath: arguments[2]) else {
    throw SyntaxFailure.invalidGrammar("The sandbox probe requires an existing forbidden file")
  }
  _ = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
  let directory = URL(fileURLWithPath: arguments[1])
  let descriptor = try JSONDecoder().decode(
    SyntaxGrammarDescriptor.self,
    from: Data(contentsOf: directory.appendingPathComponent("descriptor.json")))
  let preservedStore = ProcessInfo.processInfo.environment["TCODE_PRESERVE_GRAMMAR_STORE"]
  let installerRoot: URL
  if let preservedStore {
    let candidate = URL(fileURLWithPath: preservedStore, isDirectory: true)
      .resolvingSymlinksInPath()
    let artifactsRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("artifacts", isDirectory: true).resolvingSymlinksInPath()
    let temporaryRoots = [
      FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/private/tmp"),
    ]
    .map { $0.resolvingSymlinksInPath().path + "/" }
    guard
      candidate.path.hasPrefix(artifactsRoot.path + "/")
        || temporaryRoots.contains(where: { candidate.path.hasPrefix($0) })
    else {
      throw SyntaxFailure.invalidGrammar(
        "Preserved probe stores must be isolated under artifacts/ or a temporary directory")
    }
    installerRoot = candidate
  } else {
    installerRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode-syntax-installer-" + UUID().uuidString)
  }
  defer { if preservedStore == nil { try? FileManager.default.removeItem(at: installerRoot) } }
  let archive = directory.deletingLastPathComponent().appendingPathComponent(
    "\(descriptor.id)-\(descriptor.version)-macos27-arm64.tar.gz")
  let archiveBytes = try Data(contentsOf: archive)
  let artifact = SyntaxGrammarArtifact(
    descriptor: descriptor,
    url: URL(
      string: "https://github.com/LucaTufariello/tCode/releases/download/language-grammars-v1/"
        + archive.lastPathComponent)!,
    sha256: SyntaxIntegrity.sha256(archiveBytes), downloadBytes: archiveBytes.count)
  let installer = SyntaxGrammarInstaller(
    root: installerRoot, artifacts: [artifact], allowLocalArtifactsForTesting: true,
    localArtifactDirectoryForTesting: directory.deletingLastPathComponent())
  let plan = try installer.plan(ids: [descriptor.id])
  try await installer.install(plan)
  guard installer.installed(descriptor.id) else { throw SyntaxFailure.notInstalled(descriptor.id) }
  let installedDirectory = SyntaxGrammarStore.directory(for: descriptor, root: installerRoot)
  let module = try Data(contentsOf: installedDirectory.appendingPathComponent(descriptor.module))
  let query = try Data(contentsOf: installedDirectory.appendingPathComponent(descriptor.query))
  // A broken update cannot replace the active working installation.
  let rejectedDescriptor = SyntaxGrammarDescriptor(
    id: descriptor.id, version: descriptor.version + "-rejected",
    symbol: descriptor.symbol, moduleSHA256: descriptor.moduleSHA256,
    querySHA256: descriptor.querySHA256,
    sourceRevision: descriptor.sourceRevision, abi: descriptor.abi)
  let broken = SyntaxGrammarArtifact(
    descriptor: rejectedDescriptor, url: artifact.url,
    sha256: String(repeating: "0", count: 64), downloadBytes: archiveBytes.count)
  let brokenInstaller = SyntaxGrammarInstaller(
    root: installerRoot, artifacts: [broken], allowLocalArtifactsForTesting: true,
    localArtifactDirectoryForTesting: directory.deletingLastPathComponent())
  var badArchiveRejected = false
  do {
    try await brokenInstaller.install(try brokenInstaller.plan(ids: [descriptor.id]))
  } catch SyntaxFailure.invalidGrammar { badArchiveRejected = true }
  guard badArchiveRejected else {
    throw SyntaxFailure.invalidGrammar("Bad archive digest was accepted")
  }
  guard installer.installed(descriptor.id),
    try SyntaxGrammarStore.activatedDescriptor(id: descriptor.id, root: installerRoot) == descriptor
  else {
    throw SyntaxFailure.invalidGrammar("Failed update changed the active working grammar")
  }
  let connection = SyntaxConnection()
  let documentID = UUID()
  let source: String
  switch descriptor.id {
  case "python": source = "# café 👩🏽‍💻\r\ndef greet(name):\r\n    return \"hello \" + name\r\n"
  case "rust": source = "// café 👩🏽‍💻\r\nfn main() { let answer = 42; println!(\"{}\", answer); }\r\n"
  case "swift":
    source = "// café 👩🏽‍💻\r\nfunc greet() -> String { let answer = 42; return \"hello\" }\r\n"
  default: source = "// café 👩🏽‍💻\r\nint main() { int answer = 42; return answer; }\r\n"
  }
  let first = try await connection.highlight(
    SyntaxRequest(
      documentID: documentID, version: 1,
      text: source, grammar: descriptor, moduleData: module, queryData: query))
  let second = try await connection.highlight(
    SyntaxRequest(
      documentID: documentID, version: 2,
      text: source.replacingOccurrences(of: "42", with: "420"), grammar: descriptor,
      moduleData: nil, queryData: nil))
  let badQuery = Data("(".utf8)
  let badQueryDescriptor = SyntaxGrammarDescriptor(
    id: descriptor.id, version: descriptor.version, symbol: descriptor.symbol,
    moduleSHA256: descriptor.moduleSHA256, querySHA256: SyntaxIntegrity.sha256(badQuery),
    sourceRevision: descriptor.sourceRevision, abi: descriptor.abi)
  var badQueryRejected = false
  do {
    _ = try await connection.highlight(
      SyntaxRequest(
        documentID: documentID, version: 3, text: source, grammar: badQueryDescriptor,
        moduleData: module, queryData: badQuery))
  } catch SyntaxFailure.invalidGrammar { badQueryRejected = true }
  let afterBadQuery = try await connection.highlight(
    SyntaxRequest(
      documentID: documentID, version: 3, text: source, grammar: descriptor,
      moduleData: nil, queryData: nil))
  guard badQueryRejected, afterBadQuery.incremental, !afterBadQuery.spans.isEmpty else {
    throw SyntaxFailure.invalidGrammar("Invalid query replaced the working parser")
  }
  var multiGrammarCount = 1
  if descriptor.id == "python" {
    for other in ["c", "cpp", "swift", "rust"] {
      let candidate = directory.deletingLastPathComponent().appendingPathComponent(other)
      let info = try JSONDecoder().decode(
        SyntaxGrammarDescriptor.self,
        from: Data(contentsOf: candidate.appendingPathComponent("descriptor.json")))
      let id = UUID()
      let check = try await connection.highlight(
        SyntaxRequest(
          documentID: id, version: 1,
          text: "// hello\n42", grammar: info,
          moduleData: Data(contentsOf: candidate.appendingPathComponent(info.module)),
          queryData: Data(contentsOf: candidate.appendingPathComponent(info.query))))
      guard !check.spans.isEmpty else {
        throw SyntaxFailure.invalidGrammar("No captures for \(other)")
      }
      multiGrammarCount += 1
      connection.close(id)
    }
  }
  let isolation: (Bool, Bool, Int32) = try await withCheckedThrowingContinuation { continuation in
    do {
      let remote = try connection.remote { continuation.resume(throwing: $0) }
      remote.isolationProbe(arguments[2]) { continuation.resume(returning: ($0, $1, $2)) }
    } catch { continuation.resume(throwing: error) }
  }
  guard !first.spans.isEmpty, second.incremental, !isolation.0, !isolation.1,
    isolation.2 == EPERM || isolation.2 == EACCES
  else {
    throw SyntaxFailure.invalidGrammar(
      "Packaged isolation/incremental test failed: read=\(isolation.0) network=\(isolation.1) errno=\(isolation.2)"
    )
  }
  var parseSamples = [Double]()
  var roundTripSamples = [Double]()
  let benchmarkID = UUID()
  let benchmarkSource = largeFixture(language: descriptor.id)
  let firstLarge = try await connection.highlight(
    SyntaxRequest(
      documentID: benchmarkID, version: 1, text: benchmarkSource, grammar: descriptor,
      moduleData: nil, queryData: nil))
  guard !firstLarge.spans.isEmpty else { throw SyntaxFailure.invalidResponse }
  for editIndex in 0..<100 {
    let comment = descriptor.id == "python" ? "# edit " : "// edit "
    let sampleText = benchmarkSource + comment + String(editIndex) + "\r\n"
    let started = ContinuousClock.now
    let result = try await connection.highlight(
      SyntaxRequest(
        documentID: benchmarkID, version: editIndex + 2,
        text: sampleText, grammar: descriptor, moduleData: nil, queryData: nil))
    let elapsed = started.duration(to: .now).components
    parseSamples.append(result.parseMilliseconds)
    roundTripSamples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
  }
  parseSamples.sort()
  roundTripSamples.sort()
  let memory = try await RunningProcess().run(
    executable: "/bin/ps",
    arguments: ["-o", "rss=", "-p", String(first.serviceProcessID)], directory: nil)
  let helperRSS = (Int(memory.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) * 1024
  connection.close(benchmarkID)
  print(
    "\(descriptor.id): parsed \(first.spans.count) captures, incremental edit passed; workspace and network denied"
  )
  let crashCheck = arguments.count > 4 && arguments[4] == "--crash-check"
  var recoveredServicePID: Int32?
  if crashCheck {
    // launchd intentionally throttles rapid restarts of a crashing XPC service.
    // The editor remains alive and uses its basic highlighter during this interval.
    (try? connection.remote { _ in })?.terminateForTesting()
    try await Task.sleep(for: .milliseconds(150))
    connection.invalidate()
    try await Task.sleep(for: .seconds(12))
    let recovered = try await connection.highlight(
      SyntaxRequest(
        documentID: documentID, version: 200,
        text: source, grammar: descriptor, moduleData: module, queryData: query))
    guard !recovered.spans.isEmpty, recovered.serviceProcessID != first.serviceProcessID else {
      throw SyntaxFailure.invalidGrammar("The helper did not restart in a new process")
    }
    recoveredServicePID = recovered.serviceProcessID
  }
  let report: [String: Any] = [
    "grammar": descriptor.id, "captures": first.spans.count,
    "incremental": second.incremental, "parseMilliseconds": first.parseMilliseconds,
    "managedInstallPassed": true, "badArchiveRejected": badArchiveRejected,
    "managedStorePreserved": preservedStore != nil,
    "badQueryRejectedWithWorkingParserPreserved": badQueryRejected,
    "installedBytes": module.count + query.count,
    "grammarsLoadedOnSameConnection": multiGrammarCount,
    "incrementalSamples": parseSamples.count, "workloadUTF8Bytes": benchmarkSource.utf8.count,
    "workloadLines": benchmarkSource.utf8.filter { $0 == 10 }.count,
    "initialLargeParseMilliseconds": firstLarge.parseMilliseconds,
    "incrementalParseMedianMs": parseSamples[50], "incrementalParseP95Ms": parseSamples[95],
    "incrementalRoundTripMedianMs": roundTripSamples[50],
    "incrementalRoundTripP95Ms": roundTripSamples[95],
    "helperResidentBytes": helperRSS,
    "workspaceReadDenied": !isolation.0, "networkDenied": !isolation.1,
    "networkErrno": isolation.2, "serviceCrashRecovered": crashCheck,
    "recoveredServicePID": recoveredServicePID ?? 0,
    "clientPID": ProcessInfo.processInfo.processIdentifier, "servicePID": first.serviceProcessID,
  ]
  try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: arguments[3]))
  connection.invalidate()
}
Task {
  do {
    try await probe()
    print("Packaged syntax probe passed")
    exit(0)
  } catch {
    fputs("Syntax probe: \(error.localizedDescription)\n", stderr)
    exit(1)
  }
}
dispatchMain()
