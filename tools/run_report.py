#!/usr/bin/env python3
"""Judge a real recording against the device tests (A1, A3, A4), from `sensing-decode --out` CSVs.

  swift run sensing-decode exports/recordings --out exports/csv
  python3 tools/run_report.py exports/csv [--hz 50]

Timing comes from ts_mono_ns only, never from arrival time. Prints one block per engine session. Exports are
participants' data, so this reads them and writes nothing.
"""

import argparse
import csv
import json
from pathlib import Path
from statistics import median

GAP_MS = 100
CLOCK_DRIFT_MS = 50


def rows(path):
    return list(csv.DictReader(path.open())) if path.exists() else []


def events(folder, sensor, kind=None):
    out = []
    for r in rows(folder / f"{sensor}.csv"):
        if kind is None or r.get("event_kind") == kind:
            out.append((int(r["ts_mono_ns"]), r.get("event_kind"), json.loads(r.get("event_attributes") or "{}")))
    return sorted(out, key=lambda e: e[0])


def report(folder, want_hz):
    start = events(folder, "device.session", "start")
    if not start:
        return
    attrs = start[0][2]
    if attrs.get("reason") == "recovery":
        print(f"\n{folder.name}: a recovery session, no motion to judge")
        return
    print(f"\n{folder.name}: {attrs.get('model')} {attrs.get('os')}")
    end = events(folder, "device.session", "end")
    print(f"  ended: {end[-1][2].get('reason') if end else 'NO END RECORDED'}")

    # A1: the accelerometer, the stream with its own subscription.
    accel = [int(r["ts_mono_ns"]) for r in rows(folder / "motion.accelerometer.csv")]
    if len(accel) > 1:
        accel.sort()
        steps = [(b - a) / 1e6 for a, b in zip(accel, accel[1:])]
        seconds = (accel[-1] - accel[0]) / 1e9
        hz = (len(accel) - 1) / seconds
        big = [s for s in steps if s > GAP_MS]
        print(f"  accelerometer: {seconds:.0f} s, {hz:.2f} Hz, median {median(steps):.2f} ms, max gap {max(steps):.1f} ms, {len(big)} gaps over {GAP_MS} ms")
        if want_hz:
            print(f"    A1: {100 * hz / want_hz:.1f}% of {want_hz} Hz; pass needs >=98%, median within 1 ms of {1000 / want_hz:.1f} ms, and every big gap recorded")

    gaps = events(folder, "device.gap")
    print(f"  recorded gaps: {len(gaps)}" + "".join(f"\n    {e[1]} {e[2]}" for e in gaps[:12]))

    # A3: drops and the cost, from the heartbeats.
    beats = events(folder, "device.health", "heartbeat")
    if len(beats) >= 2:
        first, last = beats[0][2], beats[-1][2]
        uptime = int(last.get("uptime_ms", 0)) - int(first.get("uptime_ms", 0))
        cpu = int(last.get("cpu_ms", 0)) - int(first.get("cpu_ms", 0))
        pending = max(int(b[2].get("pending_persist", 0)) for b in beats)
        print(f"  A3: {last.get('dropped')} dropped, {100 * cpu / max(uptime, 1):.1f}% of one core, largest backlog {pending} samples, {len(beats)} heartbeats")
        print(f"  battery: {first.get('battery_pct')}% to {last.get('battery_pct')}%, charging at the end: {last.get('is_charging')}, thermal {first.get('thermal_state')} to {last.get('thermal_state')}, low power {last.get('low_power')}")

    # A4: the wall clock against the monotonic clock, between clock events.
    clocks = events(folder, "device.clock")
    drifts = []
    for (_, _, a), (_, _, b) in zip(clocks, clocks[1:]):
        mono_ms = (int(b["mono_ns"]) - int(a["mono_ns"])) / 1e6
        wall_ms = int(b["wall_ms"]) - int(a["wall_ms"])
        drifts.append(wall_ms - mono_ms)
    if drifts:
        worst = max(abs(d) for d in drifts)
        print(f"  A4: {len(clocks)} clock events, worst drift between two {worst:.1f} ms (pass under {CLOCK_DRIFT_MS} ms), per interval {[round(d, 1) for d in drifts]}")
    else:
        print(f"  A4: {len(clocks)} clock event(s), too few to compare")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("csv_dir", type=Path)
    p.add_argument("--hz", type=float, default=0, help="the accelerometer rate that was asked for")
    a = p.parse_args()
    for device in sorted(d for d in a.csv_dir.iterdir() if d.is_dir()):
        for session in sorted(s for s in device.iterdir() if s.is_dir()):
            report(session, a.hz)


if __name__ == "__main__":
    main()
