# Progress

Plan: [PLAN.md](PLAN.md) · Decisions: [DECISIONS.md](DECISIONS.md) · Open questions: [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md)

**Status key:** ☐ not started · ◐ in progress · ☑ done · ⛔ blocked

| Phase | Status | Delivers | Checked by |
|---|---|---|---|
| P0 | ☑ | Repo, package, proto, zlib compile, lints, plan docs | Builds and tests, including the watch target |
| P1 | ☑ | Diagnostics screen, bare locked recording on phone and watch | A0, rough A1 and A2. **Stop and report**: this decides the adapter design |
| P2 | ☑ | Storage and `sensing-decode` | Android test vectors; `compat.sh` both ways |
| P3 | ☑ | Engine, config, activity sessions, outbox | Fake-adapter soak; killing a writer process and recovering |
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

## P3

- ☑ `Intake` (`SensingCore`): callbacks push under a short lock, with `seq` assigned there. No I/O, task hop or string work per sample. A motion payload is stored inline
- ☑ `CollectionEngine` (`SensingEngine`): an actor on its own serial queue with no suspension point inside, on a 500 ms tick. `Batcher` builds batches from each sample's bytes
- ☑ `ActivitySessions` with its persisted outbox, and `CollectionConfig`, `SleepOffsetTracker` and `DeviceIdentity`
- ☑ Android's `ActivitySessionsTest` and `CollectionConfigTest` ported case for case, plus engine tests with a fake clock and fake adapters
- ☑ Soak: 8 streams at 100 Hz for 5 simulated minutes, 240,000 samples with nothing lost and seq contiguous, processed in 1.15 s on this Mac in a debug build, 2026-11-02. The real watch number comes from A3
- ☑ Thread sanitizer: no data races across the engine and intake tests
- ☑ A real process at full rate with the real timer, killed with SIGKILL and recovered: every stream contiguous from 0, under 3 s lost. A batch reaches the file every 2 to 2.5 s, which sets that bound
- ☑ `scripts/compat.sh` now judges real `SessionEvents`: 8 label events, including a discarded session, became 4 session writes and 4 label writes in the ingest's `projectLabels`, with nothing skipped
- Tests found 3 real bugs, all fixed: events raised during Stop's final drain were lost; a sample took 145 bytes because a rare large payload was stored inline; delete-oldest could evict label chunks and the eviction records themselves, which Android's can too

## P4

- ☑ `MotionAdapter`, `AltimeterAdapter`, `PedometerAdapter`, with `Conversions` and `Decimator` tested on macOS
- ☑ `Sensing`, the iPhone's public API, on `RecordingController`, which holds the whole recording flow with no platform code and is tested with fake sensors: labels, a double tap on Start, Stop during Start, discard, the time limit, a full disk, crash recovery
- ☑ A minimal Record tab in the example app, driven from the command line in debug builds for device tests
- ☑ First real chunks, iPhone 15 Pro, iOS 26.7.1, 2026-11-02, screen on and at rest, debug build, 40 s with the six motion streams at 100 Hz: 100.53 Hz, nothing lost, no motion gap over 10 ms, `sensing-decode --check` clean, 8.1% of one core. Gravity 9.807 m/s² with Android's signs, linear acceleration and gyroscope near zero, field 40 µT, unit quaternions, 997.5 hPa. About 14 KiB/s on disk at that rate
- ☐ A1, A3, A4 and A11 (phone)
