#!/usr/bin/env python3
"""Assemble reviewed local language-release assets; never publish or change catalog state.

First run scripts/build-grammars.py and scripts/generate-language-packs.sh.
The output groups immutable assets by their declared GitHub Release tag and adds
checksums/review notes. A maintainer must separately review, upload, and validate.
"""

import argparse
import hashlib
import json
import pathlib
import shutil
import tarfile
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def release_location(url):
    value = urllib.parse.urlparse(url)
    prefix = "/LucaTufariello/tCode/releases/download/"
    if value.scheme != "https" or value.netloc != "github.com" or not value.path.startswith(prefix):
        raise ValueError("Expected the curated tCode GitHub Release URL: " + url)
    parts = value.path[len(prefix):].split("/")
    if len(parts) != 2 or any(p in ("", ".", "..") for p in parts):
        raise ValueError("Expected release tag and artifact filename: " + url)
    return parts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grammars", type=pathlib.Path, default=ROOT / "dist/grammar-artifacts")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "dist/language-release-review")
    args = parser.parse_args()
    catalog = json.loads((ROOT / "catalog/catalog.json").read_text())
    grammar_metadata = json.loads((args.grammars / "grammars.json").read_text())
    if catalog.get("grammarArtifacts") != grammar_metadata:
        raise ValueError("Grammar descriptors differ. Regenerate language packs after grammar assets.")
    assets = []
    for entry in catalog["entries"]:
        source = ROOT / "catalog/packs" / (entry["id"] + ".json")
        pack = json.loads(source.read_text())
        if pack.get("id") != entry["id"] or pack.get("version") != entry["version"]:
            raise ValueError("Pack identity/version differs from catalog: " + entry["id"])
        if digest(source) != entry.get("packSHA256"):
            raise ValueError("Pack hash differs from catalog: " + entry["id"])
        tag, name = release_location(entry["packURL"])
        assets.append((source, pathlib.Path(tag) / name))
    for artifact in grammar_metadata:
        tag, name = release_location(artifact["url"])
        source = args.grammars / name
        if digest(source) != artifact["sha256"] or source.stat().st_size != artifact["downloadBytes"]:
            raise ValueError("Grammar archive differs from catalog: " + name)
        descriptor = artifact["descriptor"]
        with tarfile.open(source, "r:gz") as archive:
            expected = {"descriptor.json", "LICENSE", descriptor["module"], descriptor["query"]}
            if set(archive.getnames()) != expected or any(not m.isfile() for m in archive.getmembers()):
                raise ValueError("Unexpected grammar archive contents: " + name)
            if json.load(archive.extractfile("descriptor.json")) != descriptor:
                raise ValueError("Grammar descriptor mismatch: " + name)
            for key, hash_key in (("module", "moduleSHA256"), ("query", "querySHA256")):
                data = archive.extractfile(descriptor[key]).read()
                if hashlib.sha256(data).hexdigest() != descriptor[hash_key]:
                    raise ValueError("Grammar component hash mismatch: " + name)
            if not archive.extractfile("LICENSE").read():
                raise ValueError("Missing grammar license: " + name)
        assets.append((source, pathlib.Path(tag) / name))
    assets.append((ROOT / "catalog/catalog.json", pathlib.Path("language-catalog-v1/catalog.json")))
    # Validate everything before creating output; never rewrite source availability/publication fields.
    args.output.mkdir(parents=True, exist_ok=True)
    checksums = []
    for source, relative in assets:
        destination = args.output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        checksums.append(digest(destination) + "  " + relative.as_posix())
    (args.output / "SHA256SUMS").write_text("\n".join(sorted(checksums)) + "\n")
    (args.output / "REVIEW.md").write_text(
        "# Language release review bundle\n\n"
        "Prepared locally; nothing has been published. Catalog availability is preserved.\n\n"
        "1. Review source revisions, licenses, pack commands, prerequisites, and hashes.\n"
        "2. Run unit, real-tool, native UI, packaged XPC isolation, and signature checks.\n"
        "3. Separately approve publication and upload immutable versioned assets.\n"
        "4. Validate downloads/install through the public URLs before marking entries published.\n"
        "5. Publish the validated catalog last; retain older versioned assets.\n\n"
        "See catalog/README.md and docs/VALIDATION.md. This is not a notarized distribution.\n"
    )
    print(f"Prepared {len(assets)} local assets in {args.output}. Nothing was published.")


if __name__ == "__main__":
    main()
