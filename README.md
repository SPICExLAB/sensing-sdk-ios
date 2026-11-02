# sensing-sdk-ios

A Swift SDK that records iPhone and Apple Watch sensors to disk, plus an example data-collection app. It's the counterpart of the Android [`sensing-sdk-android`](https://github.com/SPICExLAB/sensing-sdk-android) and writes the same `sensorlog.v1` chunk format, so the data can sit alongside Android's without conversion. It isn't connected to inrtl Lab yet: data stays on the device and is exported by hand.

**Status: in progress.** See [`docs/plan/PROGRESS.md`](docs/plan/PROGRESS.md).

| Doc | Holds |
|---|---|
| [`docs/plan/PLAN.md`](docs/plan/PLAN.md) | The approved plan |
| [`docs/plan/PROGRESS.md`](docs/plan/PROGRESS.md) | Status by phase, with evidence |
| [`docs/plan/DECISIONS.md`](docs/plan/DECISIONS.md) | Decisions, S-NNN |
| [`docs/plan/OPEN-QUESTIONS.md`](docs/plan/OPEN-QUESTIONS.md) | Open questions and risks |
| [`docs/ANDROID-DIFFERENCES.md`](docs/ANDROID-DIFFERENCES.md) | Where iOS data differs from Android's |
| [`AGENTS.md`](AGENTS.md) | Rules for anyone working in this repo |

## Build and test

Needs Xcode 16 or later. Minimum targets are iOS 17 and watchOS 10; only version 27 simulators have been used so far, so older versions get compiler checks only.

```sh
swift test                 # the platform-neutral code, on macOS
scripts/check.sh           # everything a PR must pass: lints, tests, iOS and watchOS builds
scripts/check.sh --quick   # lints and tests only
scripts/gen-proto.sh       # regenerate Sources/SensingProto from proto/
scripts/compat.sh          # proves the format against Android's and the ingest's real decoders
                           # (needs ../sensing-sdk-android, ../inrtl-lab and Go; run it whenever storage changes)
```

## Checking a recording on a Mac

```sh
swift run sensing-decode <export.zip or folder> --check --out DIR
```

It prints each stream's rate and gaps, writes CSVs, and verifies each chunk. An export is participants' data: keep it out of this repo.
