#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nool-command-channel.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 6 \
  "$root/Sources/NotchApp/Features/Music/MediaRemoteCommandChannel.swift" \
  "$root/Tests/MediaRemoteCommandChannel/main.swift" -o "$scratch/channel-test"
python3 - "$scratch/channel-test" <<'PY'
import signal, subprocess, sys
binary = sys.argv[1]
control = subprocess.run([binary, '--unsafe-control'], capture_output=True, timeout=10)
assert control.returncode == -signal.SIGPIPE, f'Unsafe control did not reproduce SIGPIPE: {control.returncode}'
print('PASS: original pipe write reproduces SIGPIPE (13) in isolated child')
safe = subprocess.run([binary], capture_output=True, text=True, timeout=15)
print(safe.stdout, end='')
if safe.returncode:
    print(safe.stderr, file=sys.stderr)
    raise SystemExit(safe.returncode)
PY
