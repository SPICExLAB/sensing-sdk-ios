#!/usr/bin/env bash
# The gate every PR passes first (GitHub Actions don't run for this account). Prints one line per job and exits 1 if
# any fails.
#   scripts/check.sh           everything
#   scripts/check.sh --quick   lints and macOS tests only, without the iOS and watchOS builds
set -uo pipefail
cd "$(dirname "$0")/.."
QUICK=${1:-}
FAILED=0
LOG=$(mktemp -d)
job() { # name, command...
  local name=$1; shift
  if "$@" >"$LOG/$name.log" 2>&1; then echo "ok      $name"; else echo "FAILED  $name (log: $LOG/$name.log)"; tail -25 "$LOG/$name.log"; FAILED=1; fi
}

proto_matches_android() {
  [ -d ../sensing-sdk/.git ] || { echo "no ../sensing-sdk checkout: skipped"; return 0; }
  git -C ../sensing-sdk show "$(cat proto/SENSING_SDK_REF):sensing-model/src/main/proto/sensorlog/v1/envelope.proto" |
    cmp - proto/sensorlog/v1/envelope.proto
}

# The engine is an actor with no suspension points, so it can't hit the re-entrancy bug class Android's engine hit
# (sensing-sdk AGENTS.md: a loop over batchers across a suspension point crashed).
no_await_in_engine() {
  [ -d Sources/SensingCore/Engine ] || return 0
  ! grep -rnE '\bawait\b' Sources/SensingCore/Engine --include='*.swift' | grep -v '// await-ok'
}

# Int is 32 bits on the watch's arm64_32, and macOS tests can't catch an overflow: nanoseconds, seq and byte totals are
# Int64. A conversion that's really safe says why with `// int-ok: <reason>`.
no_int_conversions() {
  ! grep -rnE '(^|[^A-Za-z0-9_.])Int\(' Sources/SensingCore Sources/SensingStorage --include='*.swift' | grep -v '// int-ok'
}

# Swift's uuidString is upper case; Android's ids are lower case, and the ingest stores them verbatim.
uuids_are_lowercase() {
  ! grep -rn 'uuidString' Sources Example --include='*.swift' | grep -v 'lowercased()'
}

# Attribute numbers use POSIX formatting: Android's default-locale format changes values in comma-decimal locales.
no_locale_number_format() {
  ! grep -rnE 'String\(format:' Sources/SensingCore Sources/SensingStorage Sources/SensingAdapters --include='*.swift' | grep -v 'locale:'
}

job proto-matches-android proto_matches_android
job no-await-in-engine no_await_in_engine
job no-int-conversions no_int_conversions
job uuids-are-lowercase uuids_are_lowercase
job no-locale-number-format no_locale_number_format
job swift-test swift test
if [ "$QUICK" != "--quick" ]; then
  job build-watchos xcodebuild -scheme SensingWatch -destination generic/platform=watchOS -derivedDataPath .build/xc build
  job build-ios xcodebuild -scheme SensingKit -destination generic/platform=iOS -derivedDataPath .build/xc build
  if [ -f Example/project.yml ]; then
    example() {
      (cd Example && xcodegen generate --quiet) &&
        xcodebuild -project Example/SensingExample.xcodeproj -scheme Example -destination generic/platform=iOS \
          -derivedDataPath .build/xc CODE_SIGNING_ALLOWED=NO build
    }
    job build-example example
  fi
fi
[ "$FAILED" = 0 ] && echo "check: all jobs pass @$(git rev-parse --short HEAD 2>/dev/null)"
exit "$FAILED"
