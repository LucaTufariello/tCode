#!/usr/bin/env python3
"""Prepare a local review ZIP and verify its extracted native app. Never publishes."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def run(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def entitlements(path):
    value = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)],
                           check=True, capture_output=True).stdout
    return plistlib.loads(value) if value.strip() else {}


def inventory(root):
    return {str(p.relative_to(root)): digest(p) for p in sorted(root.rglob('*')) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('dist/tCode.app'))
    parser.add_argument('--output', type=Path,
                        default=Path('artifacts/language-package-verification.json'))
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    assert info['LSMinimumSystemVersion'] == '27.0'
    run('codesign', '--verify', '--deep', '--strict', str(app))
    assert entitlements(app) == {}, 'The main editor must not receive syntax-worker entitlements'
    helper = app / 'Contents/XPCServices/dev.tufariello.tCode.SyntaxService.xpc'
    assert entitlements(helper) == {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.cs.disable-library-validation': True,
    }, 'Unexpected worker privileges'
    binaries = []
    for path in sorted(app.rglob('*')):
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in [b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf']:
            continue
        architecture = run('lipo', '-archs', str(path))
        assert architecture == 'arm64', str(path) + ': ' + architecture
        run('codesign', '--verify', '--strict', str(path))
        build = run('otool', '-l', str(path))
        assert re.search(r'\bminos\s+27\.0\b', build), str(path) + ': deployment target'
        libraries = run('otool', '-L', str(path))
        assert not any(value in libraries for value in ['WebKit', 'JavaScriptCore', 'Electron'])
        binaries.append({'path': str(path.relative_to(app)), 'architecture': architecture,
                         'sha256': digest(path), 'minimum_macos': '27.0',
                         'strict_signature_verified': True, 'linked_libraries': libraries})
    assert {p['path'] for p in binaries} == {
        'Contents/MacOS/tCode',
        'Contents/XPCServices/dev.tufariello.tCode.SyntaxService.xpc/Contents/MacOS/TCodeSyntaxService',
    }, 'Unexpected native executable inventory'
    archive = app.parent / f'tCode-{version}-macOS27-arm64.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
    expected = inventory(app)
    with tempfile.TemporaryDirectory(prefix='tcode-release-verify-') as directory:
        run('ditto', '-x', '-k', str(archive), directory)
        extracted = Path(directory) / app.name
        assert inventory(extracted) == expected, 'Extracted archive contents differ'
        run('codesign', '--verify', '--deep', '--strict', str(extracted))
    signature = subprocess.run(['codesign', '-dvv', str(app)],
                               check=True, capture_output=True, text=True)
    result = {
        'app': str(app), 'version': version, 'build': info['CFBundleVersion'],
        'architecture': 'arm64', 'minimum_macos': '27.0',
        'app_file_bytes': sum(p.stat().st_size for p in app.rglob('*') if p.is_file()),
        'mach_o_files': binaries, 'main_app_entitlements': entitlements(app),
        'syntax_worker_entitlements': entitlements(helper),
        'deep_strict_signature_verified': True, 'signature': signature.stdout + signature.stderr,
        'zip': {'path': str(archive), 'bytes': archive.stat().st_size, 'sha256': digest(archive),
                'all_extracted_file_hashes_match': True, 'extracted_signature_verified': True},
        'file_sha256': expected, 'signing': 'ad hoc',
        'developer_id_notarization_performed': False, 'published': False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in
                      ['version', 'app_file_bytes', 'zip', 'deep_strict_signature_verified']}, indent=2))


if __name__ == '__main__':
    main()
