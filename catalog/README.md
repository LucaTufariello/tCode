# tCode language catalog

This directory is maintainer-controlled catalog source. Language packs contain data only and may reference the installer recipe IDs compiled into `TCodeCore`; they cannot provide installer commands.

The bundled catalog works offline. Entries remain **draft** until the matching public GitHub Release artifacts have been uploaded and the complete catalog download/install flow has been verified. No release is published automatically by these scripts.

- Stable catalog URL: `https://github.com/LucaTufariello/tCode/releases/download/language-catalog-v1/catalog.json`.
- Versioned pack artifact URLs: `https://github.com/LucaTufariello/tCode/releases/download/language-packs-v2.0.0/<id>.json`.
- Grammar artifacts use their own pinned descriptor, hash, runtime ABI, and revision.
- Remote catalog entries must resolve to this repository's versioned GitHub Release downloads. A published pack must carry a SHA-256 checksum.

## Preparing portable packs

Run the following from the repository after reviewing source/license updates:

```sh
python3 scripts/build-grammars.py
./scripts/generate-language-packs.sh
python3 scripts/prepare-language-release.py
```

The grammar builder verifies pinned source archives, compiles/signs arm64 modules, packages licenses and matching queries, and records the exact archive/module/query hashes. It supports `--source-cache` for an offline maintainer build; end users need no compiler to consume the prepared artifacts. [Syntax build and isolation checks](../docs/SYNTAX.md).

The pack generator compiles the actual Core models and migrations, serializes all four packs as interface version 2 / pack version 2.0.0, updates their catalog hashes, and includes the curated grammar artifact descriptors. Python, C/C++, and Swift remain the bundled defaults; Rust configuration is nested in `Resources/CatalogPacks` and becomes installed only after the user chooses it from the catalog. The preparation helper verifies exact JSON/archive/component hashes and licenses, then groups assets by release tag under `dist/language-release-review/` with `SHA256SUMS` and review instructions. These scripts never publish, change entries to published, or upload anything.

## Updating the allowlisted tools

Run `python3 scripts/generate-tool-catalog.py` after reviewing `docs/tool-requirements.txt`. The generator reads official PyPI release metadata, selects CPython 3.12 macOS arm64-compatible wheels, and updates both `catalog/python-wheels.json` and the compiled `PythonWheelLock.swift`. Review version/license changes and test a clean isolated install before release. It never runs in an end user's app.

The Python installer first downloads every pinned wheel, verifies every SHA-256, creates a tCode-owned environment, installs with `--no-index --no-deps`, runs `pip check`, validates health and arm64 extension architectures, then atomically activates a receipt. It does not modify project environments. CPython itself remains externally managed.

The `rust-analyzer` recipe pins upstream release `2026-10-19`, compressed size `14071674`, and SHA-256 `eedad08a96f7bf92afd0890463787337d17591ea2e3df216033c6bc3ccc9d802`. Its URL/hash were read from the official GitHub Releases metadata. Rust/rustfmt/rust-src and Xcode remain external prerequisites. Executable paths are probed; a broken rustup shim is not counted as healthy.

## Publishing a catalog update

1. Prepare versioned pack JSON and grammar archives; run the local import/install and regression tests.
2. Upload immutable versioned assets to the repository's GitHub Releases after review.
3. Fill the catalog pack checksums from those exact bytes and mark only verified assets as published.
4. Validate downloads and installation through tCode using the public URLs.
5. Publish the stable catalog artifact. Keep prior versioned assets available so installed users can stay on working versions.

To avoid declaring support prematurely, stage and review the immutable assets first. Test the candidate published catalog before making it the stable artifact. The normal UI intentionally disables draft grammar downloads. A locally passing file-install fixture does not establish that GitHub URLs, redirects, release availability, or the public catalog path work. Developer ID signing/notarization is separate from this local release-preparation workflow.

Contributions for additional languages should provide a [data-only pack](../docs/LANGUAGE-SUPPORT.md), recognition/ambiguity cases, existing upstream tool references, explicit licenses, and real language-server/task validation. A new pack may reference an existing curated grammar or bounded structural query. New native grammar artifacts require curated source/hash/license review and sandboxed validation. New executable installer recipes require an app update and code review.
