#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
generated_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tcode-pack-generator.XXXXXX")"
trap 'rm -rf -- "$generated_work_dir"' EXIT
xcrun swiftc "$repo_dir/Sources/TCodeCore/Files.swift" "$repo_dir/Sources/TCodeCore/LanguagePack.swift" "$repo_dir/Sources/TCodeCore/LanguagePackDefaults.swift" "$repo_dir/scripts/GenerateLanguagePacks.swift" -o "$generated_work_dir/generate-packs"
"$generated_work_dir/generate-packs" "$repo_dir"
python3 - "$repo_dir" <<'PY'
import hashlib
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
path = root / 'catalog/catalog.json'
catalog = json.loads(path.read_text())
for row in catalog['entries']:
    artifact = root / 'catalog/packs' / (row['id'] + '.json')
    row['packSHA256'] = hashlib.sha256(artifact.read_bytes()).hexdigest()
    row['bundledFilename'] = 'CatalogPacks/rust.json' if row['id'] == 'rust' else row['id'] + '.json'
catalog['grammarArtifacts'] = json.loads((root / 'Sources/TCode/Resources/Syntax/grammars.json').read_text())
path.write_text(json.dumps(catalog, indent=2) + '\n')
print('Prepared catalog checksums and native grammar descriptors. Nothing was published.')
PY
