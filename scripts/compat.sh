#!/usr/bin/env bash
# Proves the chunk format against Android's and the ingest's real decoders, comparing decoded content (gzip output and
# map order vary, so bytes are the wrong target). Nothing committed in the other repos changes. It needs ../sensing-sdk
# and ../inrtl-lab checkouts, Go, and network for Gradle's first run.
#   scripts/compat.sh                    Swift writes, JVM and Go read
#   scripts/compat.sh --regen-fixtures   also rewrites Tests/Fixtures from JVM and Go writers
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
unset GOOGLE_APPLICATION_CREDENTIALS CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE
TMP=$(mktemp -d)
INGEST=$(cd ../inrtl-lab/cloud/ingest && pwd)
FAILED=0
step() { printf '%-48s' "$1"; }
pass() { echo "ok${1:+  ($1)}"; }
fail() { echo "FAILED: $1"; FAILED=1; }

gradle_run() { ../sensing-sdk/gradlew -q -p tools/android-compat run --args="$1" 2>"$TMP/gradle.err"; }

overlay() {
  cat > "$TMP/overlay.json" <<JSON
{"Replace": {"$INGEST/internal/server/zz_compat_test.go": "$ROOT/tools/go-compat/compat_test.go"}}
JSON
}

go_status_before=$(git -C ../inrtl-lab status --porcelain)
sdk_status_before=$(git -C ../sensing-sdk status --porcelain)

step "Swift writes the fixture"
if out=$(swift run -q sensing-compat write "$TMP/swift" 2>&1); then pass "$out"; else fail "$out"; fi

step "JVM reads it (FrameCodec.kt, Wire)"
if gradle_run "read $TMP/swift" > "$TMP/jvm.txt"; then
  if diff -q "$TMP/swift/expected.txt" "$TMP/jvm.txt" >/dev/null; then pass "$(wc -l < "$TMP/jvm.txt" | tr -d ' ') samples identical"
  else fail "content differs"; diff "$TMP/swift/expected.txt" "$TMP/jvm.txt" | head -10; fi
else fail "$(tail -15 "$TMP/gradle.err")"; fi

step "Go reads it (frames.Decode, rowsFor, projectLabels)"
overlay
if out=$(cd "$INGEST" && COMPAT_READ="$TMP/swift" COMPAT_OUT="$TMP/go.txt" go test -overlay "$TMP/overlay.json" -count=1 -v -run '^TestCompatRead$' ./internal/server/ 2>&1); then
  if diff -q "$TMP/swift/expected.txt" "$TMP/go.txt" >/dev/null; then pass "$(echo "$out" | grep -oE '[0-9]+ chunks.*writes' | head -1)"
  else fail "content differs"; diff "$TMP/swift/expected.txt" "$TMP/go.txt" | head -10; fi
else fail "$(echo "$out" | tail -15)"; fi

if [ "${1:-}" = "--regen-fixtures" ]; then
  step "JVM writes Tests/Fixtures/android"
  rm -rf Tests/Fixtures/android
  if gradle_run "write $ROOT/Tests/Fixtures/android" >/dev/null; then pass; else fail "$(tail -15 "$TMP/gradle.err")"; fi
  step "Go writes Tests/Fixtures/go"
  rm -rf Tests/Fixtures/go
  if out=$(cd "$INGEST" && COMPAT_WRITE="$ROOT/Tests/Fixtures/go" go test -overlay "$TMP/overlay.json" -count=1 -run '^TestCompatWrite$' ./internal/server/ 2>&1); then pass; else fail "$(echo "$out" | tail -15)"; fi
fi

step "Swift reads the committed fixtures"
out=""
if [ -d Tests/Fixtures/android ] && out=$(swift test --filter FixtureTests 2>&1); then pass "$(echo "$out" | grep -oE 'Executed [1-9][0-9]* tests' | tail -1)"
else fail "$(echo "${out:-no fixtures: run with --regen-fixtures}" | tail -15)"; fi

step "the other repos are untouched"
if [ "$go_status_before" = "$(git -C ../inrtl-lab status --porcelain)" ] && [ "$sdk_status_before" = "$(git -C ../sensing-sdk status --porcelain)" ]; then pass; else fail "git status changed"; fi

rm -rf "$TMP"
[ "$FAILED" = 0 ] && echo "compat: all checks pass"
exit "$FAILED"
