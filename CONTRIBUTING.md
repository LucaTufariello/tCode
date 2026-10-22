# Contributing to tCode

tCode targets macOS 27 on Apple Silicon with Xcode 27 / Swift 6.4. Keep the application native: AppKit/SwiftUI, native text editing and PTY, local processes, and offline core behavior. Preserve save protection, shared undo, recovery, reviewed workspace edits, and process cancellation when changing language features.

## Source map

| Area | Entry points |
|---|---|
| Configuration interface, migration, recognition | `Sources/TCodeCore/LanguagePack.swift`, `LanguagePackDefaults.swift`, `LanguagePackRegistry.swift` |
| Catalog, installation plans, ownership and health | `Sources/TCodeCore/LanguageCatalog.swift`, `ToolInstaller.swift`, `ToolHealth.swift`, `PythonWheelLock.swift` |
| Native settings and document selection | `Sources/TCode/LanguageSupportView.swift`, `LanguageRuntime.swift`, `WorkspaceWindow.swift` |
| LSP, formatting, tasks and DAP | `Sources/TCode/LanguageTools.swift`, `Commands.swift`, `TasksAndGit.swift`, `DebugSession.swift` |
| Native syntax transport and installation | `Sources/TCodeCore/SyntaxConnection.swift`, `SyntaxProtocol.swift`, `SyntaxInstaller.swift` |
| Syntax worker and editor integration | `Sources/TCodeSyntax/NativeSyntaxParser.swift`, `TCodeSyntaxService/main.swift`, `TCode/SyntaxClient.swift`, `TCode/Editor.swift` |

The versioned configuration interface is documented in [Language Support](docs/LANGUAGE-SUPPORT.md). Begin with a small imported data pack and real upstream tools. Recognition, highlighting, intelligence, formatting, tasks, and debugging are separate capabilities; declare and test only those the pack actually supplies. Additional configurations using the supported interface need no app rebuild. A new executable installer recipe requires reviewed application code.

## Build and verify

Build early after substantial Swift changes:

```sh
swift build --arch arm64
swift test --arch arm64
```

Ordinary tests explicitly skip optional integrations and measurements. The release checks require actual Python tools, CMake/clang-format, Rust with rustfmt/rust-src, and Xcode language/debug tools. Configure discovery through supported tool paths rather than relying on a shell-only PATH. Tests create temporary projects, including paths with spaces and Unicode; repository example projects are unnecessary.

For complete local evidence, generate optional grammar artifacts and run:

```sh
python3 scripts/build-grammars.py
TCODE_INTEGRATION=1 \
TCODE_DOWNLOAD_INTEGRATION=1 \
TCODE_GRAMMAR_FIXTURES="$PWD/dist/grammar-artifacts" \
TCODE_EDITOR_METRICS="$PWD/artifacts/language-editor-metrics.json" \
TCODE_SEARCH_METRICS="$PWD/artifacts/language-search-metrics.json" \
swift test --arch arm64
./scripts/build.sh
./scripts/test-syntax-service.sh
python3 scripts/verify-release.py
git diff --check
```

Grammar generation needs the developer compiler and network access. Users install prebuilt modules; they do not compile grammars. The packaged probe uses the exact signed worker in `dist/tCode.app` and checks actual workspace/network denial and crash recovery. Do not replace these checks with mocks when reporting release acceptance. Record skipped checks, tool versions, actual results, and measurement limits in [validation](docs/VALIDATION.md).

## Catalog and release changes

After changing bundled defaults, run `./scripts/generate-language-packs.sh` and review the generated configuration and hashes. Keep grammar runtime/ABI, source revisions, query versions, architecture, signatures, and licenses pinned together. Imported packs may supply declarative query data and reference curated grammars; they cannot add arbitrary native modules or installer scripts.

`python3 scripts/prepare-language-release.py` assembles local review assets without publishing. Follow [catalog maintenance](catalog/README.md): review artifacts first, obtain publication approval, validate the public downloads/installations, then publish the accepted catalog. Preserve old versioned assets and working installations. Draft entries must continue to identify unavailable downloads honestly.

`scripts/verify-release.py` creates a local ZIP, checks the executable inventory and worker entitlements, extracts into a fresh folder, compares every file hash, and verifies signatures again. Ad hoc development signatures do not complete Developer ID distribution or notarization.

Update the [feature matrix](docs/STATUS.md), dependency notices, and actual screenshots when behavior changes. AI chat, coding agents, provider APIs, and the language-setup skill belong to the following release; avoid inactive controls or an AI dependency in this foundation.
