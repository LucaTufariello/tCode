#!/usr/bin/env python3
"""Paired Release-app/XPC RSS with a restored 10,000-line Rust buffer.

Uses private temporary copies of installed packs/grammars and the normal recovery
format. It does not enable language servers, change preferences, or drive UI.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, default=Path('dist/tCode.app'))
parser.add_argument('--profile', type=Path, required=True,
                    help='Test profile with the installed Rust pack and grammar')
parser.add_argument('--output', type=Path, default=Path('artifacts/language-memory-metrics.json'))
args = parser.parse_args()
binary = args.app.resolve() / 'Contents/MacOS/tCode'
helper = args.app.resolve() / 'Contents/XPCServices/dev.tufariello.tCode.SyntaxService.xpc/Contents/MacOS/TCodeSyntaxService'

def processes():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,rss=,command='], text=True)
    result = []
    for row in rows.splitlines():
        values = row.strip().split(None, 2)
        if len(values) == 3:
            result.append((int(values[0]), int(values[1]), values[2]))
    return result

if any(str(binary) in command for _, _, command in processes()):
    raise SystemExit('Close this Release app before measuring its memory.')
with tempfile.TemporaryDirectory(prefix='tcode-language-memory-') as directory:
    root = Path(directory)
    profile = root / 'Support'
    for name in ['LanguagePacks', 'grammars']:
        shutil.copytree(args.profile / name, profile / name)
    recovery = root / 'Recovery'
    recovery.mkdir()
    workspace = root / 'Workspace'
    workspace.mkdir()
    source = workspace / 'main.rs'
    baseline = b'fn main() {}\n'
    source.write_bytes(baseline)
    text = 'fn main() {\n' + ''.join(
        f'    let value_{index} = {index}; // caf\u00e9 \U0001f469\U0001f3fd\u200d\U0001f4bb\n'
        for index in range(9998)) + '}\n'
    document_id = str(uuid.uuid4()).upper()
    (recovery / f'{document_id}.json').write_text(json.dumps({
        'id': document_id, 'path': str(source), 'text': text,
        'baseline': base64.b64encode(baseline).decode(), 'encoding': 4, 'bom': '',
    }))
    syntax_metric = root / 'syntax.json'
    env = dict(os.environ, TCODE_SUPPORT_DIRECTORY=str(profile),
               TCODE_RECOVERY_PATH=str(recovery), TCODE_SYNTAX_METRICS_PATH=str(syntax_metric))
    process = subprocess.Popen([str(binary), str(workspace)], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 20
        worker_pid = None
        syntax = None
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('App exited before loading its syntax helper')
            if syntax_metric.exists():
                syntax = json.loads(syntax_metric.read_text())
                if syntax['status'] != 'Tree-sitter':
                    raise RuntimeError(f"Restored document parsing failed: {syntax['status']}")
                worker_pid = syntax['helper_pid']
                matches = [pid for pid, _, command in processes()
                           if command.startswith(str(helper))]
                if worker_pid not in matches or syntax['span_count'] <= 0:
                    raise RuntimeError('Syntax result did not identify a live packaged helper')
                break
            time.sleep(0.1)
        if worker_pid is None:
            raise RuntimeError('Expected one packaged syntax helper for the restored buffer')
        time.sleep(5)
        samples = []
        for _ in range(5):
            rows = {pid: rss for pid, rss, _ in processes()}
            main_rss = rows[process.pid] * 1024
            worker_rss = rows[worker_pid] * 1024
            samples.append({'main_rss_bytes': main_rss, 'helper_rss_bytes': worker_rss,
                            'combined_rss_bytes': main_rss + worker_rss})
            time.sleep(0.2)
        result = {
            'dataset_lines': text.count('\n'), 'dataset_bytes': len(text.encode()),
            'main_pid': process.pid, 'helper_pid': worker_pid, 'samples': samples,
            'main_executable_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'helper_executable_sha256': hashlib.sha256(helper.read_bytes()).hexdigest(),
            'syntax': syntax,
            'median_main_rss_mib': statistics.median(x['main_rss_bytes'] for x in samples) / 1048576,
            'median_helper_rss_mib': statistics.median(x['helper_rss_bytes'] for x in samples) / 1048576,
            'median_combined_rss_mib': statistics.median(x['combined_rss_bytes'] for x in samples) / 1048576,
            'measurement': 'Paired ps RSS snapshots, 5 seconds after successful native highlighting through the packaged XPC helper, restored Rust buffer; no LSP, task, debugger or terminal. RSS is not physical footprint or peak memory. No screen-latency or visual-highlighting assertion.',
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
