# Setup and supported workflows

## Host and distribution

Validated on macOS 27.0 (26A5425a), Xcode 27.0 (27A266a), Swift 6.4, arm64. `Package.swift` has a hard macOS 27 target. The Swift compiler uses Swift 5 language mode for the current actor/Objective-C boundaries; it still builds with Swift 6.4. Strict Swift 6 concurrency migration remains work. Builds currently emit implicit-strong-capture warnings in asynchronous UI closures; these are disclosed rather than hidden.

`./scripts/build.sh` creates `dist/tCode.app`. The signature is **ad hoc**, verified with `codesign --verify --deep --strict`. An Apple Development identity is present on the development Mac, but no Developer ID distribution signing or notarization was performed. The app is unsandboxed so native project filesystem and development-tool processes work directly. App Store sandboxing, security-scoped bookmark workflows, hardened runtime distribution, and notarization have not been validated.

Do not remove quarantine from downloaded software to bypass Gatekeeper. This build is intended for local build-and-run development.

## Tools and GUI discovery

Tool resolution checks a configured path, project `.venv/bin`, the isolated user tools environment, standard Xcode locations, Homebrew, and system directories. It explicitly builds a GUI-safe PATH and does not depend on Finder inheriting a shell PATH. Paths are editable in Settings → Language Tools. Enable/disable immediately stops existing sessions and reactivates the current enabled pack if workspace activation was requested. Path changes apply when a session is next created; close/reopen the workspace or toggle the pack to restart it.

For a different Xcode/toolchain, set the SourceKit-LSP, swift-format, LLDB DAP, and Swift paths. UserDefaults tool keys use executable names, for example `tool.swift`. The initial UI exposes pack server/formatter/adapter fields; the Swift compiler can also be specified by an executable run configuration. Tool versions and process logs are available from the Command Palette. SourceKit-LSP has no `--version` in this toolchain; associate it with `swift --version`, its selected path, and help output.

Optional setup:

```sh
./scripts/setup-tools.sh /opt/homebrew/bin/python3.12
```

Pinned versions are in `tool-requirements.txt`; license metadata is in `python-tool-licenses.json`. No interpreter, server, adapter, or compiler is copied into the app. Xcode's clangd/SourceKit-LSP/LLDB DAP and the managed Python tools were tested natively. CMake must be installed separately from a trusted source.

## Python

With a Python file active, Build runs `python -m compileall -q .`, Run executes the active Python file, Test runs `python -m pytest -v`, and Discover Tests uses `pytest --collect-only -q`. Results replace the file list under the sidebar title and navigate to matching test definitions; the sidebar's back chevron returns to the files; complete runner output stays in Build Output.

The default interpreter resolution prefers `.venv/bin/python3`, then the managed tools interpreter. Choose another interpreter in Run Configuration. pylsp Jedi receives this interpreter for analysis. **debugpy and pytest must be installed in the chosen interpreter**; tCode never installs them automatically. pylsp and Ruff executables can live in the managed environment independently of project imports.

Choose Enable Language Tools to start pylsp and Ruff. The bundled pack evaluated and uses python-lsp-server 1.15.0. Ruff 0.16.10 provides linting and formatting; linting runs against the buffer through stdin. Select a saved Python source, place a breakpoint after an assignment, and choose Start Debugging. debugpy 1.8.22 runs through the chosen interpreter using `-m debugpy.adapter`.

## C and C++

For a folder with a root `CMakeLists.txt`, Build configures CMake into `build/` with debug symbols and `CMAKE_EXPORT_COMPILE_COMMANDS=ON`, then builds; Test and Discover Tests run CTest against `build/`. Run and Debug launch the program set in Run Configuration (a relative path such as `build/<name>`); choosing either before one is set opens the configuration dialog. The initial configuration assumes a single CMake build directory; presets and multi-configuration generators are outside this implementation.

clangd reads `compile_commands.json`; a database under `build/` is passed explicitly when a language session starts. Build before enabling tools if no database exists. clang-format uses the document path for configuration discovery. LLDB DAP comes from Xcode. The tested sample and native debug adapter are arm64.

## Swift

For a folder with a root `Package.swift`, Build, Run, Test, and Discover Tests use SwiftPM (`swift build`, `swift run`, `swift test`, `swift test list`); a Run Configuration executable overrides Run. This Xcode/SwiftPM stores executables under `.build/out/Products/Debug/`; set the Debug program in Run Configuration to the built binary before Start Debugging. Use `swift build --show-bin-path` to confirm the path in another toolchain.

SourceKit-LSP and swift-format come from the chosen Xcode toolchain. SwiftPM executable/library targets and standalone Swift source/debug executables are supported. A real Swift arm64 binary was debugged with Xcode's LLDB DAP. Complete `.xcodeproj`/`.xcworkspace`, signing, simulator, and iOS project integration are not claimed.

## Settings and persistence

Global preferences use the app's UserDefaults domain `dev.tufariello.tCode`. Open folders, tabs, layout, breakpoints, and watch expressions restore per workspace. The frame uses native window autosave. Saved layout includes visibility, sidebar width, bottom-panel height, split orientation/count, active document, and caret location. Splits currently display the shared active document; selecting another tab rebuilds the split group.

Create `.tcode/settings.json` for workspace overrides:

```json
{"indentSize": 4, "wrap": true, "exclusions": ["vendor", "generated"]}
```

Exclusions are exact file/folder basenames and apply to lazy browsing, Quick Open, and search/replacement. Default exclusions include `.git`, `.build`, `build`, `node_modules`, `.venv`, `venv`, `__pycache__`, `DerivedData`, and `.tools`. Indexing is capped at 50,000 files; normal search at 10,000 results and 2 MB per file. Symlink directories are shown but not traversed; symlink saves resolve the target and keep the symlink intact.

The supported EditorConfig subset applies hierarchical sections from workspace root to the file's folder using `*`, extension, and path glob patterns, with `indent_style` and numeric `indent_size`. Full EditorConfig `root`, brace expansion, `unset`, charset, end_of_line, trim_trailing_whitespace, and insert_final_newline semantics are deferred. Existing file encodings and line endings are preserved, rather than silently normalized.

Workspace run settings:

```json
{
  "executable": "build/app",
  "arguments": [],
  "environment": {},
  "workingDirectory": "",
  "python": "",
  "debugProgram": "build/app"
}
```

Paths may be absolute or relative to the workspace; an empty working directory means the workspace. Run Configuration edits use one argument or environment assignment per line. A folder's configuration is read without executing it. Build/run/test/debug require an explicit user command. No shell expansion is applied to task arguments.

Recovery checkpoints are private local JSON files in `~/Library/Application Support/tCode/Recovery` (directory 0700, records 0600). Changed buffers checkpoint after 350 ms; an immediate power loss can lose that debounce interval. Quit checkpoints synchronously through an asynchronous termination handshake. Reload keeps a modified old buffer as an untitled recovery record. Save compares original disk bytes and rejects a changed/missing file; comparison, reload, or Save a Copy is required. Atomic writes preserve POSIX mode bits; ACLs, extended attributes, coordinated cloud saves, and a race with an external writer during the final atomic write are limitations.
