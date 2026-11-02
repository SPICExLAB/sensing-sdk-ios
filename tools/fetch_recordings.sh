#!/usr/bin/env bash
# Copy recordings off the iPhone into exports/recordings (gitignored: this can be participants' data), then check them.
#   tools/fetch_recordings.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PHONE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
[ -n "$PHONE" ] || { echo "no iPhone connected" >&2; exit 1; }
rm -rf exports/recordings
mkdir -p exports/recordings
xcrun devicectl --timeout 280 device copy from --device "$PHONE" --domain-type appDataContainer \
  --domain-identifier com.rahulislam.sensing.example --source "Library/Application Support/sensing" --destination exports/recordings | tail -1
swift run -q sensing-decode exports/recordings --check
