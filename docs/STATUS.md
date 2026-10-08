# Feature/status matrix — tCode 0.1

**Implemented** means a working initial implementation exists; it does not imply exhaustive production validation. **Partial** identifies material limits. **Deferred** means it is not delivered. Evidence is in [VALIDATION.md](VALIDATION.md), tests, and actual UI screenshots. Optional tools remain external.

| Area | Status | Behavior and boundaries |
|---|---|---|
| Native macOS 27 / arm64 app | Implemented | AppKit/SwiftUI, native text/terminal, no web/JS runtime; Release app and ad hoc signature verified. |
| Native toolbar, sidebar, panel, inspector | Implemented | Resizable/collapsible split views, Files/Search/Git/Run, tabs, Terminal/Problems/Build Output/Debug Console. System Liquid Glass control header, macOS 27 interactive effect/concentric corners. |
| Multiple windows, full screen, recent folders | Implemented | Native window/menu behavior and per-workspace restoration. Full-screen entry is a standard AppKit operation; extended multi-display restoration is untested. |
| File operations | Implemented | Native create project/files/nested folders, rename/move/duplicate/Trash/reveal/copy path, sidebar drag moves, collision/symlink validation, lazy tree and watchers. Trash preserves open text as untitled. |
| External rename/delete tracking | Partial | In-app moves update document paths and close/reopen services. External writes/rename/delete are detected and save rejects conflicts; arbitrary external renames are not automatically resolved to a new path. |
| Untitled, Save/As/All, undo, autosave | Implemented | Shared document UndoManager, atomic save with original-byte check, modified tabs, native panels, opt-in autosave. New buffers keep native editing. |
| Crash recovery and external conflict | Implemented | Private debounced recovery records; actual SIGKILL/relaunch recovery tested. Comparison and Save a Copy preserved both versions in a native workflow. |
| Text formats and file metadata | Partial | UTF-8 with/without BOM and BOM-marked UTF-16 LE/BE round-trip; line endings preserved. Unsupported/binary encodings safely rejected. ACL/xattr preservation/cloud coordination not implemented. |
| Native editor / input | Implemented | NSTextView/TextKit 1 range edits, Unicode/emoji/combining text, marked-input fallback, shared storage/undo across splits, visible gutter/current line/brackets. |
| Highlighting | Partial | Debounced background regex colors; multiline grammar, semantic tokens, Tree-sitter and incremental parsing deferred. |
| Indentation/wrap/comments/line ops | Implemented | Configurable tabs/spaces/wrapping, newline indent, comment toggle, duplicate line, basic per-language snippet insertion. |
| Multiple selections/cursors | Partial | Native multiple selections plus added insertion cursors above/below; insertion and IME fallback tested. Secondary-cursor deletion/movement and full snippet tab-stop sessions are deferred. |
| Folding | Partial | Fold selected text / unfold all without modifying source. Parser-derived fold ranges, gutter fold affordances, persistent folds deferred. |
| Find/regex, Quick Open, palette | Implemented | Native find/replace, regex replacement, fuzzy keyboard list, go-to-line, symbol navigation, back navigation. Forward history and richer navigation UI deferred. |
| Workspace search/replace | Implemented | Background bounded search with exclusions; reviewed multi-file byte preflight/rollback. Preview is a before/after text view, not a diff hunk editor. 50k indexed-file / 2 MB file / 64 MB replacement preview limits. |
| Split document state | Partial | Shared text and undo with horizontal/vertical panes; selecting a tab rebuilds panes around the active document. Independent documents per split and per-pane tab groups are deferred. |
| Native first-party language packs | Implemented | Versioned manifest discovery/registration for Python, C/C++, Swift. Enable/disable, paths, logs, missing-tool feedback. No arbitrary third-party code host. |
| Python | Implemented | Interpreter/.venv selection, real pylsp + Ruff, buffer lint/format, debugpy, pytest. Selected interpreter must contain debugpy/pytest; no automatic installation. |
| C/C++ | Implemented | clangd, compile_commands.json, CMake Debug build, clang-format, CTest, LLDB DAP. CMake presets/multi-config and arbitrary build systems deferred. |
| Swift | Implemented | SourceKit-LSP, swift-format, SwiftPM build/run/list/test, real Swift LLDB. SwiftPM and standalone source/executables supported; full Xcode project integration deferred. |
| LSP navigation/features | Implemented | Capability checks, completion + additional edits, hover/signature presentation, definition/references/symbols, diagnostics, reviewed rename/code actions, local advertised server commands. |
| Full LSP feature coverage | Partial | Full text sync, version/stale checks, encodings, cancellation/timeouts/failures. Resource create/rename/delete edits rejected; completion resolve, snippets, arbitrary dynamic capabilities, semantic tokens and richer in-editor popovers deferred. |
| PTY terminal | Implemented | SwiftTerm 1.20.0, interactive zsh, correct cwd, ANSI color/resize, selection/copy/paste, multiple switchable sessions. Primary interactive/cwd/color/resize behavior verified. |
| Run/build/test configurations | Implemented | Explicit execution only; executable/arguments/env/cwd/interpreter/debug target; output/exit status/cancel/process-group cleanup. Single saved run configuration per workspace. |
| Test discovery/result navigation | Partial | pytest/SwiftPM/CTest discovered/result rows and best-effort source navigation; full logs/error links. No hierarchical result tree, persistent history, parameter-specific location metadata, or per-test rerun yet. Unknown runner formats stay in output. |
| DAP debugger | Implemented | Verified Python/C++/Swift adapters, breakpoints, continue/pause/step, stack selection, expandable variables, saved watch expressions, console. All three reached answer=42 in automated and native UI checks. |
| Debugger polish | Partial | Uses native list sheets and Run actions; no persistent debugger tree, inline value rendering, conditional/log breakpoints, attach, or runInTerminal reverse request. Debug targets must be saved. |
| Git | Implemented | Real branch/status, diff, stage/unstage/commit/history, clean-branch switch. Conflicts block commits and dirty workspace blocks switch. Native stage/commit tested in a temporary repository. |
| Git advanced conflict workflows | Deferred | No merge/rebase UI, interactive hunk staging, credential manager, push/pull UI, or conflict resolution editor. Git error text remains visible. |
| Global/workspace settings | Implemented | Font/size/indent/autosave/appearance, tools, selected menu shortcut overrides, `.tcode/settings.json` exclusions/wrap/indent. Font preferences apply to new panes. |
| EditorConfig | Partial | Hierarchical `indent_style`/numeric `indent_size` and common glob sections. Remaining EditorConfig specification is explicitly deferred. |
| Appearance/accessibility | Partial | System light/dark/accent/materials, standard focus/accessibility roles/labels, native menus and keyboard workflows tested. Full VoiceOver, Full Keyboard Access, Increase Contrast, Reduce Transparency/Motion interaction audit remains unverified. |
| Performance | Implemented measurement | Actual hardware startup/RSS, native insertion/layout, lazy tree/index/search and large decode/storage metrics recorded; no unsupported screen latency or sustained large-file scrolling claims. |
| Privacy/offline | Implemented | Core editing offline, no account/telemetry/source upload. External tools may have their own behavior and are explicitly enabled. |
| Themes/snippet import from VS Code | Deferred | Basic bundled snippets only. No VSIX execution, Marketplace access, restricted packages, or general VS Code compatibility claim. Optional declarative import was not needed for the initial runnable release. |
| Packaging/signing | Partial | Launchable arm64 app, resources/icon/licenses, verified ad hoc signature. Developer ID/notarization/App Store workflows require a distribution phase and have not been performed. |

Remaining correctness risks: disk-byte preflight cannot prevent another program changing the file in the final write interval; unexpected disk failures during rollback can require manual recovery; complex shared multi-window document lifecycle and external directory moves need broader testing. Tests and the reviewed-plan safeguards cover the common path, not every filesystem/provider behavior.
