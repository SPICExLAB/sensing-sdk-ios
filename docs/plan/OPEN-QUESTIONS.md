# Open questions and risks

Close an item by recording the outcome in [DECISIONS.md](DECISIONS.md) and marking it ☑ here.

**Status key:** ☐ open · ◐ in progress · ☑ resolved

| # | Status | Question / risk | Why it matters | Owner | Resolve by |
|---|---|---|---|---|---|
| Q1 | ☐ | Does the location background mode keep motion data flowing on a locked iPhone, with the mic off? Nothing local proves it | The whole iPhone recording model rests on it. Fallbacks: a workout session on the iPhone (raises the minimum to iOS 26), or a mirrored workout from the watch | Team, with product owner's devices | P1 |
| Q2 | ☐ | Does a Series 9 sustain 50 Hz wrist-down in a workout session? Nothing local documents more than about 25 Hz | Sets the watch's usable rate. Fallback: `CMBatchedSensorManager`, or Android's 25 Hz default | Team | P1 |
| Q3 | ☐ | Does the Series 9 report a magnetometer and a magnetic-north attitude frame? | Decides `motion.magnetometer` and `motion.rotation_vector` on the watch | Team | P1 |
| Q4 | ☐ | What's the minimum HealthKit permission for a workout session? Plan: workout share only, no heart rate. Does it need any? | Avoids asking for more than needed | Team | P1 |
| Q5 | ☐ | What are `transferFile`'s real limits? None are documented | Sets the cap and resend timing. Plan: at most 4 outstanding | Team | P1, then A10 |
| Q6 | ☐ | Does `CMLogItem.timestamp` track `CLOCK_UPTIME_RAW`, and does `CLOCK_MONOTONIC_RAW − CLOCK_UPTIME_RAW` grow only during sleep? | The conversion to Android's `elapsedRealtimeNanos` rests on it | Team | P1, then A4 |
| Q7 | ☐ | Which plist key enables background location on the watch, and does the watch need it during a workout? | Decides watch `loc.fused` | Team | P6 |
| Q8 | ☐ | Are the battery targets in A6 (≤12%/h on each device) right? | They're estimates | Product owner | P8 |
| Q9 | ☐ | Is the 2 s `fsync` plus `F_FULLFSYNC` at seal enough? A process kill loses nothing written, but sudden power loss could lose up to one seal interval | Android's `fd.sync()` differs. Flushing 8 files to media every 2 s would cost battery | Team | P2 |
