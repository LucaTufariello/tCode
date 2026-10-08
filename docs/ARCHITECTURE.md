# Architecture and native API decisions

Two cohesive Swift modules make up the app:

- **TCodeCore** contains encoding/atomic filesystem operations, Unicode position conversion, bounded lazy indexing/search, review plans, recovery storage, process lifecycle, Content-Length protocol transport, Git operations, and test-output parsing. It has no UI dependency.
- **TCode** owns AppKit windows, native menus/panels, the editor and document pool, language-pack registration, LSP feature presentation, task/debug/Git workflows, SwiftTerm PTY views, and SwiftUI Settings.

## Documents and editor

`CodeDocument` owns one `NSTextStorage`, version, original bytes, encoding/BOM, shared UndoManager, recovery checkpoint, and language session. Split panes attach independent layout managers/text containers to that storage. Edits mutate native storage ranges; typing does not replace the entire buffer. The document pool canonicalizes symlink paths so the same file shares state across windows.

AppKit **NSTextView with TextKit 1** was selected deliberately. It provides mature native input methods, marked text, find/replace, selection, drag/drop, accessibility, and undo behavior, and supports attaching multiple layout managers to shared storage. A small native prototype and tests validated shared text/undo, multi-cursor insertion with IME fallback, Unicode, range edits, and large-file loading. TextKit 2's newer layout model would need a different shared document/layout implementation and was not adopted without validation. The choice is not a claim that TextKit 1 outperforms TextKit 2.

A native ruler draws visible line numbers and breakpoints. Syntax colors are temporary layout attributes from a debounced background regex scan, not a parser or semantic-token system. This is adequate for initial editing but handles complex multiline syntax incompletely. Tree-sitter was not justified by a measured bottleneck in the current fixture; an incremental parser remains a future correctness/performance improvement. Folding suppresses selected glyphs without deleting document text. Native IME stays authoritative; secondary cursors clear when composition begins.

At **2,000,000 UTF-16 units**, large-file mode disables syntax scans, bracket searches, and LSP activation. Plain native editing and saving remain available. The measured 10.5 MB load covers decoding/storage, not full-document layout or scroll performance. Search skips files above 2 MB; indexing is capped at 50,000 paths; normal search returns at most 10,000 hits. Replacement scans all indexed eligible files and rejects a preview above 64 MB instead of applying a silently truncated plan.

## Tool processes and protocols

The native transport incrementally parses Content-Length messages with bounded headers/bodies. Actors serialize request IDs, matching, cancellation, timeout, errors, and notifications. Independent ordered reader and event streams allow DAP stopped-event handlers to issue requests without blocking response consumption. Server-initiated LSP file edits are sent through the same native review/preflight flow as rename/code actions. Unsupported resource operations are rejected. Advertised server commands require a concrete user review before execution.

The LSP layer negotiates UTF-16/UTF-8 positions (with UTF-32 mapping available), tracks versions, synchronizes the current text before requests, and drops stale results. Full-content change events are valid LSP synchronization messages; this implementation does not send minimal incremental deltas. Completion edits, including additional text edits, share one undo group. It advertises no snippet insertion support. Diagnostics and output locations are navigable. Ruff and server diagnostics are retained separately and merged so an empty server update cannot clear lint findings. Ruff scalar columns are converted to the negotiated LSP encoding; this was checked with a buffer containing a multi-scalar emoji.

Version-1 bundled JSON manifests register the three first-party packs through `Bundle.module`. They define extensions, LSP executable/arguments, formatter, and adapter. Pack registration is working discovery, not a general binary/plugin host. Tools activate only after explicit workspace enablement or an explicit language feature command. No VS Code extension package or Marketplace request occurs.

`RunningProcess` performs blocking pipe reads off the UI thread, streams stdout/stderr, writes stdin concurrently, checks cancellation before/after launch, and signals its own child process group with TERM then KILL. Background search forwards parent cancellation to detached work. Formatters use stdout separately so stderr cannot become source text. Protocol sessions request orderly shutdown/disconnect. Quit awaits workspace shutdown before replying to AppKit; normal workspace closure cancels tools and terminal sessions.

Git invokes `/usr/bin/git` directly with argument arrays and parses NUL-delimited porcelain status, including rename records. It does not interpolate filenames or commit text into shell commands. Branch switching requires saved buffers and a clean Git workspace, then reloads clean documents. Unmerged files block commits.

## macOS 27 design

Verified against the installed macOS 27 SDK headers and Apple's current documentation:

- Native `NSToolbar`, `NSSplitViewController`, sidebar/inspector split items, and scroll views adopt system toolbar/sidebar and scroll-edge behavior. The code surface uses opaque `textBackgroundColor`.
- `NSGlassEffectView.effectIsInteractive` (macOS 27) is used on the small bottom-panel control header. It provides system Liquid Glass interaction without turning the editor into a translucent surface.
- `NSView.cornerConfiguration` and `.uniformCorners(radius: .containerConcentric(8))` (macOS 27) give that control container concentric system corners.
- SwiftUI Settings, system colors/fonts/SF Symbols, native dialogs/context menus, system focus rings, and standard accessibility controls retain platform behavior.

No custom continuous animation or rendering loop is used. System material/color behavior is used for accessibility preferences. Full VoiceOver and accessibility-setting audits are not claimed; see the validation matrix. The original AppKit-generated app icon is delivered as an `.icns` asset; layered Icon Composer variants are deferred.

References: [AppKit modernization, WWDC26](https://developer.apple.com/videos/play/wwdc2026/289/), [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass), [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/), [app icons](https://developer.apple.com/design/human-interface-guidelines/app-icons), [LSP 3.17](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/), [DAP](https://microsoft.github.io/debug-adapter-protocol/specification), [VS Code extension host runtimes](https://code.visualstudio.com/api/advanced-topics/extension-host), [VS Code extension FAQ](https://code.visualstudio.com/docs/supporting/faq#_extensions).
