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
| Radio | ☐ | Cellular, Wi-Fi, network latency, heading, UWB distance (S-023) | R1, R2, R3 |

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

## P5

- ☑ `SensingLink`: the phone-watch protocol, with WatchConnectivity behind `LinkTransport`, so all of it runs against a fake on macOS. `PhoneLink`, `WatchLink`, `ChunkReceiver`, `PhoneRelayUploader` and `WCLinkTransport`
- ☑ `ChunkUploader` and `ChunkDrainer` (`SensingEngine`): Android's `UploadTransport`, with the watch's route to the phone as its first implementation, at most 4 at a time, retrying from 30 s doubling to an hour, ±20%
- ☑ `WatchSensing`, the watch's public API, on `WorkoutKeeper` and the same `RecordingController` as the phone. A watch crash with the workout alive resumes the recording in a new engine session, with `process_death` recorded
- ☑ `Sensing` starts the watch with `startWatchApp`, tries once more after 5 s, and records `peer_start_failed` with a banner if that fails too. A relaunched phone tells the watch to stop
- ☑ A watch screen and a Watch section on the phone's Record tab. Both apps build for real devices
- ☑ The Phase 1 watch probe and `ProbeLink` are gone, since a `WCSession` has one delegate. The phone's bare recorder stays in Diagnostics. Their evidence is in P1 above, and the code is in git history
- ☑ 42 link tests with a fake link: newest generation only, across relaunches; the link down, with the watch recording on to its time limit; Stop on the watch, with and without the link; crashes on both sides; lost and duplicate acks; a corrupt file; the same id with other bytes; bad ids; four at a time. The thread sanitizer is clean on them
- Testing and review found 4 real bugs, all fixed: a duplicate `bad` ack failed every later attempt unsent; a drain could delete the metadata of a chunk still arriving, stranding it; a state arriving before recovery finished could start a recording mid-recovery; a watch recording ended by a crash never told the phone. The second is a race, and the test for it failed only 1 run in 6 with the fix removed, so it can catch that bug but won't every time
- A refinement to the plan: the watch's Stop button stops the watch at once and tells the phone, rather than waiting for the phone's answer when it's reachable. It's one code path, and the phone stopping is unchanged
- ☐ **Nothing in this phase has run on a device.** The link has only met the fake, so real WatchConnectivity behaviour is unproven: delivery with the phone locked, the watch's reachability wrist-down, `startWatchApp` under the SDK. A2, A8, A9 and A10 are still to come

## P6

- ☑ `LocationAdapter`, `ActivityAdapter`, `BatteryAdapter`, `ScreenAdapter`, `NetworkAdapter`, `AudioLevelAdapter`, and `BluetoothAdapter` on the phone. All build for iPhone and Apple Watch
- ☑ What they compute is pure and tested on macOS: Android's `DeviceAdaptersTest` where it applies (the dBFS values, the `[n, 2]` tensor, the network attributes, salted 16-character hashes), plus battery attributes, invalid location values, one-activity-at-a-time transitions and the catalog's defaults
- ☑ Sound and Bluetooth default to off (S-008). Location and activity default to on for the phone and off for the watch
- ☐ **None of these adapters has run on a device.** Only their mappings are tested. Permission prompts for the mic and Bluetooth come with P7's Permissions screen; until then those two report `adapter_unavailable`. A11 (the rest), A12 and A13 are still to come

## P7

- ☑ `ZipWriter`, `RecordingExporter` and `ChunkInspector`: a store-only zip with `manifest.json` (`sensing-export/1`), under the ingest's landing paths. Real `unzip -t` checks it in tests
- ☑ `scripts/compat.sh` now takes a whole recording through the real controller and exporter, and hands the zip to Android's and the ingest's real decoders: 521 samples identical in both, 4 label events became 2 session writes and 2 label writes, nothing skipped. This is A15 on made-up samples; A15 proper needs a real export
- ☑ The example app: a searchable picker over the taxonomy's active ids, with labels in the lab app's attributes (`Activities.kt`); Permissions; Sensors, for each device; Recordings, with rates and gaps from the chunks, missing watch chunks, Export and Delete; Diagnostics, with storage and chunks no recording claims
- ☑ Debug actions for the device tests: `-debugQuotaMiB` and `-deleteOldest` (A14), Crash now on the watch (A8), and `-recordAutostart`
- ☑ `scripts/sync-taxonomy.sh`, and `Example/iOS/TAXONOMY_SOURCE.txt`, which says where the copy came from. `PrivacyInfo.xcprivacy` on both apps
- ☑ A recording on a paired iPhone 18 Pro and Series 12 simulator (S-021), through the real app, 2026-11-02, 20 s. The watch app started from the phone's published state, recorded under the same recording id, and stopped with `phone_stop`. The phone wrote a real `peer_clock`. Location, network, screen and battery adapters ran without crashing, and `sensing-decode --check` was clean. Motion isn't available on a simulator, so it recorded `adapter_unavailable`, as it should
- It found what the fake link couldn't: `loc.fused` going back in time when an event stamped now was followed by a fix with an older timestamp (now `ForwardGate`, also on activity and steps, and a cached fix from before the recording is dropped); the phone's Stop saving its own copy of the record over the watch's sessions, which an export needs; and a blank rate picker for sensors whose default isn't a listed rate. All fixed
- ☐ **On a simulator, chunks never left the watch** (S-021), so file transfer through the SDK, acks and the summary are proven only against the fake. A9 and A10 are what will settle it
- ☐ A7, A14 and A15 are still to come on real devices
- ☑ Every recording needs a label: Start stays disabled and says why until an activity is chosen, and the choice clears after each recording, so a carried-over label can't mislabel the next one. Debug `-recordAutostart` is the only thing that picks one by itself
- ☑ Export is on each row of the Recordings list as well as on the recording's own screen. Tested through the app's own flow on a simulator, 2026-11-02: the share sheet opened with the zip, real `unzip -t` passed, `sensing-decode --check` was clean, and the manifest carried the label and taxonomy id

## Radio sensors

- ☑ `CellularAdapter`, `WifiConnectionAdapter` and `NetworkLatencyAdapter` on the phone; `HeadingAdapter` and `UwbDistanceAdapter` on both. What they compute is pure and tested on macOS. Wi-Fi names and addresses are hashed there, before they can reach a sample
- ☑ A signed device build, 2026-11-02: Apple accepted `com.apple.developer.networking.wifi-info` through automatic signing
- ☑ All of them on a paired simulator, 25 s, through the real app, 2026-11-02, and `sensing-decode --check` was clean:
  - `device.network_rtt`: a real probe, `connect_ms` 19, `smoothed_ms` 17, over Wi-Fi
  - `device.peer_distance`: 26 samples at 1 Hz, so tokens crossed real WatchConnectivity both ways and ranging ran. Every distance was 0.0, the simulator's, so this says nothing about accuracy
  - `device.cellular`: `radio=none`, `device.wifi`: `identity=unavailable`, as a simulator should. `loc.heading` reported `missing_hardware`
- ☐ `device.network` read `ipv4=false` and `ipv6=false` on that working network. It may be the simulator. Check on a device in R1, and drop both if they read false there too
- ☐ R1 to R3 on real devices: none of the radio adapters has run on one. R3 says whether a locked phone suspends UWB
