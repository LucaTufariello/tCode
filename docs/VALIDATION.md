# Validation and measured performance

Language-foundation validation performed **2026-10-21–22** on the same Apple M2 MacBook Air (Mac14,2), 8 CPU cores, 8 GB RAM, macOS 27.0 build 26A5425a, Xcode 27.0 build 27A266a, Swift 6.4, arm64 used for the original baseline. These are local measurements and tested workflows, not a production-readiness certification or a completed public release.

## Automated evidence

The final consolidated run enabled real integration/download tools, generated grammar fixtures, and editor/search measurements. [language-release-tests.log](../artifacts/language-release-tests.log) reports **89 executed XCTest cases, zero failures, zero skips**: 68 Core cases, 17 editor/runtime/client cases, and 4 syntax cases. Packaged XPC probes and native UI checks are additional evidence, outside that XCTest count.

Focused logs document the regressions now included in that complete invocation:

| Evidence | Result |
|---|---|
| [language-catalog-update-tests.log](../artifacts/language-catalog-update-tests.log) | An older bundled configuration cannot shadow a published pack update. |
| [language-migrated-workflows.log](../artifacts/language-migrated-workflows.log) | Real Python, C/C++, and Swift v2 build/run/test/discovery/formatting. |
| [language-xcode-reuse.log](../artifacts/language-xcode-reuse.log) | Healthy existing Xcode tools produce an available reuse plan, including a SourceKit-LSP help fallback. |
| [language-rust-native-runtime.log](../artifacts/language-rust-native-runtime.log) | Native app runtime: imported Rust configuration, explicit server enablement, live diagnostics/completion/definition, shared split formatting Undo/Redo, and Cargo build/run/test with a passed navigator row. |
| [language-recognition-guard-tests.log](../artifacts/language-recognition-guard-tests.log) | 17 registry/recognition regressions, including bounded processing for a valid but pathological imported first-line expression. |
| [syntax-packaged-release.log](../artifacts/syntax-packaged-release.log) and [syntax JSON](../artifacts/syntax) | All five grammar modules installed/parsed using the signed packaged XPC helper; isolation and crash-reconnection checks passed. |

Coverage includes v1 migration/v2 round-trip, association ambiguity/manual language/Plain Text choices, workspace isolation, reload/removal, bounded versioned last-good history, unsupported/corrupt/oversized packs, a shared 10 ms progress deadline for imported first-line regular expressions on at most 1,024 characters, portable export privacy checks, placeholder argument boundaries, and no execution during import. Native runtime tests exercise an external formatter/shared undo and sequential tasks/cancellation. Syntax client tests cover shared parse work across splits, stale/closed-document rejection, and cancellation without cancelling another split's work.

Installer regressions cover approval decline, missing/broken executables, version-probe timeout even when a terminated tool exits zero, catalog identity/version/hash agreement, canonical release URLs, bounded downloads, bad hashes, unsafe archive paths/symlinks, receipt/path ownership, failed/cancelled update retention, and cancellation at activation. Existing filesystem/encoding/recovery, native editor/IME/undo, process/protocol cancellation, reviewed replacement, and Git tests also pass. Early failing runtime/formatter diagnostic logs remain for investigation; the later full run contains their passing corrected regressions.

Reproduce with prerequisites installed and generated grammar assets:

```sh
python3 scripts/build-grammars.py
TCODE_INTEGRATION=1 \
TCODE_DOWNLOAD_INTEGRATION=1 \
TCODE_GRAMMAR_FIXTURES="$PWD/dist/grammar-artifacts" \
TCODE_SEARCH_METRICS="$PWD/artifacts/language-search-metrics.json" \
TCODE_EDITOR_METRICS="$PWD/artifacts/language-editor-metrics.json" \
swift test --arch arm64
./scripts/build.sh
./scripts/test-syntax-service.sh
```

Network and native external tools are required for download/live checks. Ordinary `swift test --arch arm64` deliberately skips integrations/benchmarks whose flags or prerequisites are absent. Tests create disposable projects; removed repository examples are not required.

## Real tools and managed installation

These are actual local processes, not protocol mocks. Counts describe fixtures rather than guarantees for other tool versions/projects.

| Tool/workflow | Current verified result |
|---|---|
| pylsp + Ruff | Completion 84, definition 1, diagnostics 2; native document diagnostic merge/emoji position regression passed. |
| clangd | Completion 6, definition 1, diagnostics 2. |
| SourceKit-LSP | Completion 31, definition 1, diagnostics 1. |
| debugpy, C++ LLDB DAP, Swift LLDB DAP | Each reached a verified source breakpoint and exposed `answer = 42`. |
| Migrated Python v2 commands | compileall, run result 42, pytest/discovery, and Ruff stdin formatting passed. |
| Migrated C/C++ v2 commands | CMake configure/build with compile database, binary result 42, CTest/discovery, and clang-format stdin passed. |
| Migrated Swift v2 commands | SwiftPM build/run result 42/test/discovery and swift-format stdin passed. |
| Rust | Cargo build/run/test (one test), rustfmt stdin, rust-analyzer definition 1/completion 36/diagnostics 6, and LLDB source breakpoint with `answer = 42`. |

The installer tests downloaded the pinned upstream rust-analyzer archive and all Python wheels, verified SHA-256/architecture, created a separate Python environment with `pip --no-index --no-deps`, ran `pip check`, and probed executables. [Installer evidence](../artifacts/language-installer-validation.json) records a focused earlier run; the later full log repeats the download checks. Full-run measurements were **14,071,674 download bytes / 38,205,764 installed bytes / 1.28 s** for rust-analyzer, and **21,658,368 bytes / 92,770,728 installed bytes / 8.50 s** for Python tools. Durations vary with caches/network. No compiler/interpreter/SDK or project dependency installation is implied.

The tCode-hosted remote catalog and grammar Release assets are **not published**. A successful upstream tool download or local grammar fixture does not validate those public tCode URLs. Catalog publication and public end-to-end installation remain release gates.

## Packaged native syntax verification

The probe uses the exact signed helper copied from the Release app; [release-verification.json](../artifacts/syntax/release-verification.json) records matching helper SHA-256, arm64 modules, signatures, and entitlements. The editor has no syntax-worker entitlements. The worker has App Sandbox and its worker-only library-validation exception, with no workspace/network entitlement.

Python, C, C++, Swift, and Rust passed actual NSXPC installation/parsing from verified local archives into temporary managed stores. Each rejected a bad archive hash and invalid query while preserving working support, parsed Unicode/emoji/combining text and CRLF, and applied incremental edits. All five denied a workspace read and outbound socket (`EPERM`). The Python probe additionally loaded all five grammars on one connection, terminated its helper deliberately, and reconnected to a new process (PID 35021 → 35054) while the client survived. The other four JSON files intentionally report `serviceCrashRecovered = false` because they did not request termination.

For 100 incremental edits to a 10,000-line workload:

| Grammar | UTF-8 bytes | Worker parse/query median / p95 | XPC round-trip median / p95 | Helper RSS |
|---|---:|---:|---:|---:|
| Python | 168,898 | 20.33 / 21.39 ms | 40.85 / 42.22 ms | 56.11 MiB, five grammars loaded |
| C | 258,855 | 10.33 / 10.62 ms | 50.49 / 53.00 ms | 34.83 MiB |
| C++ | 258,855 | 10.73 / 10.96 ms | 51.10 / 52.49 ms | 45.45 MiB |
| Swift | 258,856 | 12.65 / 13.57 ms | 52.87 / 55.63 ms | 52.83 MiB |
| Rust | 258,854 | 10.83 / 11.07 ms | 51.05 / 52.15 ms | 36.30 MiB |

These packaged-probe measurements include UTF-16 capture conversion; round-trip includes transport. The final repeat ran after builds, application tests, and memory measurements completed; background system work can still affect timings. Python loaded five grammars while the other workers loaded one, so RSS values are not a controlled per-language comparison. They do not measure keystroke-to-screen latency or a fully active IDE. [Syntax implementation and limits](SYNTAX.md).

Prepared compressed grammar downloads total **924,492 bytes**: Python 66,862; C 75,852; C++ 283,932; Swift 377,199; Rust 120,647. The actual managed grammar store totals **9,979,876 bytes** including modules, queries, licenses, metadata, and receipts, excluding directory allocation. [Installed sizes](../artifacts/syntax/installed-sizes.json).

## Native UI checks and their limits

The current packaged AppKit app was operated through Settings → Language Support. Verified Installed/Catalog views, separate capabilities, the Rust installation review, optional-component choices, and explicit approval. Rust configuration plus managed rust-analyzer were installed into an isolated profile through native UI, without starting a workspace server. Screenshots: [Installed](../artifacts/language-support-installed.png), [Catalog](../artifacts/language-support-catalog.png), [Rust review](../artifacts/language-support-install-review.png). A second native review correctly identified healthy rust-analyzer, the external Rust toolchain, and existing Xcode tools for reuse; cancelling that review made no changes. [Reuse review](../artifacts/language-support-reuse-review.png).

The packaged Rust workspace then completed the native editor workflow: `.rs` recognition and Tree-sitter status, explicit **Enable Language Tools**, real rust-analyzer completion and definition navigation, two live syntax diagnostics, and Undo clearing the diagnostics. Cargo Build exited zero; Run printed `43`; Test exited zero and showed `PASSED tests::greets` in the navigator. Native rustfmt produced one undoable change, and Undo/Redo both worked. LLDB stopped at source line 7 and the variable inspector showed `answer = 42`. Apple LLDB warned that it has no Rust language plugin, so this does not establish complex Rust type inspection. Evidence: [UI results](../artifacts/language-ui-validation.json), [editor](../artifacts/rust-editor.png), [completion](../artifacts/rust-completion.png), [diagnostics](../artifacts/rust-diagnostics.png), [tests](../artifacts/rust-tests.png), and [debugger variable](../artifacts/rust-debugger.png).

The native language selector offered C and C++ for a header; selecting C applied the distinct `c` language ID and survived an app restart. An untitled document accepted explicit Rust and Plain Text selections. A deliberate SIGKILL of only the isolated GUI app's syntax worker left the app alive and editing available; a Unicode edit triggered a new helper process (PID 30057 → 30524), Tree-sitter resumed, and Undo restored the original buffer. [GUI crash evidence](../artifacts/language-ui-crash.json).

These checks used an isolated test profile. Curated grammar modules were seeded through the packaged local-artifact installer probe because the public assets remain unpublished. Configuration import did not start a workspace server. Workspace trust/reload, import/export/removal, and failed-update UX still need a broader interactive release pass; their automated coverage is recorded above.

The original **2026-10-08** UI evidence remains historical regression context: Unicode create/save/reopen, Python/C++/Swift build/run/test and variable inspectors, real PTY cwd/color/resize, local Git stage/commit, native Undo/Redo, light/dark appearance, and actual SIGKILL recovery/external-conflict Save a Copy. See [ui-validation.json](../artifacts/ui-validation.json), [dark](../artifacts/dark.png), [light](../artifacts/light.png), [debugger](../artifacts/debugger.png), and [recovery evidence](../artifacts/recovery-result.json). Those checks were not all repeated after the foundation changes.

## Editor, search, and launch measurements

| Measurement | tCode 0.1 baseline | tCode 0.2 foundation |
|---|---:|---:|
| Five-launch median to first native window layout | 285.7 ms | 279.9 ms |
| Median idle main-process RSS after one second | 111.14 MiB | 111.06 MiB |
| Native insertion + visible layout, median / p95 | 0.562 / 0.635 ms | 0.532 / 0.565 ms |
| Initial full layout, 10,000 lines | 229.5 ms | 188.4 ms |
| 10.5 MB decode/storage, large-file mode | 70.3 ms | 68.2 ms |
| Lazy root listing, 1,000 source files | 0.291 ms | 0.263 ms |
| Bounded index, same fixture | 6.30 ms | 5.40 ms |
| 2.1 MB search, raised benchmark cap, 60,000 hits | 2,416.0 ms | 2,295.0 ms |

Startup and idle RSS were remeasured on **2026-10-22** for both versions, using the verified original 0.1 ZIP and final 0.2 app with the same disposable Cargo workspace and restored tabs, isolated support/recovery directories, and language tools off. Each version ran five warm process launches. Executable SHA-256 values are recorded in the [0.1 launch baseline](../artifacts/language-baseline-launch-metrics.json) and [0.2 launch results](../artifacts/language-launch-metrics.json). The observed 5.8 ms median difference is not evidence of a general startup improvement. Startup is process start to first layout, excluding full restoration/presentation; idle RSS excludes tools and the syntax worker.

The remaining baseline rows use the original **2026-10-08** [editor](../artifacts/editor-metrics.json) and [search](../artifacts/search-metrics.json) fixtures, repeated **2026-10-22** for [current editor](../artifacts/language-editor-metrics.json) and [current search](../artifacts/language-search-metrics.json) measurements. These are local runs, not statistical performance guarantees.

The separate [paired active-memory run](../artifacts/language-memory-metrics.json) restored a **10,000-line / 517,690-byte Unicode Rust buffer** in the packaged Release app. The measurement waited for an actual Tree-sitter result (29,996 spans, 427,708 UTF-16 units) identifying the live packaged helper PID, then sampled both processes together. Median main RSS was **156.67 MiB**, worker RSS **44.91 MiB**, and combined RSS **201.58 MiB**. No LSP, task, debugger, or terminal ran. This is paired post-parse resident memory, not physical footprint, peak memory, a screen-highlighting assertion, or a same-workload comparison with the idle baseline. Reproduce with `python3 scripts/measure-language-memory.py --profile /path/to/isolated/profile-with-rust-pack-and-grammar` after building and closing the Release app.

Native edit timing covers 100 NSTextView insertions on a 160,000-byte/10,000-line fixture in the test host, not a fully populated IDE with tools/parser active. Large-file timing is decode/storage only. Search excludes 100 `node_modules` files; normal UI search caps at 10,000 hits instead of the stress limit. No sustained scrolling, display latency, physical-footprint, or Metal-rendering claim is made.

After building, close other tCode instances and reproduce startup with `python3 scripts/measure-launch.py --workspace /path/to/disposable/project`. The script isolates support/recovery state and terminates only its measurement processes.

## Packaging and remaining release gates

The final **0.2.0 / build 2** app and syntax helper are arm64 with minimum macOS 27. Strict signatures passed for both native executables and the complete app; all five grammar modules also passed arm64/signature checks. The main app has no entitlements; the helper alone has App Sandbox and the library-validation exception. The final app's helper matches the packaged probe, and startup/memory evidence records the same final executable hashes. [Final package inventory](../artifacts/language-package-verification.json).

The app contains **9,019,054 bytes** of files; the final ZIP is **3,039,732 bytes**, compared with **1,829,476 bytes** for the verified [0.1 ZIP baseline](../artifacts/package-verification.json). Grammar archives and optional tool installations are separate on-demand downloads, whose sizes are recorded above. Every extracted ZIP file matched the app inventory by SHA-256, and the extracted app passed strict signature verification. The final ZIP SHA-256 is `d136ec4fe8a8d9c8a903a585abc5500d690d73eb932f913049acccf1ac420a7d`.

Maintainer scripts built the five grammar archives from pinned source revisions with queries/licenses, regenerated four versioned pack configurations, and prepared ten hashed catalog/pack/grammar assets under `dist/language-release-review/`. [Catalog preparation and publication procedure](../catalog/README.md) describes review and immutable release upload order. No assets were published. Signing is ad hoc; Developer ID signing, notarization, App Store distribution, and installation on a second Mac have not been performed.

Before describing the online release as complete: publish/retrieve the reviewed immutable assets, validate installation through the public catalog URLs, and complete the broader interactive checks identified above. Current preparations do not satisfy those gates by themselves.

Other existing boundaries remain: full VoiceOver/Full Keyboard Access and Increase Contrast/Reduce Transparency/Motion audits; multiple displays; cloud/network filesystems; ACL/xattr preservation; extensive multicursor/IME behavior; arbitrary external directory moves; sustained large-file editing; broad LSP/DAP capability variants; query predicates and embedded languages. [STATUS.md](STATUS.md) distinguishes implemented, partial, and deferred behavior.
