# Validation and measured performance

Validated **2026-10-08** on an Apple M2 MacBook Air (Mac14,2), 8 CPU cores, 8 GB RAM, macOS 27.0 build 26A5425a, Xcode 27.0 build 27A266a, Swift 6.4, arm64. These are local hardware measurements and tested initial workflows, not a production-readiness certification.

## Automated validation

Final functional/integration command:

```sh
TCODE_INTEGRATION=1 swift test --arch arm64
```

**26 functional/integration tests passed, zero failures.** XCTest reports 28 cases across two executables, with the two opt-in benchmark cases intentionally skipped in this final functional run. The core executable has 13 functional cases, 1 optional benchmark, and 6 live protocol/tool integrations. The editor executable has 7 functional/application cases (including a real pylsp/Ruff diagnostics pipeline) and 1 optional benchmark. Raw evidence: `artifacts/final-tests.log`.

Both opt-in benchmarks were also run successfully on this machine with the flags below; their measured output is retained in the metrics JSON files. The final functional run includes native Undo/Redo routing and the close/move diagnostic regression assertions. Benchmarks are opt-in to keep ordinary tests independent of timing and hardware.

```sh
TCODE_INTEGRATION=1 \
TCODE_SEARCH_METRICS="$PWD/artifacts/search-metrics.json" \
TCODE_EDITOR_METRICS="$PWD/artifacts/editor-metrics.json" \
swift test --arch arm64
```

Core coverage includes encodings/BOM/line endings, UTF-8/UTF-16/UTF-32 positions, CR/CRLF navigation, collision/move/symlink behavior, external save protection, recovery metadata, malformed/fragmented/combined protocol frames, reviewed replacement preflight, process cancellation including descendants, dead/cancelled protocol requests, actual Git stage/commit, test result formats, and project-search measurements. Editor coverage includes native Undo/Redo command routing, shared split text/undo, source-preserving folding, multiple insertion cursors/IME fallback, conflicting saves, completion additional edits as one undo transaction, typing/large-load measurements, and a real pylsp/Ruff diagnostic merge with emoji position mapping.

Live integrations exercise the actual tools:

| Tool | Verified evidence |
|---|---|
| pylsp + Ruff | Real completion (84 items), definition (1), diagnostics (2) on a temporary Python fixture. |
| clangd | Real completion (6), definition (1), diagnostics (2) on a C++ fixture. |
| SourceKit-LSP | Real completion (31), definition (1), diagnostics (1) on a Swift fixture. |
| debugpy | Verified breakpoint; paused variables contain `answer = 42`. |
| LLDB DAP / C++ | Compiled arm64 debug binary; verified breakpoint and `answer = 42`. |
| LLDB DAP / Swift | Compiled arm64 debug binary; verified breakpoint and `answer = 42`. |

Numbers describe these fixtures, not promises about other server versions. One early LLDB cold-start check exceeded the original 10-second fixture wait; the initialization allowance was corrected to 30 seconds, and the final full runs passed.

## Native end-to-end checks

The actual AppKit application was operated through its menus, controls, editor, panels, and command palette. [Dark release screenshot](../artifacts/dark.png), [light release screenshot](../artifacts/light.png), [Python debugger](../artifacts/debugger.png), [C++ debugger](../artifacts/cpp-debugger.png), [Swift debugger](../artifacts/swift-debugger.png), and [diagnostics](../artifacts/diagnostics.png) show the running app:

- Created `artifacts/UITestProject` and nested `Sources/hello.py` entirely through native UI. Typed/saved/reopened emoji, accented text, and a combining character with unchanged bytes.
- Ran Python compileall, the sample program, and pytest: exit 0 and one passing test.
- Built C++ through CMake, ran the executable, and ran CTest: exit 0 and one passing test.
- Built/ran/tested SwiftPM: exit 0 and one passing XCTest.
- Set native gutter/keyboard breakpoints and used the native variables list to inspect `answer = 42` in Python, C++, and Swift.
- Used interactive PTY zsh with ANSI green output, correct workspace `pwd`, and `stty size` after native resizing. This was terminal input/output, not a subprocess log view.
- Staged and committed `main.py` in `artifacts/UITestGit` through native actions. Commit `9047a86`, with a clean working tree afterward. No network operation occurred.
- Verified native Command-Z Undo and Command-Shift-Z Redo, then restored the probe without saving.
- Verified Quick Open fuzzy filtering waits for Return; checked native light and dark appearance and accessible editor/control labels in the accessibility tree.
- Verified crash recovery by inspecting the checkpoint, sending SIGKILL to the development app, and relaunching. The unsaved Unicode buffer returned in the native editor. An external disk change then caused Save to reject the conflict. Compare showed both versions; Save a Copy retained the recovered buffer separately and left the external disk version intact. Evidence: `artifacts/recovery-result.json`, `artifacts/external-conflict.png`, and both fixture files.

`artifacts/ui-validation.json` records these checks. Screenshots include the packaged release editor/terminal, light appearance, and the native Python/C++/Swift variable inspectors. Earlier inspector/conflict screenshots were captured in the debug app; the final editor/terminal screenshots use the packaged release.

## Measured performance

| Measurement | Dataset and result |
|---|---|
| Warm startup to first native window layout | Five Release launches, Python example workspace; median **295.8 ms**. |
| Idle resident memory | Same five runs, sampled after one second, no language server/debugger/terminal; median **110.5 MiB RSS**. |
| Native edit/layout work | 160,000-byte, 10,000-line file; 100 native NSTextView insertions plus visible-region layout; median **0.562 ms**, p95 **0.635 ms**. |
| Initial full text layout | Same 10,000-line file: **229.5 ms**. |
| Large-file decode/storage | 10,500,000-byte source fixture: **70.3 ms**; large-file mode enabled. |
| Lazy root listing | 1,000 source files / 10 source folders plus an excluded dependency folder: **0.291 ms**. |
| Bounded file index | 1,000 included source files, 100 `node_modules` files excluded: **6.30 ms**. |
| Project search stress fixture | 2.1 MB source, 60,000 hits with an intentionally raised benchmark cap: **2416.0 ms**. Normal UI search caps at 10,000 hits. |

Raw data: `artifacts/launch-metrics.json`, `artifacts/editor-metrics.json`, `artifacts/search-metrics.json`. Startup is process start to the first layout, not full document restoration or screen-present latency. RSS is not physical footprint and excludes separately launched tools. The edit benchmark runs a native text view in the test host; it does not measure keystroke-to-display latency, sustained scrolling, or a fully populated IDE with language tools. Large loading measures decode/storage only. File-cache warmth, background system work, and build mode affect timings. No Metal rendering claim is made.

Reproduce startup/RSS after building, with other tCode instances closed:

```sh
python3 scripts/measure-launch.py
```

The script uses a temporary isolated recovery directory and a fixture workspace, runs five local launches without activating project tasks, and terminates those measurement processes after sampling. It does not change system settings.

## Package verification

`artifacts/package-verification.json` records the executable hash, linked libraries, Mach-O inventory, deployment version, and signature. The app executable is **arm64**, minimum macOS **27.0**. It contains no bundled native helper executables. SwiftTerm is linked natively and its resource bundle, the language manifests, icon, and dependency notices are under Contents/Resources. Strict deep codesign verification passed with **Signature=adhoc**. The final ZIP was extracted to a fresh temporary folder; its executable hash matched the app, and strict signature verification passed again. No Developer ID signing, notarization, App Store sandbox, or installation on a second Mac was performed.

## Remaining validation boundaries

A full VoiceOver interaction pass, Full Keyboard Access audit, Increase Contrast and Reduce Transparency/Motion setting matrix, multiple-display restoration, cloud/network filesystems, ACL/xattr handling, extensive multicursor deletion/IME languages, arbitrary external directory renames, very large sustained editing, and complete LSP server capability variants remain unverified or partial. The feature matrix labels these limits. The app uses system materials/colors/focus and no continuous animations, but that is not evidence of a completed accessibility audit.
