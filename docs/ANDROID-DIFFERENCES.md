# Differences from the Android SDK

What a data consumer has to know when iOS and Android data sit side by side. The format is the same; these are the places where the meaning or the coverage differs. Android's source is `sensing-sdk` @183d765.

_Status: started 2026-11-02; each phase adds what it finds._

## Coverage

**Not emitted on iOS (no public API or no usable equivalent):** `motion.significant_motion`, `env.light`, `env.proximity`, `env.ambient_temp`, `env.humidity`, `loc.gnss`, `loc.gnss_status`, `loc.gnss_measurements`, `device.wifi_scan`, `virtual.environment`.

## Meaning

| Stream | Android | iOS |
|---|---|---|
| Recording | Always on | Start to Stop (S-002) |
| `env.barometer` | Set rate (5 Hz, 1 Hz) | As delivered: measured 0.94 Hz on an iPhone 15 Pro and 0.39 Hz on a Series 9 |
| `motion.step_counter` | Cumulative since boot | Cumulative since recording start |
| `loc.fused` | One of two location streams | The only one; CoreLocation exposes no raw GPS fix |
| `device.screen` | Real screen on and off | Approximate: lock state on the phone, app active state on the watch |
| `device.bluetooth_scan` | All devices, by MAC address | All devices when open, a fixed list of services when locked; by a per-device UUID |
| `label.session` `end_reason` | `stopped`, `time_limit`, `discarded`: a session outlives its process | Adds `process_died`, since a phone crash ends the recording (S-011). The ingest reads an unknown reason as `stopped` (`labels.go:104-107`), so it's safe today but loses the reason until the ingest learns it |
| `device.session end` `reason` | Android's reasons | Adds `user_stop`, `watch_stop`, `phone_stop`, `superseded`, `keepalive_lost`, `recovery_done`, and on start `workout_recovery` |
| `device.health heartbeat` | Its own attributes | Additive `cpu_ms`, `uptime_ms`, `battery_pct`, `is_charging`, `low_power`, `thermal_state`, which is how A3 and A6 measure cost |

## Android behaviour deliberately not copied

These look like bugs or weak spots in the Android SDK. They're noted here for a separate decision about Android.

| Android | iOS | Why |
|---|---|---|
| A chunk seals only on a write (`ChunkWriter.kt:57`), so a quiet sensor stays open until the session ends | A timer | Quiet streams would otherwise never reach 5 min |
| A crash between rename and metadata write orphans a `.pb.gz` (`ChunkWriter.kt:77-86`) | A startup sweep rebuilds it | The file would never upload |
| Recovery parses ids from the filename (`ChunkRecovery.kt:41`) | Reads them from the samples | It's what Android's AGENTS.md says it does |
| Oldest-first sorts on `firstTsMono`, which resets at reboot (`ChunkDatabase.kt:43`) | Wall time | New chunks could evict first |
| Eviction events can be lost when the engine is stopped (`Retention.kt:50`) | A persisted outbox | "Never silent" |
| `"%.1f".format` uses the default locale (`BatteryAdapter.kt:65`) | POSIX formatting | Comma-decimal locales change attribute values |
| One `device.gap` per dropped sample | One per run of drops | A burst would add more load at the worst moment |
| A Room database of chunk rows; `ACKED` and `EVICTED` rows are never pruned | A JSON record beside each chunk, with state from the file system | No rows to go stale |
| Deleting the oldest can take label chunks and the eviction records themselves | Bookkeeping and label streams are never evicted | They're tiny, and losing a recording's labels costs far more than they free |
| Quota always deletes the oldest | Stops the recording at the quota by default; deleting is an option (S-007) | The device may hold the only copy |
| `peer_clock` is one-way (`PhoneRelayReceiver.kt:81-87`) | The round-trip midpoint, with `rtt_ns` | Removes the transit bias; required fields are unchanged |
