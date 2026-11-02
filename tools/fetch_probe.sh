#!/usr/bin/env bash
# Copy the probe runs off the iPhone and the watch into exports/ (gitignored: this can be participants' data).
#   tools/fetch_probe.sh
set -uo pipefail
cd "$(dirname "$0")/.."
udid() { xcrun devicectl list devices 2>/dev/null | awk -v want="$1" '$0 ~ want && /physical/' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1; }
fetch() { # udid, bundle id, destination
  [ -n "$1" ] || { echo "no device for $3" >&2; return 1; }
  mkdir -p "$3"
  xcrun devicectl --timeout 280 device copy from --device "$1" --domain-type appDataContainer \
    --domain-identifier "$2" --source Documents/probe --destination "$3" | tail -1
}
fetch "$(udid iPhone)" com.rahulislam.sensing.example exports/probe
fetch "$(udid 'Apple Watch')" com.rahulislam.sensing.example.watchkitapp exports/watch-probe
echo "now: python3 tools/probe_report.py exports/probe exports/watch-probe"
