#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ "$(git branch --show-current)" != "port/g7-direct" ]; then
  echo 'Stop: switch to port/g7-direct first.' >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo 'Stop: save your existing changes first.' >&2
  exit 1
fi
command -v python3 >/dev/null
DRIVER=86041a7dcddb81325102369ada68b7b53113c223
URL=https://github.com/loopandlearn/G7SensorKit.git
if [ "$(git config -f .gitmodules --get submodule.G7SensorKit.url)" != "$URL" ]; then
  echo 'Stop: unexpected G7SensorKit dependency URL.' >&2
  exit 1
fi
git submodule update --init --recursive
if [ -n "$(git -C G7SensorKit status --porcelain)" ]; then
  echo 'Stop: G7SensorKit has local changes.' >&2
  exit 1
fi
git -C G7SensorKit fetch "$URL" "$DRIVER"
git -C G7SensorKit checkout --detach "$DRIVER"
git -C G7SensorKit submodule update --init --recursive
python3 - <<'PY'
from pathlib import Path
import plistlib
p = Path('Trio/Resources/Info.plist')
raw = p.read_text()
data = plistlib.loads(raw.encode())
if 'NSCameraUsageDescription' not in data:
    marker = '\t<key>NSContactsUsageDescription</key>'
    if raw.count(marker) != 1:
        raise SystemExit('Stop: unexpected plist layout; inspect manually.')
    addition = '\t<key>NSCameraUsageDescription</key>\n\t<string>Camera is used to scan the code on your Dexcom sensor packaging.</string>\n'
    updated = raw.replace(marker, addition + marker, 1)
    plistlib.loads(updated.encode())
    p.write_text(updated)
PY
git diff --check
git diff --submodule=short -- G7SensorKit Trio/Resources/Info.plist
printf '\nPrepared locally only. No commit or push performed. Build in Xcode and validate before use.\n'
