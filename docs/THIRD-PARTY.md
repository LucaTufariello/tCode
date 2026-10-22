# Dependencies and tool notices

## Linked native dependency

**SwiftTerm 1.20.0**, revision `5d144068` (full revision in `Package.resolved`), Miguel de Icaza and contributors — **MIT License**. Native terminal parser and AppKit PTY terminal view. [Repository](https://github.com/migueldeicaza/SwiftTerm). Full license: `licenses/SwiftTerm-MIT.txt`. SwiftTerm is compiled into the app; no terminal helper executable or JavaScript renderer is bundled.

SwiftTerm's package graph resolves **swift-argument-parser 1.8.2**, revision `6a52f3251125d74daf04fcbd5e6f08a75d074382` (full revision in `Package.resolved`) — **Apache License 2.0 with Swift Runtime Library Exception**. It is used by SwiftTerm package utility targets rather than the tCode target's direct dependency list. Its full license is retained in `licenses/SwiftArgumentParser-Apache-2.0.txt` for completeness. [Repository](https://github.com/apple/swift-argument-parser).

## Native syntax runtime and optional grammars

**Tree-sitter 0.25.10**, Max Brunsfeld and contributors — **MIT**. The C runtime is vendored in `Sources/CTreeSitter` and linked into the native syntax worker, not the editor process. Full notices: [TreeSitter-MIT.txt](licenses/TreeSitter-MIT.txt) and [TreeSitter-Unicode.txt](licenses/TreeSitter-Unicode.txt) for its Unicode support code. [Upstream](https://github.com/tree-sitter/tree-sitter/tree/v0.25.10). The runtime source archive SHA-256 is recorded in `catalog/grammar-lock.json`.

Prebuilt grammar modules are separate optional downloads. Each prepared archive contains the upstream **MIT** license as `LICENSE`, alongside its pinned descriptor/module/query. Their source revisions and source-archive hashes are in [grammar-lock.json](../catalog/grammar-lock.json):

| Grammar | Upstream version / revision | Source and license |
|---|---|---|
| Python | 0.25.0 / `293fdc02038ee2bf0e2e206711b69c90ac0d413f` | [tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python/tree/293fdc02038ee2bf0e2e206711b69c90ac0d413f), MIT, Max Brunsfeld and contributors |
| C | 0.24.1 / `7fa1be1b694b6e763686793d97da01f36a0e5c12` | [tree-sitter-c](https://github.com/tree-sitter/tree-sitter-c/tree/7fa1be1b694b6e763686793d97da01f36a0e5c12), MIT, Max Brunsfeld and contributors |
| C++ | 0.23.4 / `f41e1a044c8a84ea9fa8577fdd2eab92ec96de02` | [tree-sitter-cpp](https://github.com/tree-sitter/tree-sitter-cpp/tree/f41e1a044c8a84ea9fa8577fdd2eab92ec96de02), MIT, Max Brunsfeld and contributors |
| Rust | 0.24.0 / `18b0515fca567f5a10aee9978c6d2640e878671a` | [tree-sitter-rust](https://github.com/tree-sitter/tree-sitter-rust/tree/18b0515fca567f5a10aee9978c6d2640e878671a), MIT, Maxim Sokolov and contributors |
| Swift | 0.7.4 / `82bb3a533e0801fd2bbaa11dc49676e10bf41948` | [tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift/tree/82bb3a533e0801fd2bbaa11dc49676e10bf41948), MIT, alex-pinkus and contributors |

The structural queries under `catalog/Queries` are maintained by tCode; downloaded upstream query suites are not silently reused. Grammar archives are prepared local release artifacts until publication. No unrestricted native module hosting or arbitrary VS Code extension execution is provided.

## External tools and managed optional downloads

- python-lsp-server **1.15.0** — MIT; [upstream](https://github.com/python-lsp/python-lsp-server).
- Ruff **0.16.10** — MIT; [upstream](https://github.com/astral-sh/ruff).
- Black **26.10.0** — MIT; [upstream](https://github.com/psf/black). Included in the optional Python tool recipe; Ruff remains the default formatter.
- debugpy **1.8.22** — MIT; [upstream](https://github.com/microsoft/debugpy).
- pytest **9.1.1** — MIT; [upstream](https://github.com/pytest-dev/pytest).
- clang-format **23.1.3** Python distribution — distribution license metadata and LLVM notices apply; see `python-tool-licenses.json`.
- Apple clangd **21.0.0**, Xcode's SourceKit-LSP, LLDB DAP **LLVM 21 / lldb-2103**, Swift **6.4**, and swift-format — supplied by the user's Xcode toolchain, governed by their respective upstream/toolchain licenses. [clangd](https://clangd.llvm.org/), [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp), [LLDB DAP](https://lldb.llvm.org/use/lldbdap.html).
- CMake/CTest and Git — external installed executables; no copies are included in the application.
- rust-analyzer **2026-10-19** — dual **MIT / Apache-2.0**; [upstream release](https://github.com/rust-lang/rust-analyzer/releases/tag/2026-10-19), [license notices](https://github.com/rust-lang/rust-analyzer#license). The managed recipe downloads the pinned native arm64 archive from upstream; it is not bundled in the base application. Rust, Cargo, rustfmt, and rust-src are external prerequisites under their upstream distribution terms.

The optional setup script installs exact versions from `tool-requirements.txt` into the earlier user tools environment. The managed installer uses a reviewed wheel lock (`catalog/python-wheels.json`) and retains distributions' installed license files in isolated environments. `python-tool-licenses.json` records versions/license metadata from the development tools environment; it is evidence of that environment rather than an exhaustive legal certification of every future installation. Consult the exact wheel's `.dist-info` license files. No Python tool packages, Rust compiler, restricted VS Code extensions, or Marketplace content are bundled in the base app. Maintainers must retain upstream notices if redistributing tool archives later.

Apple system frameworks and SF Symbols are used under the platform SDK terms. The tCode icon is original AppKit-drawn artwork generated by `scripts/icon.swift`.
