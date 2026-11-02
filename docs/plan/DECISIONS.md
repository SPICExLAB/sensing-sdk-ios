# Decision log

Newest entries go at the bottom. Don't edit past entries; add a new one that supersedes them, e.g. "Supersedes S-007". Cite other logs as "Android AGENTS.md", "lab L-097" and "platform D-051".

| ID | Date | Decision | Why / notes |
|---|---|---|---|
| S-001 | 2026-11-02 | **A new Swift SDK for iPhone and Apple Watch and an example app, not connected to inrtl Lab.** No Firebase, sign-in, upload, studies or remote config | Product owner: "i dont want to integrate it to inrtl lab yet.. i just need a example app on the sdk" |
| S-002 | 2026-11-02 | **Recording runs from Start to Stop, with the screen locked.** The iPhone stays alive through the location background mode; the watch through a workout session. Force-quit ends it, and gaps are recorded. Always-on can come later | Product owner. iOS can't match Android's always-on recording: the watch's passive path is accelerometer only, and iOS doesn't relaunch a force-quit app |
| S-003 | 2026-11-02 | **Sensors: motion core, location and activity, device state, sound level and Bluetooth** | Product owner. Ids with no public iOS API aren't emitted (PLAN.md, "Sensors") |
| S-004 | 2026-11-02 | **The example app has activity labels** from a bundled copy of the taxonomy, in Android's `label.session` stream | Product owner: recordings can be used for training right away |
| S-005 | 2026-11-02 | **A new repo, `project-ursula/sensing-sdk-ios`** (private), holding a copy of Android's proto that `scripts/check.sh` compares against a pinned commit | Product owner. Apps add it as an ordinary package, and the Android repo the lab builds from stays untouched |
| S-006 | 2026-11-02 | **Same data format as Android:** proto, chunk framing, sensor ids and units, converted on the device. An upload protocol exists with no cloud implementation | Plan default. Connecting it later needs no conversion |
| S-007 | 2026-11-02 | **Full storage stops a recording; it never deletes, in the example app.** Android's delete-oldest is an SDK option, off in the app. It warns at 80% | Plan default. The device may hold the only copy until someone exports it |
| S-008 | 2026-11-02 | **Sound and Bluetooth default to off** | Plan default. Android has them on, but here they add a mic indicator and change device behaviour |
| S-009 | 2026-11-02 | **Bluetooth scans everything when the app is open and a fixed list of service types when locked, with a `scan_mode` event; phone only in v1** | Plan default. `CBCentralManager.h` requires background scans to name service types |
| S-010 | 2026-11-02 | **Start is on the phone only; the watch can Stop** | Plan default. A watch can't start the phone's location keep-alive from the background, and labels live on the phone |
| S-011 | 2026-11-02 | **A phone crash ends the recording; no auto-resume.** Next launch recovers the files and records the gap | Plan default |
| S-012 | 2026-11-02 | **Plain SwiftUI in the example app, with no Claude Design step** | Plan default. A developer example, not a platform screen |
| S-013 | 2026-11-02 | **`Int` isn't used for nanoseconds, seq or byte totals; `scripts/check.sh` flags `Int(` in Core and Storage.** The watch's `arm64_32` makes `Int` 32 bits | macOS tests can't catch an overflow there |
