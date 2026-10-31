#!/bin/bash
set -euo pipefail
task_sdk_root="$(cd "$(dirname "$0")/.." && pwd)"
task_codegen_dir="$task_sdk_root/Tools/L4ProtocolCodegen"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
    echo "Usage: bash scripts/generate-l4-protocol.sh [--check]" >&2
    exit 2
fi
swift build --package-path "$task_codegen_dir"
python3 - "$task_sdk_root" "${1:-}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
outputs = root / 'Tools/L4ProtocolCodegen/.build/plugins/outputs'
destination = root / 'Sources/HyperliquidCore/MarketData/L4/Quicknode/Generated'
destination.mkdir(parents=True, exist_ok=True)
outdated = []
for name in ('quicknode_l4.pb.swift', 'quicknode_l4.grpc.swift'):
    candidates = list(outputs.rglob(name))
    if len(candidates) != 1:
        raise SystemExit(f'Expected one generated {name}, found {len(candidates)}')
    content = candidates[0].read_bytes()
    target = destination / name
    if sys.argv[2] == '--check':
        if not target.exists() or target.read_bytes() != content:
            outdated.append(name)
    else:
        target.write_bytes(content)
if outdated:
    raise SystemExit('Generated L4 protocol sources are outdated: ' + ', '.join(outdated))
print('L4 protocol sources verified.' if sys.argv[2] == '--check' else 'L4 protocol sources generated.')
PY
