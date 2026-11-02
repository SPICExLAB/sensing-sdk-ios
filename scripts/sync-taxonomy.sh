#!/usr/bin/env bash
# Copies the lab's activity taxonomy into the example app, and records where it came from. The SDK itself knows nothing about
# the taxonomy: labels are only strings to it. Re-run this after a taxonomy release in inrtl-lab.
#   scripts/sync-taxonomy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE=../inrtl-lab/cloud/dashboard/internal/api/taxonomy.json
cp "$SOURCE" Example/iOS/taxonomy.json
COMMIT=$(git -C ../inrtl-lab log -1 --format=%h -- cloud/dashboard/internal/api/taxonomy.json)
VERSION=$(python3 -c "import json; print(json.load(open('Example/iOS/taxonomy.json'))['version'])")
printf 'inrtl-lab cloud/dashboard/internal/api/taxonomy.json @%s, taxonomy version %s\n' "$COMMIT" "$VERSION" > Example/iOS/TAXONOMY_SOURCE.txt
cat Example/iOS/TAXONOMY_SOURCE.txt
