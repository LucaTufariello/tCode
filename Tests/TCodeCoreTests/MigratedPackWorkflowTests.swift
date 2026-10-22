import Foundation
import XCTest

@testable import TCodeCore

/// Runs the shipped v2 command definitions against actual compilers, formatters, and test runners.
/// Fixtures and test-specific caches are temporary; no example project or tool installation is changed.
final class MigratedPackWorkflowTests: XCTestCase {
  private func enabled() throws {
    guard ProcessInfo.processInfo.environment["TCODE_INTEGRATION"] == "1" else {
      throw XCTSkip("Set TCODE_INTEGRATION=1 to validate the migrated packs with real tools.")
    }
  }

  private func pack(_ id: String) throws -> LanguagePack {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resource = repository.appendingPathComponent("Sources/TCode/Resources/\(id).json")
    let pack = try LanguagePackRegistry.decode(Data(contentsOf: resource))
    XCTAssertEqual(pack.interfaceVersion, 2)
    return pack
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tcode migrated workflows 😀 " + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func write(_ text: String, to path: String, root: URL) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }

  private func requireTool(_ name: String) async throws -> String {
    guard let path = ToolLocator.find(name) else { throw XCTSkip("\(name) is not installed.") }
    let health = await ToolHealth.check(executable: path)
    guard health.isHealthy else { throw XCTSkip("\(name) is unavailable: \(health.detail)") }
    return path
  }

  private func context(root: URL, file: URL, python: String? = nil) -> [String: String] {
    let interpreter = python ?? ToolLocator.find("python3", root: root) ?? "python3"
    return [
      "workspace": root.path, "file": file.path, "fileName": file.lastPathComponent,
      "fileStem": file.deletingPathExtension().lastPathComponent,
      "python": interpreter, "interpreter": interpreter, "program": file.path,
      "buildDir": root.appendingPathComponent("build").path,
    ]
  }

  private func execute(
    _ definition: LanguageCommand, context: [String: String], root: URL, input: Data? = nil
  ) async throws -> ProcessResult {
    let command = try definition.resolved(context)
    let executable = try XCTUnwrap(
      ToolLocator.find(command.executable, root: root),
      "The shipped pack references an unavailable executable: \(command.executable)")
    let directory =
      command.workingDirectory.map {
        URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
      } ?? root
    var arguments = command.arguments
    let moduleCache = root.appendingPathComponent(".module-cache").path
    var environment = command.environment
    environment["CLANG_MODULE_CACHE_PATH"] = moduleCache
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = moduleCache
    environment["SWIFT_MODULE_CACHE_PATH"] = moduleCache
    if URL(fileURLWithPath: executable).lastPathComponent == "swift",
      let action = arguments.first, ["build", "run", "test"].contains(action)
    {
      // Preserve the manifest's action/arguments; isolate only SwiftPM's shared cache/config paths.
      arguments.insert(
        contentsOf: [
          "--cache-path", root.appendingPathComponent(".swiftpm-cache").path,
          "--config-path", root.appendingPathComponent(".swiftpm-config").path,
          "--security-path", root.appendingPathComponent(".swiftpm-security").path,
          "--manifest-cache", "local",
        ], at: 1)
    }
    let result = try await RunningProcess().run(
      executable: executable, arguments: arguments, directory: directory,
      environment: environment, input: input)
    XCTAssertEqual(result.status, 0, "\(executable) \(arguments)\n\(result.output)")
    guard result.status == 0 else { throw TCodeError.message("Migrated pack command failed.") }
    return result
  }

  private func task(
    _ action: String, pack: LanguagePack, context: [String: String], root: URL
  ) async throws -> String {
    let task = try XCTUnwrap(pack.tasks[action], "Missing migrated \(action) task")
    XCTAssertTrue(
      task.rootMarkers.allSatisfy {
        FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
      })
    var output = ""
    for step in task.steps {
      let result = try await execute(step, context: context, root: root)
      output += result.output
    }
    return output
  }

  private func assertPassingTest(_ output: String, pack: LanguagePack, named: String) throws {
    let parser = try XCTUnwrap(pack.tasks["test"]?.resultParser)
    let entries = TestReports.parse(output, runner: parser)
    XCTAssertTrue(entries.contains { $0.name.contains(named) && $0.status == "PASSED" }, output)
  }

  func testMigratedPythonBuildRunPytestAndRuffFormat() async throws {
    try enabled()
    let python = try await requireTool("python3")
    _ = try await requireTool("ruff")
    let pytest = try await RunningProcess().run(
      executable: python, arguments: ["-m", "pytest", "--version"], directory: nil)
    guard pytest.status == 0 else {
      throw XCTSkip("The selected Python needs pytest: \(pytest.output)")
    }
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write(
      "def answer():\n    return 42\n\nif __name__ == '__main__':\n    print(answer())\n",
      to: "main.py", root: root)
    _ = try write(
      "from main import answer\n\ndef test_answer():\n    assert answer() == 42\n",
      to: "test_answer.py", root: root)
    let pack = try pack("python")
    let context = context(root: root, file: file, python: python)
    _ = try await task("build", pack: pack, context: context, root: root)
    let run = try await task("run", pack: pack, context: context, root: root)
    XCTAssertEqual(run.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    let tests = try await task("test", pack: pack, context: context, root: root)
    try assertPassingTest(tests, pack: pack, named: "test_answer")
    let discovery = try await task("discoverTests", pack: pack, context: context, root: root)
    XCTAssertTrue(discovery.contains("test_answer.py::test_answer"), discovery)
    let input = "def answer():\n return(42)\n"
    let formatted = try await execute(
      XCTUnwrap(pack.formatterCommand), context: context, root: root, input: Data(input.utf8))
    XCTAssertNotEqual(formatted.stdout, input)
    XCTAssertTrue(formatted.stdout.contains("    return 42"), formatted.stdout)
    print(
      "VERIFIED migrated Python v2 pack: compileall, run=42, pytest, discovery, Ruff stdin format")
  }

  func testMigratedCPPConfigureBuildCTestBinaryAndClangFormat() async throws {
    try enabled()
    for name in ["cmake", "ctest", "clang++", "clang-format"] { _ = try await requireTool(name) }
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write(
      "#include <iostream>\nint main() { std::cout << 42 << '\\n'; return 0; }\n",
      to: "main.cpp", root: root)
    _ = try write(
      """
      cmake_minimum_required(VERSION 3.16)
      project(MigratedCpp LANGUAGES CXX)
      add_executable(migrated_sample main.cpp)
      enable_testing()
      add_test(NAME answer COMMAND migrated_sample)
      set_tests_properties(answer PROPERTIES PASS_REGULAR_EXPRESSION "42")

      """, to: "CMakeLists.txt", root: root)
    let pack = try pack("cpp")
    let context = context(root: root, file: file)
    _ = try await task("build", pack: pack, context: context, root: root)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("build/compile_commands.json").path))
    let tests = try await task("test", pack: pack, context: context, root: root)
    try assertPassingTest(tests, pack: pack, named: "answer")
    let discovery = try await task("discoverTests", pack: pack, context: context, root: root)
    XCTAssertTrue(discovery.contains("answer"), discovery)
    // The C/C++ pack deliberately requires an explicit run configuration for the chosen binary.
    let binary = root.appendingPathComponent("build/migrated_sample")
    let run = try await execute(.init(executable: binary.path), context: context, root: root)
    XCTAssertEqual(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    let input = "int main(){int answer=42;return answer-42;}\n"
    let formatted = try await execute(
      XCTUnwrap(pack.formatterCommand), context: context, root: root, input: Data(input.utf8))
    XCTAssertNotEqual(formatted.stdout, input)
    XCTAssertTrue(formatted.stdout.contains("int answer = 42;"), formatted.stdout)
    print(
      "VERIFIED migrated C/C++ v2 pack: CMake configure/build/compile_commands, CTest/discovery, binary run=42, clang-format stdin"
    )
  }

  func testMigratedSwiftPMBuildRunTestAndSwiftFormat() async throws {
    try enabled()
    _ = try await requireTool("swift")
    _ = try await requireTool("swift-format")
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try write(
      """
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(name: "MigratedSwift", products: [
        .executable(name: "MigratedSwift", targets: ["MigratedSwift"])
      ], targets: [
        .target(name: "Answer"),
        .executableTarget(name: "MigratedSwift", dependencies: ["Answer"]),
        .testTarget(name: "AnswerTests", dependencies: ["Answer"])
      ])

      """, to: "Package.swift", root: root)
    let file = try write(
      "import Answer\nprint(answer())\n", to: "Sources/MigratedSwift/main.swift", root: root)
    _ = try write(
      "public func answer() -> Int { 42 }\n", to: "Sources/Answer/Answer.swift", root: root)
    _ = try write(
      """
      import XCTest
      import Answer
      final class AnswerTests: XCTestCase {
        func testAnswer() { XCTAssertEqual(answer(), 42) }
      }

      """, to: "Tests/AnswerTests/AnswerTests.swift", root: root)
    let pack = try pack("swift")
    let context = context(root: root, file: file)
    _ = try await task("build", pack: pack, context: context, root: root)
    let run = try await task("run", pack: pack, context: context, root: root)
    XCTAssertTrue(run.components(separatedBy: .newlines).contains("42"), run)
    let tests = try await task("test", pack: pack, context: context, root: root)
    try assertPassingTest(tests, pack: pack, named: "testAnswer")
    let discovery = try await task("discoverTests", pack: pack, context: context, root: root)
    XCTAssertTrue(discovery.contains("testAnswer"), discovery)
    let input = "let answer=42\nprint( answer )\n"
    let formatted = try await execute(
      XCTUnwrap(pack.formatterCommand), context: context, root: root, input: Data(input.utf8))
    XCTAssertNotEqual(formatted.stdout, input)
    XCTAssertTrue(formatted.stdout.contains("let answer = 42"), formatted.stdout)
    print(
      "VERIFIED migrated Swift v2 pack: SwiftPM build/run=42/test/discovery, swift-format stdin")
  }
}
