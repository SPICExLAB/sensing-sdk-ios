# Progress

Plan: [PLAN.md](PLAN.md) · Decisions: [DECISIONS.md](DECISIONS.md) · Open questions: [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md)

**Status key:** ☐ not started · ◐ in progress · ☑ done · ⛔ blocked

| Phase | Status | Delivers | Checked by |
|---|---|---|---|
| P0 | ☑ | Repo, package, proto, zlib compile, lints, plan docs | Builds and tests, including the watch target |
| P1 | ☑ | Diagnostics screen, bare locked recording on phone and watch | A0, rough A1 and A2. **Stop and report**: this decides the adapter design |
| P2 | ☑ | Storage and `sensing-decode` | Android test vectors; `compat.sh` both ways |
| P3 | ☐ | Engine, config, activity sessions, outbox | Fake-adapter soak; killing a writer process and recovering |
| P4 | ☐ | Phone motion adapters, keep-alive, minimal app | A1, A3, A4, A11 (phone) |
| P5 | ☐ | Watch app, workout, link, transfer, clock pairing, recovery | A2, A8, A9, A10 |
| P6 | ☐ | Location, activity, device state, sound, Bluetooth | A11 (rest), A12, A13 |
| P7 | ☐ | Full example app, labels, export | A7, A14, A15 |
| P8 | ☐ | Soak, tuning, docs; KB repo table updated and that page republished | A5, A6 |

## P0

- ☑ Package with its targets, swift-protobuf 1.39.0, minimum iOS 17 / watchOS 10 / macOS 14
- ☑ `sensorlog.v1` copied from sensing-sdk @183d765 and generated; `scripts/check.sh` compares it against the pin
- ☑ `import zlib` compiles and links for watchOS and iOS, with real gzip members (no hand-built wrapper), 2026-11-02
- ☑ Known answers pass: identifier hash `b57a3b2f7dad4b8a`, CRC-32 `0xCBF43926`
- ☑ `scripts/check.sh` with its lints

## P1

- ☑ `KeepAliveController` (SensingKit) with four modes: none, location at 100 m, location at 3 km, workout on iPhone (iOS 26)
- ☑ `WorkoutKeeper` (SensingWatch): workout share only, no heart rate, nothing saved to Health, failures reach `onEvent`, recovery
- ☑ `Clock` (SensingCore): `CLOCK_MONOTONIC_RAW`, `CLOCK_UPTIME_RAW`, the sleep offset
- ☑ Example app's diagnostics screens on phone and watch, the bare CSV recorder, `tools/probe_report.py`, `tools/fetch_probe.sh`
- ☑ Smoke tests on iOS 27 and watchOS 27 simulators, 2026-11-02: each mode starts and stops with no crash, events are written, and the workout session reaches state 2 in both. Simulators have no motion sensors, so this says nothing about Q1–Q6
- ☑ `probe_report.py` checked on a synthetic run: it finds a planted 2 s hole, 96.7% of expected samples
- ☑ Signing: blocked until the team's account holder accepted the latest Program License Agreement, 2026-11-02. New App IDs now exist with HealthKit
- ☑ Rough A1 and A2 on an iPhone 15 Pro (iOS 26.7.1) and an Apple Watch Series 9 (watchOS 26.6), 2026-11-02, unplugged. Rates come from sample timestamps. These runs use the bare recorder, not the engine:

  | Run | Duration | Accelerometer | Rate | Max gap | Gaps over 100 ms |
  |---|---|---|---|---|---|
  | Phone, no keep-alive (control) | 547 s | 1,725 samples, about 6% of expected | Stopped about 16 s after locking | 78 s of uptime; the phone slept 377 s | 2 |
  | Phone, location at 100 m, locked in a pocket | 1,487 s, locked 1,478 s | 74,764 samples, 100.6% | 50.28 Hz, median 19.89 ms | 29.8 ms | 0 |
  | Watch, workout session, worn, started by `startWatchApp` | 1,487 s | 74,454 samples, 100.1% | 50.07 Hz, median 19.97 ms | 20.0 ms | 0 |

- ☑ A0: Q1, Q2, Q3, Q4 and Q6 closed (S-014 to S-017). Barometer as delivered: 0.94 Hz on the phone, 0.39 Hz on the watch. A 16 MB file transfer from watch to phone completed, but see Q10
- ☐ Not run, because it wasn't needed: the workout-on-iPhone fallback, 3 km accuracy

## P2

- ☑ `SensingStorage`: frames, chunk writer, recovery with a startup sweep, retention with a persisted eviction outbox, the store, JSON records beside each chunk
- ☑ Android's test vectors ported case for case (`FrameCodecTest`, `ChunkWriterRecoveryTest`, `RetentionTest`), plus tests for each deliberate difference
- ☑ `sensing-decode`: chunks to CSV, a rate and gap report from `ts_mono_ns`, and `--check` against each chunk's record. It reports where Android's reader and the ingest's would disagree on a damaged file
- ☑ `scripts/compat.sh`, 2026-11-02, comparing decoded content sample by sample. Nothing committed in the other repos changes:
  - Swift's 8 chunks and 212 samples, covering all 6 payload types, read identically through Android's real `FrameCodec.kt` and Wire
  - and through the ingest's real `frames.Decode` (0 skipped), `rowsFor` and `projectLabels`: 4 label events became 2 session writes and 2 label writes, with nothing skipped
  - Swift reads the Android-written and Go-written fixtures now committed in `Tests/Fixtures`, the golden fixtures this format never had, and agrees with Android's scanner on where damaged files stop being valid
- ☑ The check can fail: a little-endian CRC and raw deflate in place of gzip were each caught by both JVM and Go
- ☐ Not yet on a device: it's run on macOS, and it compiles for iOS and watchOS. The first real chunks come with P4
