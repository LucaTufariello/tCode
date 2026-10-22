# Setup and supported workflows

## Host and distribution

Validated on macOS 27.0 (26A5425a), Xcode 27.0 (27A266a), Swift 6.4, arm64. `Package.swift` has a hard macOS 27 target. The Swift compiler uses Swift 5 language mode for the current actor/Objective-C boundaries; it still builds with Swift 6.4. Strict Swift 6 concurrency migration remains work. Builds currently emit implicit-strong-capture warnings in asynchronous UI closures; these are disclosed rather than hidden.

`./scripts/build.sh` creates `dist/tCode.app` with the native syntax XPC helper under `Contents/XPCServices`. The signatures are **ad hoc**, verified with `codesign --verify --deep --strict`. No Developer ID distribution signing or notarization was performed. The editor is unsandboxed so project filesystem and development-tool processes work directly; the syntax helper is separately sandboxed and has no workspace or network entitlement. Its worker-only library-validation exception permits curated native grammar modules. App Store distribution, security-scoped bookmark workflows, and production hardened-runtime/notarization workflows have not been validated.

Do not remove quarantine from downloaded software to bypass Gatekeeper. This build is intended for local build-and-run development.

## Tools and GUI discovery

Tool resolution checks configured executable paths, project `.venv/bin`, managed-install receipts, the earlier `tools` environment, Xcode locations, Homebrew, Rust's `.cargo/bin`, and system directories. It builds a GUI-safe PATH instead of depending on Finder inheriting a shell PATH. Open **Settings → Language Support → Installed → Configure…** to override paths. Save, enable/disable, and reload stop existing language sessions; explicitly choose **Editor → Enable Language Tools** to reconnect. An executable being located is not a health guarantee: **Validate** runs version/help probes, and actual workspace connection validates code intelligence.

For a different Xcode/toolchain, configure SourceKit-LSP, swift-format, LLDB DAP, and Swift paths. UserDefaults tool keys remain executable-based, for example `tool.swift`; previous overrides are preserved. **Show Tool Versions and Logs** is available from Language Support and the palette. Some SourceKit-LSP builds expose `--help` rather than `--version`; validation reports that distinction.

## Install only the support you need

Use **Language Support → Catalog → Install…**. The review shows each component's downloads, versions, hashes, prerequisites, destinations, and expected changes. Select optional tools/grammars and choose **Approve Installation**, or use **Configuration Only**. Approval is separate from starting a workspace language server. Cancellation and a failed verification leave previous active versions in place.

Python, C/C++, and Swift configurations are bundled. Rust's starter configuration is installed from Catalog without rebuilding tCode. All four entries currently remain draft: remote tCode pack/grammar assets are prepared but not yet published. Configuration-only installation and separately pinned upstream tool setup remain available. Draft grammar download controls explain why they are unavailable; do not treat a prepared URL as a live installation service. Refreshing a future published catalog caches accepted metadata for offline browsing. Previously installed support works offline.

Managed Python setup requires **CPython 3.12** already installed; it downloads hash-pinned wheels before creating a separate environment. Python, Rust/rustfmt/rust-src, Xcode, and CMake are external prerequisites. tCode neither replaces them nor installs project dependencies. It can reuse a healthy existing tool instead of downloading a duplicate. See [language support and pack authoring](LANGUAGE-SUPPORT.md) and [native grammar setup](SYNTAX.md).

The earlier script remains an explicit alternative:

Optional setup:

```sh
./scripts/setup-tools.sh /opt/homebrew/bin/python3.12
```

Pinned versions are in `tool-requirements.txt`; license metadata is in `python-tool-licenses.json`. The new installer pins compatible wheels in `catalog/python-wheels.json`; a recipe cannot resolve arbitrary new package versions on a user's Mac. No interpreter, language server, adapter, compiler, or grammar is copied into the base app; its native syntax runtime/helper is included. CMake must be installed separately from a trusted source.

## Python

With a Python file active, Build runs `python -m compileall -q .`, Run executes the active Python file, Test runs `python -m pytest -v`, and Discover Tests uses `pytest --collect-only -q`. Results replace the file list under the sidebar title and navigate to matching test definitions; the sidebar's back chevron returns to the files; complete runner output stays in Build Output.

The default interpreter resolution prefers `.venv/bin/python3`, then the managed tools interpreter. Choose another interpreter in Run Configuration. pylsp Jedi receives this interpreter for analysis. **debugpy and pytest must be installed in the chosen interpreter**; tCode never installs them automatically. pylsp and Ruff executables can live in the managed environment independently of project imports.

Choose Enable Language Tools to start pylsp and Ruff. The bundled pack evaluated and uses python-lsp-server 1.15.0. Ruff 0.16.10 provides linting and formatting; linting runs against the buffer through stdin. Select a saved Python source, place a breakpoint after an assignment, and choose Start Debugging. debugpy 1.8.22 runs through the chosen interpreter using `-m debugpy.adapter`.

The managed `python-tools` recipe also includes Black 26.10.0; Ruff is the default formatter. Import a portable pack override to select a different formatter command. Managed tools do not automatically add pytest/debugpy to a separately selected project interpreter.

## C and C++

For a folder with a root `CMakeLists.txt`, Build configures CMake into `build/` with debug symbols and `CMAKE_EXPORT_COMPILE_COMMANDS=ON`, then builds; Test and Discover Tests run CTest against `build/`. Run and Debug launch the program set in Run Configuration (a relative path such as `build/<name>`); choosing either before one is set opens the configuration dialog. The initial configuration assumes a single CMake build directory; presets and multi-configuration generators are outside this implementation.

clangd reads `compile_commands.json`; a database under `build/` is passed explicitly when a language session starts. Build before enabling tools if no database exists. clang-format uses the document path for configuration discovery. LLDB DAP comes from Xcode. The tested sample and native debug adapter are arm64.

`.c` and `.cpp` documents have separate language IDs and grammars within the shared `cpp` pack. `.h` matches both: choose **Editor → Document Language… → C / C++ — c** or **cpp**. An unresolved tie remains ambiguous rather than selecting an arbitrary server language ID.

## Swift

For a folder with a root `Package.swift`, Build, Run, Test, and Discover Tests use SwiftPM (`swift build`, `swift run`, `swift test`, `swift test list`); a Run Configuration executable overrides Run. This Xcode/SwiftPM stores executables under `.build/out/Products/Debug/`; set the Debug program in Run Configuration to the built binary before Start Debugging. Use `swift build --show-bin-path` to confirm the path in another toolchain.

SourceKit-LSP and swift-format come from the chosen Xcode toolchain. SwiftPM executable/library targets and standalone Swift source/debug executables are supported. A real Swift arm64 binary was debugged with Xcode's LLDB DAP. Complete `.xcodeproj`/`.xcworkspace`, signing, simulator, and iOS project integration are not claimed.

## Rust

Install an external Rust toolchain using its supported instructions and add `rustfmt` and `rust-src` components. Install **Rust** from Language Support's Catalog; the configuration is on demand, while rust-analyzer is a separately pinned native arm64 download. Validate the toolchain and language server. A broken rustup shim is reported as unhealthy even if its path exists. Xcode supplies LLDB DAP.

For a disposable project, create an empty folder and run `cargo init --bin` there, then open that folder in tCode. Build/Run/Test/Discover Tests use `cargo build`, `cargo run`, `cargo test`, and `cargo test -- --list`; `Cargo.toml` must be at the workspace root. Open `src/main.rs`, enable language tools, and use completion/diagnostics/definitions. Formatting uses rustfmt with edition 2021 by default; a pack override may set another edition. The default rust-analyzer configuration disables build scripts, procedural macros, and automatic check-on-save execution. Code relying on those features may need an explicitly reviewed custom configuration.

For debugging, build a debug binary, set `.tcode/run.json` `debugProgram` to `target/debug/<package-name>`, put a breakpoint after an assignment in saved source, and choose Start Debugging. Cargo multi-package target selection, inferred debug executables, and a complete Rust-specific debugger experience remain outside the initial integration.

No sample projects are required inside the repository. Create disposable Python/CMake/SwiftPM/Cargo folders for experimentation; the integration tests create their own temporary fixtures.

## Settings and persistence

Global preferences use the app's UserDefaults domain `dev.tufariello.tCode`. Open folders, tabs, layout, breakpoints, and watch expressions restore per workspace. The frame uses native window autosave. Saved layout includes visibility, sidebar width, bottom-panel height, split orientation/count, active document, and caret location. Splits currently display the shared active document; selecting another tab rebuilds the split group.

Create `.tcode/settings.json` for workspace overrides:

```json
{"indentSize": 4, "wrap": true, "exclusions": ["vendor", "generated"]}
```

Exclusions are exact file/folder basenames and apply to lazy browsing, Quick Open, and search/replacement. Default exclusions include `.git`, `.build`, `build`, `node_modules`, `.venv`, `venv`, `__pycache__`, `DerivedData`, and `.tools`. Indexing is capped at 50,000 files; normal search at 10,000 results and 2 MB per file. Symlink directories are shown but not traversed; symlink saves resolve the target and keep the symlink intact.

The supported EditorConfig subset applies hierarchical sections from workspace root to the file's folder using `*`, extension, and path glob patterns, with `indent_style` and numeric `indent_size`. Full EditorConfig `root`, brace expansion, `unset`, charset, end_of_line, trim_trailing_whitespace, and insert_final_newline semantics are deferred. Existing file encodings and line endings are preserved, rather than silently normalized.

Indentation precedence is language-pack defaults, explicit global indentation preferences, workspace settings, then the supported EditorConfig rules. Manual language changes reapply the selected pack's defaults beneath those overrides.

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
