# Language support and pack authoring

tCode separates recognition/editing metadata, native syntax grammars, language servers, formatters, tasks, and debugger adapters. Installing configuration does not imply every feature is available. **Settings → Language Support** shows those capabilities independently. The same app can use additional data-only packs without recompilation; new executable installer recipes still require an app update and code review.

## User workflow

- **Installed** shows effective bundled/user packs. Enable/Disable controls a pack; Configure sets local executable overrides; Validate explicitly runs executable probes. A located executable is only a candidate until validated and connected.
- **Catalog** offers four starter packs: Python, C/C++, Swift, and Rust. The first three are bundled defaults; Rust becomes installed only when chosen. Install/Update presents an approval sheet for optional tools and grammars. Configuration Only skips their downloads.
- **Import…** validates JSON and asks before replacing an existing user configuration. It starts no server and installs no tool. **Export…** writes configuration only; it does not copy executables or local executable overrides.
- **More → Remove Configuration…** removes the user overlay and reveals any bundled default. Bundled defaults can be disabled. **Remove Managed Downloads…** separately lists tCode-owned tools/grammars, warns about shared-pack use, and retains external interpreters, compilers, SDKs, and reused installations.
- **Editor → Document Language…** selects Automatic, Plain Text, or a pack/language pair. Use it for untitled files, unusual filenames, and ambiguous associations. Saved-document choices persist with workspace layout.
- **Editor → Reload Language Packs** reloads external JSON without rebuilding or restarting the app. Invalid replacements keep their last working configuration and report an error. Explicitly enable language tools again after changing configuration.

Recognition ranks exact filenames, extensions, then bounded first-line regular expressions. Extension matching is case-insensitive. The top equal-priority matches are ambiguous: `.h` can be C or C++, so tCode asks you to choose through Document Language rather than guessing. Plain Text suppresses language selection. Disabled packs do not participate.

### Publication state

The current catalog and native grammar artifacts are **prepared, unpublished release assets**. Bundled configurations remain usable and supported tool recipes use separately pinned upstream sources. Draft grammar downloads stay disabled in the normal UI. A maintainer must publish and verify the catalog path before online installation is considered released. [Catalog maintenance](../catalog/README.md).

The catalog is refreshed only on request. Successful validated refreshes are cached for offline browsing. Existing packs/tools/grammars keep working when the network is unavailable; first-time downloads require connectivity. No AI account is required.

## Locations, precedence, and trust

All paths below are relative to `~/Library/Application Support/tCode/`:

| Location | Purpose |
|---|---|
| App resources | Bundled Python/C/C++/Swift defaults and on-demand Rust starter data |
| `LanguagePacks/<id>.json` | User-installed portable configuration overlays |
| `LanguagePacks/versions/<id>/<version>-<SHA-256>/pack.json` | Validated configuration history, capped at 16 recent versions plus the active version |
| `LanguagePacks/versions/<id>/active.json` | Last validated installation pointer used to recover a corrupt active user configuration after restart |
| `LanguageCatalog/catalog.json` | Last validated remote catalog cache |
| `ManagedTools/versions/<recipe>/<version>-<unique-id>/` | Versioned owned tool environments/binaries |
| `ManagedTools/receipts/<recipe>.json` | Active version, executable locations, ownership |
| `grammars/<id>/<version>/` | Owned native grammar, query, descriptor, and license |
| `grammars/<id>/active.json` | Installer-owned activation metadata |
| `tools/` | Earlier explicit setup-script environment, still discovered |

Effective order is bundled default, user configuration, then enabled workspace override for the same pack ID. Workspace files live in **`.tcode/languages/*.json`** and are ignored until **Editor → Enable Workspace Language Configurations…** is explicitly confirmed for that folder. That consent persists locally. Reload applies later reviewed changes. Duplicate IDs inside the same directory and invalid files produce configuration issues; do not rely on file ordering to resolve duplicate IDs.

Import/install saves a hash-identified version of the configuration while retaining the compatible flat active file. A malformed active user file can recover the last validated installed version across restarts; missing/deleted files are not restored. History is bounded and checksum-checked before use. Workspace override history is held only in its workspace registry's memory and never recovered from another folder. Remove Configuration removes tCode-owned history as well as the active overlay; unrelated files placed in the history folder are retained.

Packs are data, but configured language/task/debug commands can execute code when a user requests those features. Review packs before importing or enabling workspace overrides. Opening a folder, selecting its language, or importing JSON does not launch a command. Enabling a workspace server and choosing Build/Run/Test/Format/Debug are separate execution actions. Arguments are passed as arrays; tCode performs no shell interpolation. A configured executable may itself be an interpreter, so “data-only” is not an assurance that its later commands are harmless.

Executable grammar modules are different: only the curated catalog may identify them. An imported pack may select an existing curated `grammarID` or provide bounded structural highlighting query text; it cannot supply arbitrary module URLs, native code, or installer scripts. [Sandbox and syntax limits](SYNTAX.md).

## Interface version 2

The Core `LanguagePack` type is the source of truth. JSON has a 1 MiB limit; interfaces other than 1 and 2 are rejected. Version 1 decodes through migration and retains the existing integrations; new exports always write version 2. Pack `version` is independent of `interfaceVersion`.

| Field | Type / meaning |
|---|---|
| `interfaceVersion` | Required integer `2` for new packs |
| `id`, `name`, `version` | Required pack identity, display name, and version; IDs/versions are bounded safe identifiers |
| `associations` | Required nonempty list with `languageID`; optional `extensions`, `filenames`, `firstLinePattern`, `grammarID`, `highlightQuery` |
| `editor` | Optional `lineComment`, `snippets` (`name`, `text`), `indentSize` (1–16), `useTabs` |
| `languageServer` | Optional `command`, JSON `initializationOptions`/`settings`, and `rootMarkers` metadata |
| `formatterCommand` | Optional command that reads source on stdin and returns formatted source on stdout |
| `tasks` | Optional map of actions (`build`, `run`, `test`, `discoverTests`) to ordered `steps`, optional `rootMarkers`, `resultParser` |
| `debugger` | Optional `adapterID`, adapter `command`, and JSON `launch` values |
| `toolRecipeIDs` | Optional IDs referencing compiled curated setup recipes |
| `diagnosticAdapter` | Optional built-in adapter name; `ruff` retains Python buffer lint integration |

A command has required `executable`, optional `arguments` array, `workingDirectory`, and string-valued `environment` map. Available placeholders are `${workspace}`, `${file}`, `${fileName}`, `${fileStem}`, `${python}`, `${interpreter}`, `${program}`, and `${buildDir}`. Unknown/unavailable placeholders fail validation/execution. There is no `~`, shell-variable, pipe, or command-substitution expansion. Relative working directories resolve from the workspace. `.tcode/run.json` arguments/environment/cwd still apply to user task/debug execution; its explicit executable overrides the pack's Run task.

Indentation starts with pack defaults, then applies explicit global indentation preferences, `.tcode/settings.json`, and the supported hierarchical EditorConfig rules. Comments and snippet choices come from the selected pack. A snippet inserts text; it does not start a tab-stop session.

Task `rootMarkers` match files at the opened workspace root. The active document's matching task wins; otherwise a single matching project provider is selected. Multiple matching providers require a source-language choice. Language-server `rootMarkers` are currently descriptive metadata; sessions use the opened workspace root and do not perform arbitrary ancestor-root discovery. Test result adapters are built-in `pytest`, `ctest`, `swift`, and `cargo`; other output remains accessible in Build Output. Resource edits, arbitrary LSP feature support, and unknown DAP reverse requests do not become implemented by adding JSON.

Minimal editing-only configuration:

```json
{
  "interfaceVersion": 2,
  "id": "my-language",
  "name": "My Language",
  "version": "1.0.0",
  "associations": [
    {"languageID": "my-language", "extensions": ["mine"], "filenames": ["MyBuildfile"]}
  ],
  "editor": {
    "lineComment": "#",
    "indentSize": 2,
    "useTabs": false,
    "snippets": [{"name": "Greeting", "text": "hello\n"}]
  }
}
```

Import this to recognize `.mine` files; no compiler or intelligence is implied. For a complete real pack, inspect the portable [Rust configuration](../catalog/packs/rust.json) and the other three [catalog packs](../catalog/packs). Use an existing upstream LSP/DAP tool, describe its prerequisites, and test actual behavior before claiming a capability.

### Portable exports

Local Settings overrides and installed tool paths are not encoded in exported packs. Export validation refuses command environments, absolute/local paths, known credential forms, and private JSON settings instead of silently leaking them. Replace local paths with portable placeholders and keep private settings local. This check is deliberately conservative and may reject a legitimate configuration. It cannot recognize every secret hidden in ordinary text; review an exported JSON file before sharing it. Import validation also is not a security review of the commands it describes.

## Installation and compatibility boundaries

`ToolInstallPlan` reports concrete downloads, versions, SHA-256 values, prerequisites, expected changes, and availability before approval. Curated recipe IDs currently cover `python-tools`, `clang-format`, `rust-analyzer`, and external `rust-toolchain`/`xcode-tools`. The application controls recipes, not the imported pack. Managed archives/wheels are verified, staged, health-checked, and activated with owned receipts. Failed updates retain prior active versions; removing a resource does not uninstall another tool manager's copy.

CPython 3.12 is required for isolated pinned Python environments. Rust's compiler/Cargo/rustfmt/rust-src, Xcode, and CMake remain user-managed prerequisites. The Python interpreter selected for a project must contain its own required pytest/debugpy modules. A tool's successful version probe does not guarantee project-specific configuration, imports, dependencies, or debugging will succeed.

Parser-backed highlighting is incremental and native, not semantic-token support. Query predicates, embedded languages, parser-derived folds/indentation, arbitrary native plugin imports, general VSIX compatibility, and automated compiler/SDK installation are deferred. AI chat/coding and a language-setup skill follow in a later release; this foundation has no provider API or inactive AI controls.
