# Native syntax service and grammar artifacts

The editor sends document snapshots over NSXPC to `dev.tufariello.tCode.SyntaxService`. Only that separately sandboxed native process links Tree-sitter 0.25.10 or maps executable grammar modules. The main editor never calls `dlopen` for a grammar. Each document owns an incremental parser/tree in the service, shared across split views. Captures return UTF-16 offsets suitable for NSTextStorage; outdated versions are discarded.

The service has no workspace, network, app-group, or user-selected-file entitlement. The worker-only Hardened Runtime library-validation exception permits curated downloaded modules during the current ad hoc development distribution. It does not reach the main app. Production Developer ID signing/notarization and module publisher trust remain distribution work.

Grammar transport uses a read-only NSXPC file descriptor for a hash-verified temporary copy; source text and queries use XPC data. No workspace path or sandbox extension is sent. This avoids creating executable files within App Sandbox, which macOS quarantines by default. Apple's entitlement reference documents that behavior: <https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html>. The worker validates module SHA-256, arm64 Mach-O headers, Tree-sitter ABI, query digest and query compilation before activation. Native modules can only come from the curated catalog. A language pack can select a catalog grammar or supply bounded structural query text, not an arbitrary native plugin.

Limits: 2 million UTF-16 units per document, 64 open parsing documents, 16 grammar/query combinations per service, 64 MiB per module, 1 MiB per query, 100,000 captures, parser/query time budgets and an eight-second transport deadline. Query predicates and embedded-language injections are deferred. Editing and basic highlighting continue after service failure. macOS launchd may throttle a crashed helper for about ten seconds; subsequent parsing reconnects automatically.

## Rebuild optional artifacts

`catalog/grammar-lock.json` pins grammar commits, source archive hashes, symbols and ABI. `catalog/Queries/` contains tCode's small structural queries; grammar implementation licenses ship inside every artifact. The runtime is vendored under `Sources/CTreeSitter`, with MIT and Unicode license notices.

```sh
python3 scripts/build-grammars.py
./scripts/build.sh
./scripts/test-syntax-service.sh
TCODE_GRAMMAR_FIXTURES="$PWD/dist/grammar-artifacts" swift test --filter SyntaxTests
```

The maintainer build requires Xcode; normal grammar installation consumes prebuilt arm64 archives and requires no compiler. `build-grammars.py --source-cache /path` accepts pinned archives named `python.tar.gz`, `rust.tar.gz`, `c.tar.gz`, `cpp.tar.gz`, `swift.tar.gz` for offline rebuilding. The script verifies sources, builds/signs native modules, packages queries and licenses, and prepares `Sources/TCode/Resources/Syntax/grammars.json`. Artifacts go to `dist/grammar-artifacts/`.

The named GitHub release `language-grammars-v1` is a **prepared publication target**. Until a maintainer publishes it, generated artifact URLs are not an online installation claim. For local validation the packaged probe feeds the same installer verified local archives and a temporary managed store.

The packaged regression copies the exact signed helper from the assembled Release app and uses an actual NSXPCConnection. It verifies all five languages, managed installation, bad-hash and bad-query rejection, Unicode/CRLF incremental parsing, denied workspace reads, denied outbound sockets, and recovery after deliberately terminating only the helper. The recovery check requires a new helper PID while the probe survives. JSON evidence is written under `artifacts/syntax/`.

The probe also measures initial parsing and 100 incremental XPC round trips on a 10,000-line fixture for each language, with helper RSS. These timings include complete-document capture queries and the round-trip measure includes snapshot transfer and result decoding; they are not editor display latency measurements.

The final arm64 Release run on the development M2 MacBook Air passed all five grammar probes. Every worker denied the existing, host-readable workspace file and denied an outbound socket with `EPERM`. The deliberate Python worker termination recovered from PID 35021 to PID 35054 while its host process survived. These are probe-host checks; the main app's GUI recovery is recorded separately in the release validation report.

| Grammar | Fixture bytes / lines | Initial parse + captures | Incremental parse median / p95 | XPC round trip median / p95 | Helper RSS with fixture open |
| --- | ---: | ---: | ---: | ---: | ---: |
| Python | 168,898 / 10,000 | 31.59 ms | 20.33 / 21.39 ms | 40.85 / 42.22 ms | 56.11 MiB |
| C | 258,855 / 10,000 | 44.63 ms | 10.33 / 10.62 ms | 50.49 / 53.00 ms | 34.83 MiB |
| C++ | 258,855 / 10,000 | 45.29 ms | 10.73 / 10.96 ms | 51.10 / 52.49 ms | 45.45 MiB |
| Swift | 258,856 / 10,000 | 47.31 ms | 12.65 / 13.57 ms | 52.87 / 55.63 ms | 52.83 MiB |
| Rust | 258,854 / 10,000 | 46.64 ms | 10.83 / 11.07 ms | 51.05 / 52.15 ms | 36.30 MiB |

Python additionally loaded all five grammars on its connection to check multi-language sharing; the other RSS samples use their own grammar, so these values are not a direct per-language memory comparison. RSS is a process snapshot after the 100 edits while the large fixture remains open, rather than peak memory. The final repeat ran after builds, application tests, and memory measurements completed; background system work may still affect timings. The complete managed grammar store occupies 9,979,876 bytes including licenses, metadata, queries, and activation receipts, excluding directory allocation. Evidence: `artifacts/syntax/{python,c,cpp,swift,rust}.json`, `installed-sizes.json`, `release-verification.json`, and `artifacts/syntax-packaged-release.log`.

Strict signature and arm64 verification passed for the shipped helper and all five grammar modules. The probe copied the shipped helper byte-for-byte, confirmed by SHA-256. The main app has no worker entitlements; only the syntax service has App Sandbox and the library-validation exception. Signing remains ad hoc and the catalog/grammar artifacts remain prepared for publication, not an operational public download service.

Maintainer UI checks can preserve an isolated managed store without touching a personal installation:

```sh
TCODE_PRESERVE_GRAMMAR_STORE="$PWD/artifacts/language-ui-profile/grammars" ./scripts/test-syntax-service.sh
```

Launch the app with `TCODE_SUPPORT_DIRECTORY` set to `$PWD/artifacts/language-ui-profile` to use that profile. Preserved probe stores are restricted to the repository's `artifacts/` folder or temporary directories. The default probe still cleans up its unique temporary store. This local-artifact path exercises the installer for testing and does not establish that unpublished GitHub downloads work.
