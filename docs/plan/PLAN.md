# Plan

_Status: approved 2026-11-02. Track execution in [PROGRESS.md](PROGRESS.md); record changes to this plan in [DECISIONS.md](DECISIONS.md)._

## Context

The Android `sensing-sdk` records phone and watch sensors to disk in the `sensorlog.v1` chunk format. iOS has no equivalent. The existing Swift code (`inrtl-swift`, `iMobilePoser`) only streams live and loses data. None of it stores data for later transfer, and none records in the background on the iPhone.

**Goal:** a Swift SDK for iPhone and Apple Watch, plus an example app that records labelled activities on both devices and exports the data. It's **not connected to inrtl Lab**: no Firebase, sign-in, upload, studies or remote config. The data format stays compatible with Android, so connecting it later needs no conversion.

**Size:** about 7,500 lines of code and 2,400 of tests (Android's main code is about 8,000). It lands in phases, and Phase 1 tests the riskiest assumption before most of the code is written.

## Decisions

**Yours (2026-11-02):**
- Recording runs from Start to Stop, with the screen locked. An always-on mode can be added later and isn't built now.
- Sensors: motion core, location and activity, device state, sound level and Bluetooth.
- The example app has activity labels.
- New repo: `~/code/sensing-sdk-ios`, private as `project-ursula/sensing-sdk-ios`. It moved to `SPICExLAB/sensing-sdk-ios` afterwards (S-022).

**Defaults I chose; say so if you disagree:**
1. **Same data format as Android:** same proto, chunk framing, sensor ids and units, converted on the device. An upload protocol exists in the SDK, with no cloud implementation. The watch-to-phone transfer uses that protocol, so the seam gets exercised.
2. **Full storage stops a recording; it never deletes.** Android deletes the oldest data when it hits its quota, which suits data already being uploaded. Here the device may hold the only copy, so the example app warns at 80% and stops cleanly at the quota. Android's delete-oldest behaviour is an SDK option, off in the app.
3. **Sound and Bluetooth default to off**, with toggles. They add a mic indicator and change device behaviour. Android has them on.
4. **Bluetooth with the screen locked records only a subset.** Apple requires background scans to name service types (`CBCentralManager.h`). So it scans everything when the app is open and a fixed list of common services when locked, with a `scan_mode` event saying which. Phone only in v1.
5. **Start is on the phone only.** The watch can Stop but not Start, because a watch can't start the phone's location keep-alive from the background, and labels live on the phone.
6. **A phone crash ends the recording.** No auto-resume. On next launch, the app recovers the files and records the gap.
7. **Plain SwiftUI, with no Claude Design step**, since this is a developer example rather than a platform screen.

## What's confirmed and what isn't

**Confirmed in the Xcode 27.2 SDK headers:**
- `zlib` links on all platforms, including the watch's `arm64_32`. It writes real gzip directly, so nothing is built by hand.
- `CMLogItem.timestamp` stops during sleep and `CLOCK_MONOTONIC_RAW` doesn't, so timestamps need an offset to match Android's `elapsedRealtimeNanos`.
- `CMAltimeter` delivers "every few seconds" with no rate setting, so Android's 5 Hz and 1 Hz barometer rates can't be matched.
- When-in-use location plus `CLBackgroundActivitySession` (iOS 17, watchOS 10) is enough for background location. "Always" permission isn't needed.
- `completeUntilFirstUserAuthentication` allows writing while locked.
- `Int` can be 32-bit on the watch, which macOS tests won't catch. Everything uses `Int64`, enforced by a lint.

**Unproven; these need a real device (Phase 1):**
- **The biggest risk: does location keep motion data flowing on a locked iPhone?** Nothing local proves it, and `inrtl-swift` notes that "CoreMotion stops in the background" when nothing keeps the app alive.
- Whether a Series 9 sustains 50 Hz wrist-down. Nothing local documents more than about 25 Hz.
- Whether it has a magnetometer and a magnetic-north attitude frame.
- The minimum HealthKit permission for a workout session. The plan is workout share only, no heart rate.
- `transferFile`'s real limits, since none are documented.

## Repo and targets

SwiftPM, Swift tools 6.0, swift-protobuf 1.39.0 (same as `inrtl-swift`). Minimum iOS 17, watchOS 10, macOS 14. Only version 27 simulators are installed here, so older versions get compiler checks only.

| Target | Platforms | Purpose |
|---|---|---|
| `SensingProto` | all | `sensorlog.v1`, generated and committed, copied from `sensing-sdk` @183d765 |
| `SensingCore` | all | Clock, `SensorID`, conversions, identifier hash, intake, batcher, engine, config, activity sessions, `ChunkUploader` |
| `SensingStorage` | all | Frames, gzip, chunk writer, recovery, retention, sidecars, zip |
| `SensingAdapters` | iOS, watchOS | CoreMotion, CoreLocation, audio, Bluetooth, network, battery, screen |
| `SensingLink` | iOS, watchOS | WatchConnectivity behind a protocol, so tests use a fake |
| `SensingKit` | iOS | Public phone API, keep-alive, starting the watch app, receiving chunks |
| `SensingWatch` | watchOS | Public watch API, workout session and recovery, sending chunks |
| `sensing-decode` | macOS | Chunks to CSV, plus a rate and gap report |

Also: `Example/` (XcodeGen, from the template `inrtl-companion/project.yml`), `scripts/{gen-proto,check,compat,sync-taxonomy}.sh`, `tools/{android-compat,go-compat}/`, `docs/plan/` (decisions `S-NNN`, same shape as `inrtl-platform`), `docs/ANDROID-DIFFERENCES.md`, `README.md`, `AGENTS.md`.

**Reuse:**
- `inrtl-swift`: `Sources/InrtlCore/Conventions.swift` and its tests, `scripts/gen-proto.sh`, the package layout.
- `Pulse/watchOS/Engine/HealthKitSessionManager.swift:117-127`: workout recovery, as a pattern to follow.
- **Not reused:** `inrtl-swift`'s watch link and its clock, because `CLOCK_MONOTONIC` can't be paired with `CLOCK_UPTIME_RAW`.

## How it works

**App API (phone):** `Sensing.configure(options)`, `requestPermissions`, `start(RecordingSpec)`, `stop(answers:)`, `discard`, `upsertLabel`, `status`, `recordings()`, `export(id)`, `delete(id)`. Adding a sensor means one adapter and one list entry.

**Sample path:**
```
CoreMotion queue -> convert -> Intake.push (a lock: assigns seq, appends; never does I/O)
  -> CollectionEngine tick every 500 ms (encode, batch, gzip, write)
```
- There's no task or actor hop per sample.
- `seq` is assigned under the lock, so a dropped sample still uses its number, as on Android.
- **Avoiding Android's re-entrancy crash** (`sensing-sdk/AGENTS.md:457-462`):
  - The engine is an actor on its own serial queue with no `await` inside, enforced by a lint.
  - Public commands go through one serial queue, so a double tap on Start queues instead of interleaving.
  - The chunk sender takes a snapshot before suspending.

**Format, same as Android:**
- Frames are `[uvarint length][big-endian CRC-32 of the compressed bytes][one gzip member holding a SampleBatch]`.
- Batches close at about 64 KiB or 2 s; chunks seal at 5 MiB or 5 min.
- Paths are `chunks/<session_id>/<sensor_id>_<first_seq>.pb.gz`; UUIDs are lowercase.
- Identifier hash known answer: `b57a3b2f7dad4b8a`.
- Since the envelope has no platform field, `device.session start` carries additive `platform`, `model`, `os`, `app_version`, `sdk_version` and `activity_session_id` attributes.

**Storage:**
- JSON sidecars replace Android's database.
- Every file uses `completeUntilFirstUserAuthentication` and is excluded from backup.
- Startup recovers `.tmp` files and sweeps orphans.

**Android behaviour deliberately not copied** (`docs/ANDROID-DIFFERENCES.md` lists them all):
- Seal on a timer, not only on a write.
- Sort retention by wall time, because `firstTsMono` resets at reboot.
- Write eviction events through a persisted outbox, since Android's can be lost.
- Use POSIX number formatting.
- Write one `device.gap` per run of drops, not one per sample.
- Read ids from samples during recovery, not from filenames.
- Sweep orphans at startup.

## Sensors

| Android id | Phone | Watch | Notes |
|---|---|---|---|
| `motion.accelerometer` | raw accelerometer | same | `-9.80665 × a` to match Android's sign and m/s² |
| `motion.gyroscope` | device-motion rotation rate | same | rad/s; drift-compensated like Android's |
| `motion.magnetometer` | device-motion magnetic field | if available | µT; accuracy mapped |
| `motion.gravity`, `motion.linear_accel` | device motion | same | Converted to m/s², same sign rule |
| `motion.rotation_vector` | attitude | if frame offered | Rotated into Android's frame; x, y, z, w |
| `motion.step_counter` | `CMPedometer` | same | Cumulative **since recording start**, not boot |
| `env.barometer` | `CMAltimeter` | same | kPa × 10; **as delivered**, no set rate |
| `loc.fused` | `CLLocationManager` | same, default off | Ellipsoidal altitude; every 30 s |
| `loc.activity` | `CMMotionActivityManager` | same, default off | Mapped to Android's names; `confidence` added |
| `device.battery` | `UIDevice` | `WKInterfaceDevice`, polled | No temperature or voltage |
| `device.screen` | lock-state notifications | app active/inactive | **Approximate**; real screen wake isn't visible |
| `device.network` | `NWPathMonitor` | same | Same attributes |
| `device.audio_level` | `AVAudioEngine` tap | available, default off | Same dBFS math; buffers discarded in the tap; no audio file |
| `device.bluetooth_scan` | `CBCentralManager` | not in v1 | See default 4; names are hashed |

**Not emitted on iOS (no public API or no usable equivalent):** `motion.significant_motion`, `env.light`, `env.proximity`, `env.ambient_temp`, `env.humidity`, `loc.gnss`, `loc.gnss_status`, `loc.gnss_measurements`, `device.wifi_scan`, `virtual.environment`. No new sensor ids, and no `health.*`.

**Same as Android:** `device.session`, `device.clock`, `device.gap`, `device.health`, `device.storage_evicted`, `label.session`.

**Default rates:**

| Stream | Phone | Watch |
|---|---|---|
| Accelerometer, gyroscope, linear acceleration | 50 Hz | 25 Hz |
| Magnetometer | 20 Hz | 10 Hz |
| Rotation | 20 Hz | 10 Hz |
| Gravity | 10 Hz | 10 Hz |

All can be changed in the app, and 50 Hz on the watch gets tested.

## Phone and watch

- **Start:**
  - The phone saves the recording state and starts recording immediately; it never waits for the watch.
  - It then publishes the desired state with `updateApplicationContext` and calls `startWatchApp`, retrying once. On failure it records `peer_start_failed` and shows a banner.
  - The watch starts its workout session straight away and applies the settings.
- **Link loss:** the watch keeps recording, because nothing in its write path depends on the phone. It stops when the state arrives, or at the time limit (default 8 h). The watch's Stop button asks the phone to stop both devices; if the phone can't be reached, it stops locally.
- **Chunks:**
  - Sent with `transferFile`, with size and sha256 in the metadata, at most 4 at a time.
  - The phone verifies each file and acks; **the watch deletes only on an ack**.
  - After Stop, a summary lists every chunk, so the phone can show anything missing.
- **Clock pairing:** ping and reply at start, at stop, every 60 s and on reachability changes, writing `peer_clock` at the round-trip midpoint with `rtt_ns`. That improves on Android's one-way hello and keeps the same required fields.
- **Workout recovery:** `handleActiveWorkoutRecovery` recovers the session and starts a new engine session with a recorded `process_death` gap. No heart-rate read, and no silent failure (unlike `InrtlWatchCapture.swift:96-103`).

## iPhone keep-alive and how failures are recorded

Set up in the foreground at Start:
- `CLBackgroundActivitySession`
- `allowsBackgroundLocationUpdates`
- no automatic pausing
- 100 m accuracy

It runs even if `loc.fused` is off, with fixes discarded, so **the location indicator shows during every recording**.

| Failure | Recorded as |
|---|---|
| Force-quit, crash or jetsam | `device.gap process_death` and the session end, written by a short recovery session at next launch |
| Permission revoked | `device.health keepalive_lost`, then a session end |
| Suspended anyway | `device.gap process_stall` |
| A sensor goes silent | `device.gap delivery_gap` |
| Queue overflow | `device.gap buffer_ceiling` |
| Quota or disk full | Session end, reason `quota_reached` or `disk_full` |
| Low Power, thermal, mic interruption | `device.health`, or a `silenced` event |

**If location doesn't keep motion running (Phase 1 decides):**
- First fallback: a workout session on the iPhone itself, which raises the minimum to **iOS 26**.
- Second: a mirrored workout from the watch, which keeps iOS 17 but needs the watch.

I'd bring the result to you before choosing.

## Example app

**Phone:**
- **Record:** searchable picker over the 95 taxonomy ids, Start/Stop, elapsed time, live Hz per stream on both devices, warnings.
- **Permissions:** motion, location, mic, Bluetooth, Health.
- **Sensors:** phone and watch tabs, with toggles and rates.
- **Recordings:** duration, size, end reason, per-stream rate and gaps, missing watch chunks, Export, Delete.
- **Diagnostics:** an API probe, storage, plus debug actions in debug builds.

**Watch:** activity, elapsed time, Hz, link status, chunks pending, battery, Stop.

**Taxonomy:** a copy of `inrtl-lab/cloud/dashboard/internal/api/taxonomy.json`, with its source commit recorded. Read-only, and the SDK itself knows nothing about the taxonomy. Labels use the attributes from the lab app's `Activities.kt:39-52`.

**Export:** a store-only zip of chunks plus `manifest.json`, through the share sheet. Its internal paths match the ingest's landing layout.

**Decoder:** `swift run sensing-decode <zip> --out DIR --check` writes CSVs and prints the rate and gap table, using `ts_mono_ns` only and never arrival time.

**Project:**
- Bundle ids `com.rahulislam.sensing.example` and `.watchkitapp`; iPhone only.
- Team `3F2DL4L5F5`, same as the Companion.
- HealthKit entitlement, and a `PrivacyInfo.xcprivacy` file.
- Background modes: `location`, `audio`, `bluetooth-central`, `workout-processing`.

## Build order

Each phase lands as a PR after `scripts/check.sh` passes (`swift build`, `swift test`, lints, proto check). Actions don't run for this account, so the script is the gate.

| Phase | Delivers | Checked by |
|---|---|---|
| **P0** | Repo, package, proto, zlib compile, lints, plan docs | Builds and tests, including the watch target |
| **P1** | Diagnostics screen, bare locked recording on phone and watch | A0, rough A1 and A2. **I stop here and report**; this decides the adapter design and may need your call on iOS 26. |
| **P2** | Storage and `sensing-decode` | Android test vectors; `compat.sh` both ways |
| **P3** | Engine, config, activity sessions, outbox | Fake-adapter soak; killing a writer process and recovering |
| **P4** | Phone motion adapters, keep-alive, minimal app | A1, A3, A4, A11 (phone) |
| **P5** | Watch app, workout, link, transfer, clock pairing, recovery | A2, A8, A9, A10 |
| **P6** | Location, activity, device state, sound, Bluetooth | A11 (rest), A12, A13 |
| **P7** | Full example app, labels, export | A7, A14, A15 |
| **P8** | Soak, tuning, docs; KB repo table updated and that page republished (K-005) | A5, A6 |

## Verification

**`swift test` on macOS:** ports of the vectors in `FrameCodecTest`, `ChunkWriterRecoveryTest`, `RetentionTest`, `CollectionConfigTest`, `ActivitySessionsTest` and `DeviceAdaptersTest`. New tests cover the hash and CRC known answers, sign and quaternion conversions, the sleep offset, decimation, comma-locale formatting, killing a writer process, command ordering, the link protocol against a fake (duplicate, bad sha, lost ack), and an 8×100 Hz soak on a fake clock.

**Android compatibility (`scripts/compat.sh`):** compares decoded content, not bytes, since gzip output varies. It changes no committed code in the other repos.
- **Swift writes, JVM reads:** Android's real `FrameCodec.kt` and Wire, built from their source paths in a small Gradle tool. The first run needs network.
- **Swift writes, Go reads:** the ingest's real `frames.Decode`, `rowsFor` and `projectLabels`, through `go test -overlay`. `git status` must stay clean afterwards.
- **Android and Go write, Swift reads:** committed golden fixtures, which don't exist anywhere today.

**On devices** (rates from `ts_mono_ns`). The thresholds are proposals, and the battery figures especially are my estimates, so change any you like:

| # | Test | Pass |
|---|---|---|
| A0 | Diagnostics probe on both devices | Every unproven item answered and logged in DECISIONS |
| A1 | Phone locked in a pocket, 30 min, 50 Hz | Median interval 20 ±1 ms; ≥98% of expected samples; no unrecorded gap over 100 ms |
| A2 | Watch, wrist down, 30 min, 50 Hz | ≥47.5 Hz; max gap 250 ms. Below 45 Hz triggers trying `CMBatchedSensorManager`. |
| A3 | Phone 8 streams at 100 Hz; watch 8 at 50 Hz | 0 drops; under 15% and 10% of one core |
| A4 | Phone idle and locked, 1 h | Mono vs wall drift under 50 ms between clock events; no unrecorded jump |
| A5 | Both devices locked, 4 h | Both end by user stop; stalls under 1%; no motion gap over 5 s |
| A6 | Battery from ≥90% | Watch ≤12%/h at defaults; phone ≤12%/h with all sensors |
| A7 | Force-quit the phone mid-recording | Files recovered; loss ≤3 s; session end recorded; watch stops within 60 s of relaunch |
| A8 | Crash the watch | Recovered within 30 s; gap recorded |
| A9 | Link down 30 min | 0 watch gaps; all chunks delivered within 15 min of reconnecting |
| A10 | 1000+ chunks; kill the phone app mid-transfer | 0 sha failures; 0 duplicates; deletes only after ack |
| A11 | Side by side with an Android phone | Face-up z +9.81 ±0.2; barometer within 2 hPa; heading within 15°; 100 steps ±5; gyro sign correct |
| A12 | Sound | Loud at least 20 dB above quiet; no audio file on disk |
| A13 | Bluetooth | Names are 16 hex characters; no raw ids in any CSV |
| A14 | Debug quota 16 MiB | Example app stops cleanly at quota. With the SDK's delete-oldest option on, every eviction is recorded, even across a kill. |
| A15 | Real exports | JVM and Go decode 100% of frames; labels project with nothing skipped |

## What I need from you

- **Devices:** the iPhone 15 Pro and Series 9 unlocked and connected, with Developer Mode on, when a phase reaches them. Starting with P1.
- **Physical tests:** carrying or wearing them for the locked and soak runs, and an Android phone beside them for A11. I can install and read results, but I can't walk around.
- **Permission prompts:** approving them on the devices.
- **Signing:** Xcode signed in with team `3F2DL4L5F5`, so Automatic signing can create the new App IDs with HealthKit. No TestFlight in this work.

## Risks

| Risk | Mitigation |
|---|---|
| Location doesn't keep motion running when locked | Tested first in P1, before most code exists; two fallbacks |
| Watch can't sustain 50 Hz wrist-down | Batched manager, or Android's 25 Hz default |
| Watch battery | Measured in A6 before defaults are final; lower rates, or defer transfers until Stop |
| `transferFile` limits | Cap, ack, resend, summary list, A10 |
| Timestamps wrong around sleep | Offset tracker, A4 |
| Silent differences from Android, with no platform field | `platform` attribute, A11, the differences doc |
| Audio session disturbing other audio | Mix-with-others, default off, tested |

## Not in this step

- Upload, Firebase, sign-in, studies and remote config; the `inrtl-lab` repo isn't changed. Its open question Q16 (where the iOS code lives) and milestone M2 stay as they are until you connect them.
- An always-on recording mode, AirPods, heart rate or other health data, high-rate `CMBatchedSensorManager` (unless A2 needs it), App Store or TestFlight release.
- `sensing-sdk` isn't changed. The Android bugs found here are noted in `docs/ANDROID-DIFFERENCES.md` for you to decide on separately.
