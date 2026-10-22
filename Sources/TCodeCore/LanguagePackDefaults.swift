import Foundation

extension LanguagePack {
  /// V1 conversion keeps the existing three integrations while runtime behavior becomes data driven.
  public static func legacy(
    id: String, name: String, extensions: [String], server: String, serverArguments: [String],
    formatter: String, adapter: String
  ) -> Self {
    var result = LanguagePack(
      id: id, name: name, associations: [.init(languageID: id, extensions: extensions)],
      languageServer: server.isEmpty
        ? nil : .init(command: .init(executable: server, arguments: serverArguments)),
      formatterCommand: formatter.isEmpty ? nil : .init(executable: formatter))
    switch id {
    case "python":
      result.associations = [
        .init(
          languageID: "python", extensions: extensions,
          firstLinePattern: #"^#!.*\bpython[0-9.]*\b"#, grammarID: "python")
      ]
      result.editor = .init(
        lineComment: "#",
        snippets: [
          .init(name: "Function", text: "def name():\n    pass\n"),
          .init(name: "Main guard", text: "if __name__ == \"__main__\":\n    main()\n"),
        ])
      result.languageServer?.settings = .object([
        "pylsp": .object([
          "plugins": .object(["jedi": .object(["environment": .string("${python}")])])
        ])
      ])
      result.formatterCommand = .init(
        executable: formatter, arguments: ["format", "--stdin-filename", "${file}", "-"])
      result.tasks = [
        "run": .init(steps: [.init(executable: "${python}", arguments: ["${file}"])]),
        "build": .init(steps: [
          .init(executable: "${python}", arguments: ["-m", "compileall", "-q", "."])
        ]),
        "test": .init(
          steps: [.init(executable: "${python}", arguments: ["-m", "pytest", "-v"])],
          resultParser: "pytest"),
        "discoverTests": .init(
          steps: [
            .init(executable: "${python}", arguments: ["-m", "pytest", "--collect-only", "-q"])
          ], resultParser: "pytest"),
      ]
      result.debugger = .init(
        adapterID: "python",
        command: .init(executable: "${python}", arguments: ["-m", "debugpy.adapter"]),
        launch: [
          "program": .string("${file}"), "console": .string("internalConsole"),
          "justMyCode": .bool(true), "python": .array([.string("${python}")]),
        ])
      result.diagnosticAdapter = "ruff"
      result.toolRecipeIDs = ["python-tools"]
    case "cpp":
      result.associations = [
        .init(
          languageID: "c", extensions: extensions.filter { ["c", "h"].contains($0) }, grammarID: "c"
        ),
        .init(
          languageID: "cpp", extensions: extensions.filter { !["c", "h"].contains($0) } + ["h"],
          grammarID: "cpp"),
      ]
      result.editor = .init(
        lineComment: "//",
        snippets: [
          .init(name: "Function", text: "void name() {\n    \n}\n"),
          .init(name: "Main", text: "int main() {\n    return 0;\n}\n"),
        ])
      result.languageServer?.command.arguments.append("--compile-commands-dir=${buildDir}")
      result.languageServer?.rootMarkers = ["CMakeLists.txt", "compile_commands.json"]
      result.formatterCommand = .init(
        executable: formatter, arguments: ["--assume-filename=${file}"])
      result.tasks = [
        "build": .init(
          steps: [
            .init(
              executable: "cmake",
              arguments: [
                "-S", ".", "-B", "build", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                "-DCMAKE_BUILD_TYPE=Debug",
              ]), .init(executable: "cmake", arguments: ["--build", "build"]),
          ], rootMarkers: ["CMakeLists.txt"]),
        "test": .init(
          steps: [
            .init(executable: "ctest", arguments: ["--test-dir", "build", "--output-on-failure"])
          ], rootMarkers: ["CMakeLists.txt"], resultParser: "ctest"),
        "discoverTests": .init(
          steps: [.init(executable: "ctest", arguments: ["--test-dir", "build", "-N"])],
          rootMarkers: ["CMakeLists.txt"], resultParser: "ctest"),
      ]
      result.debugger = .init(adapterID: "lldb", command: .init(executable: adapter))
      result.toolRecipeIDs = ["xcode-tools", "clang-format"]
    case "swift":
      result.associations = [.init(languageID: "swift", extensions: extensions, grammarID: "swift")]
      result.editor = .init(
        lineComment: "//",
        snippets: [
          .init(name: "Function", text: "func name() {\n    \n}\n"),
          .init(name: "Section", text: "// MARK: - \n"),
        ])
      result.languageServer?.rootMarkers = ["Package.swift"]
      result.formatterCommand = .init(executable: formatter, arguments: ["format"])
      result.tasks = [
        "build": .init(
          steps: [.init(executable: "swift", arguments: ["build"])], rootMarkers: ["Package.swift"]),
        "run": .init(
          steps: [.init(executable: "swift", arguments: ["run"])], rootMarkers: ["Package.swift"]),
        "test": .init(
          steps: [.init(executable: "swift", arguments: ["test"])], rootMarkers: ["Package.swift"],
          resultParser: "swift"),
        "discoverTests": .init(
          steps: [.init(executable: "swift", arguments: ["test", "list"])],
          rootMarkers: ["Package.swift"], resultParser: "swift"),
      ]
      result.debugger = .init(adapterID: "lldb", command: .init(executable: adapter))
      result.toolRecipeIDs = ["xcode-tools"]
    default:
      if !adapter.isEmpty {
        result.debugger = .init(adapterID: id, command: .init(executable: adapter))
      }
    }
    return result
  }

  public static var rust: LanguagePack {
    LanguagePack(
      id: "rust", name: "Rust",
      associations: [.init(languageID: "rust", extensions: ["rs"], grammarID: "rust")],
      editor: .init(
        lineComment: "//",
        snippets: [
          .init(name: "Function", text: "fn name() {\n    \n}\n"),
          .init(name: "Main", text: "fn main() {\n    \n}\n"),
        ]),
      languageServer: .init(
        command: .init(executable: "rust-analyzer"),
        initializationOptions: .object([
          "cargo": .object(["buildScripts": .object(["enable": .bool(false)])]),
          "procMacro": .object(["enable": .bool(false)]), "checkOnSave": .bool(false),
        ]), rootMarkers: ["Cargo.toml"]),
      formatterCommand: .init(executable: "rustfmt", arguments: ["--edition", "2021"]),
      tasks: [
        "build": .init(
          steps: [.init(executable: "cargo", arguments: ["build"])], rootMarkers: ["Cargo.toml"]),
        "run": .init(
          steps: [.init(executable: "cargo", arguments: ["run"])], rootMarkers: ["Cargo.toml"]),
        "test": .init(
          steps: [.init(executable: "cargo", arguments: ["test"])], rootMarkers: ["Cargo.toml"],
          resultParser: "cargo"),
        "discoverTests": .init(
          steps: [.init(executable: "cargo", arguments: ["test", "--", "--list"])],
          rootMarkers: ["Cargo.toml"], resultParser: "cargo"),
      ], debugger: .init(adapterID: "lldb", command: .init(executable: "lldb-dap")),
      toolRecipeIDs: ["rust-toolchain", "rust-analyzer"])
  }
}
