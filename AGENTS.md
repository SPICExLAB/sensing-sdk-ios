# Agents: working in sensing-sdk-ios

Read [`README.md`](README.md), then [`docs/plan/PROGRESS.md`](docs/plan/PROGRESS.md) and [`docs/plan/PLAN.md`](docs/plan/PLAN.md). Android's `sensing-sdk/AGENTS.md` explains the format and the engine this repo mirrors.

## How work lands

- Branch `<area>/<slug>` from `origin/main`, then a PR, then a squash merge after `scripts/check.sh` passes. GitHub Actions don't run for this account, so the script is the gate; say so in the PR with `check: all jobs pass @<sha>`.
- Update `docs/plan/PROGRESS.md` in the same PR, with evidence. A decision gets a new S-NNN row at the bottom of `DECISIONS.md`; past rows are never edited.
- Anything that changes what iOS data means compared with Android goes in `docs/ANDROID-DIFFERENCES.md`.
- Anything touching `Sources/SensingStorage` or `proto/` also needs `scripts/compat.sh` to pass. `--regen-fixtures` rewrites `Tests/Fixtures` from Android's and Go's real writers; only do that when their format changed.

## Rules that must not break

- **The format is Android's.** `proto/` is a copy of Android's `envelope.proto`, compared against the pin in `proto/SENSING_SDK_REF`. Never edit it here: change it in `sensing-sdk` first, additively, then bump the pin. There's no platform field in the envelope, so values are converted to Android's units and signs on the device, and axes are never remapped.
- **`ts_mono_ns` counts sleep, as Android's `elapsedRealtimeNanos` does.** `CMLogItem.timestamp` doesn't. Never judge timing by arrival time, only by `ts_mono_ns`: Wi-Fi bunching once produced dozens of fake dropouts.
- **`Int` is 32 bits on the watch.** Nanoseconds, seq and byte totals are `Int64`. macOS tests can't catch this, and `scripts/check.sh` flags `Int(` in Core and Storage.
- **Nothing downstream may slow the write path, and loss is always recorded.** A sample callback never does I/O, never hops to a task, and never allocates a string. Drops consume their `seq` and appear in `device.gap`.
- **The engine has no suspension points.** It's an actor on its own serial queue with no `await` inside, so it can't hit the re-entrancy bug class Android hit. Public commands run through one serial queue.
- **A file is deleted only after it's safely elsewhere:** on the watch, only after the phone's ack.
- **No `health.*` sensors and no heart-rate read.** Health data is out of scope, and `SensorID` refuses the group.
- **No audio is ever kept, and scanned identifiers are always hashed.**
- **Exports are participants' data.** They never go in this repo.
- **Lower-case UUIDs,** POSIX number formatting in attributes. `scripts/check.sh` flags both.

## Layout

| Path | Holds |
|---|---|
| `Sources/SensingProto` | Generated from `proto/` by `scripts/gen-proto.sh`; committed |
| `Sources/SensingCore` | Clock, sensor ids, conversions, hashing, the engine |
| `Sources/SensingStorage` | Frames, gzip, chunks, recovery, retention |
| `Sources/SensingAdapters` | One adapter per sensor; adapters never touch disk |
| `Sources/SensingLink` | WatchConnectivity behind a protocol |
| `Sources/SensingKit`, `Sources/SensingWatch` | The public APIs for phone and watch |
| `Sources/sensing-decode` | macOS tool: chunks to CSV, plus a rate and gap report |
| `Sources/sensing-compat`, `tools/android-compat`, `tools/go-compat` | What `scripts/compat.sh` runs. The canonical line they share is defined in `Canonical.swift` |
| `Example/` | The example app (`xcodegen generate` in that folder; the `.xcodeproj` is ignored) |
