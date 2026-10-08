#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python_path="${1:-/opt/homebrew/bin/python3.12}"
tools_path="$HOME/Library/Application Support/tCode/tools"
"$python_path" -m venv "$tools_path"
"$tools_path/bin/python" -m pip install -r docs/tool-requirements.txt
print "Tools installed in $tools_path; no project dependencies were modified."
