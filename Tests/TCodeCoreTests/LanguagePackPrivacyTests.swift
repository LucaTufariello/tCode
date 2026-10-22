import Foundation
import XCTest

@testable import TCodeCore

final class LanguagePackPrivacyTests: XCTestCase {
  private func pack() -> LanguagePack {
    LanguagePack(
      id: "fixture", name: "Fixture",
      associations: [.init(languageID: "fixture", extensions: ["fix"])],
      languageServer: .init(command: .init(executable: "fixture-lsp")))
  }

  func testExistingLanguageDefaultsRemainPortable() throws {
    let examples = [
      LanguagePack.legacy(
        id: "python", name: "Python", extensions: ["py"], server: "pylsp", serverArguments: [],
        formatter: "ruff", adapter: "python3"),
      LanguagePack.legacy(
        id: "cpp", name: "C / C++", extensions: ["c", "cpp", "h"], server: "clangd",
        serverArguments: [], formatter: "clang-format", adapter: "lldb-dap"),
      LanguagePack.legacy(
        id: "swift", name: "Swift", extensions: ["swift"], server: "sourcekit-lsp",
        serverArguments: [], formatter: "swift-format", adapter: "lldb-dap"),
      LanguagePack.rust,
    ]
    for example in examples {
      let bytes = try example.portableData()
      XCTAssertEqual(try LanguagePackRegistry.decode(bytes), example)
    }
  }

  func testExportRejectsLocalPathsAndCredentialFlagsInArguments() throws {
    for argument in [
      "--root=/Users/fixture/PrivateProject", "/private/tmp/source", "~/project", "${HOME}/project",
      "$HOME/project",
      "C:\\Users\\fixture\\project", "file:///Users/fixture/private", "--token=private-value",
      "--api-key", "--password=private-value",
      "https://user:password@example.invalid/endpoint", "Bearer abcdefghijklmnop",
    ] {
      var value = pack()
      value.languageServer?.command.arguments = [argument]
      XCTAssertThrowsError(
        try value.portableData(), "Argument must not be silently exported: \(argument)")
    }
    var value = pack()
    value.languageServer?.command.executable = "/opt/private/fixture-lsp"
    XCTAssertThrowsError(try value.portableData())
    value.languageServer?.command = .init(
      executable: "fixture-lsp", environment: ["CUSTOM": "private-value"])
    XCTAssertThrowsError(try value.portableData())
  }

  func testExportRejectsPrivateValuesNestedInOptionsAndDebugLaunch() throws {
    let privateValues: [LanguageValue] = [
      .object(["settings": .array([.object(["api_key": .string("private-value")])])]),
      .object(["serviceToken": .string("private-value")]),
      .object(["cache": .object(["path": .string("/Users/fixture/private")])]),
      .object(["env": .object(["CUSTOM": .string("private-value")])]),
      .object(["headers": .object(["X-Custom": .string("private-value")])]),
    ]
    for setting in privateValues {
      var value = pack()
      value.languageServer?.initializationOptions = .array([setting])
      XCTAssertThrowsError(try value.portableData())
      value.languageServer?.initializationOptions = nil
      value.languageServer?.settings = setting
      XCTAssertThrowsError(try value.portableData())
      value.languageServer?.settings = nil
      value.debugger = .init(
        adapterID: "fixture", command: .init(executable: "fixture-dap"), launch: ["nested": setting]
      )
      XCTAssertThrowsError(try value.portableData())
    }
  }

  func testPortablePlaceholdersAndOrdinaryOptionsAreRetained() throws {
    var value = pack()
    value.languageServer?.command.arguments = [
      "--root=${workspace}", "--config=relative/settings.json",
    ]
    value.languageServer?.settings = .object([
      "semanticTokens": .object(["enabled": .bool(true)]),
      "endpoint": .string("https://example.invalid/lsp"),
    ])
    value.debugger = .init(
      adapterID: "fixture", command: .init(executable: "fixture-dap"),
      launch: [
        "program": .string("${workspace}/target/debug/sample"),
        "args": .array([.string("relative/input")]), "env": .object([:]),
      ])
    XCTAssertEqual(try LanguagePackRegistry.decode(value.portableData()), value)
  }

  func testInlineHighlightQueryRoundTripAndBounds() throws {
    var value = pack()
    value.associations[0].grammarID = "rust"
    value.associations[0].highlightQuery = "(identifier) @variable\n; Unicode: λ 🦀 e\u{301}\r\n"
    let bytes = try JSONEncoder().encode(value)
    XCTAssertEqual(try LanguagePackRegistry.decode(bytes), value)
    XCTAssertEqual(try LanguagePackRegistry.decode(value.portableData()), value)
    value.associations[0].highlightQuery = String(repeating: "x", count: 1_048_577)
    XCTAssertThrowsError(try value.validate())
    value.associations[0].highlightQuery = "(identifier) @variable\0"
    XCTAssertThrowsError(try value.validate())
    value.associations[0].highlightQuery = "(identifier) @variable"
    value.associations[0].grammarID = nil
    XCTAssertThrowsError(try value.validate())
  }
}
