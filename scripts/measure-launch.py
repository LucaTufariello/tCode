#!/usr/bin/env python3
"""Measure a local release build's first native layout and idle RSS.
Runs only a supplied fixture folder; language tools and tasks are not activated.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, default=Path('dist/tCode.app'))
parser.add_argument('--workspace', type=Path, required=True)
parser.add_argument('--output', type=Path, default=Path('artifacts/launch-metrics.json'))
parser.add_argument('--runs', type=int, default=5)
args = parser.parse_args()
binary = args.app.resolve() / 'Contents/MacOS/tCode'
measurements = []
with tempfile.TemporaryDirectory(prefix='tcode-launch-') as directory:
    for index in range(args.runs):
        metric = Path(directory) / f'{index}.json'
        env = dict(os.environ, TCODE_METRICS_PATH=str(metric),
                   TCODE_LAUNCH_STARTED=str(time.time()),
                   TCODE_SUPPORT_DIRECTORY=str(Path(directory) / 'Support'),
                   TCODE_RECOVERY_PATH=str(Path(directory) / 'Recovery'))
        process = subprocess.Popen([str(binary), str(args.workspace.resolve())], env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 15
            while not metric.exists() and time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('App exited before its first layout')
                time.sleep(0.05)
            value = json.loads(metric.read_text())
            time.sleep(1)
            rss = subprocess.check_output(['ps', '-p', str(process.pid), '-o', 'rss='], text=True)
            value['idle_rss_mib'] = int(rss.strip()) / 1024
            measurements.append(value)
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
result = {
    'runs': measurements,
    'median_first_layout_ms': statistics.median(x['launch_to_first_layout_ms'] for x in measurements),
    'median_idle_rss_mib': statistics.median(x['idle_rss_mib'] for x in measurements),
    'workspace': str(args.workspace.resolve()),
    'app_version': plistlib.loads((args.app.resolve() / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'],
    'executable_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'measurement': 'Warm process launch to first native window layout; RSS after 1 second; excludes tool processes and full document restoration/render latency',
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: v for k, v in result.items() if k != 'runs'}, indent=2))
