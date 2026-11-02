#!/usr/bin/env python3
"""Report on Phase 1's probe runs: did sensors keep delivering while locked, at what rate, and at what cost?

  python3 tools/probe_report.py <run directory> [more runs...]
  python3 tools/probe_report.py exports/probe            # every run under a folder

Rates and gaps come only from each sample's own timestamp (CMLogItem.timestamp), never from arrival time: Wi-Fi
bunching once produced dozens of fake dropouts. Standard library only.
"""
import csv
import statistics
import sys
from pathlib import Path

GAP_MS = 100.0


def percentile(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))] if values else 0.0


def read_events(run):
    with open(run / "events.csv", newline="") as f:
        return list(csv.DictReader(f))


def read_rows(run):
    streams = {}
    with open(run / "rows.csv", newline="") as f:
        reader = csv.reader(f)
        next(reader, None)
        for row in reader:
            if len(row) < 7:
                continue  # a torn last line from a killed process
            try:
                streams.setdefault(row[0], []).append((float(row[2]), int(row[3])))
            except ValueError:
                continue
    return streams


def windows(events, start_kinds, end_kinds, stop_up):
    """[(from_uptime_s, to_uptime_s)] between a start event and the next end event, or the run's stop."""
    out, opened = [], None
    for e in events:
        up = int(e["uptime_ns"]) / 1e9
        if e["kind"] in start_kinds and opened is None:
            opened = up
        elif e["kind"] in end_kinds and opened is not None:
            out.append((opened, up))
            opened = None
    if opened is not None:
        out.append((opened, stop_up))
    return out


def battery(events):
    points = []
    for e in events:
        if "battery=" in e["detail"]:
            try:
                level = float(e["detail"].split("battery=")[1].split()[0])
            except ValueError:
                continue
            if level >= 0:
                points.append((int(e["wall_ms"]) / 3.6e6, level * 100))
    if len(points) < 2 or points[-1][0] <= points[0][0]:
        return None
    hours = points[-1][0] - points[0][0]
    return points[0][1], points[-1][1], hours, (points[0][1] - points[-1][1]) / hours


def stream_line(name, samples, hz, within=None):
    ts = [t for t, _ in samples if within is None or within[0] <= t <= within[1]]
    if len(ts) < 2:
        return f"  {name}: {len(ts)} samples"
    intervals = [(b - a) * 1000 for a, b in zip(ts, ts[1:])]
    dur = ts[-1] - ts[0]
    gaps = [i for i in intervals if i > GAP_MS]
    pct = f", {100 * len(ts) / (dur * hz):5.1f}% of {hz:g} Hz" if hz and name in "ag" else ""
    return (f"  {name}: {len(ts):7d} samples over {dur:7.1f} s, {len(ts) / dur:6.2f} Hz{pct}, "
            f"median {statistics.median(intervals):6.2f} ms, p95 {percentile(intervals, .95):6.2f}, "
            f"max gap {max(intervals):8.1f} ms, gaps>{GAP_MS:g}ms: {len(gaps)}")


def report(run):
    print(f"\n=== {run.name}")
    events = read_events(run)
    streams = read_rows(run)
    start = next((e for e in events if e["kind"] == "start"), None)
    hz = 0.0
    if start and "hz=" in start["detail"]:
        hz = float(start["detail"].split("hz=")[1].split()[0])
    stop = next((e for e in reversed(events) if e["kind"] == "stop"), None)
    last_up = int((stop or events[-1])["uptime_ns"]) / 1e9
    if not stop:
        print("  no stop event: the process died or was killed before Stop")
    wall = (int(events[-1]["wall_ms"]) - int(events[0]["wall_ms"])) / 1000
    print(f"  wall duration {wall:.1f} s, requested {hz:g} Hz")

    print("  whole run:")
    for name, samples in sorted(streams.items()):
        print("  " + stream_line(name, samples, hz))

    bg = windows(events, {"app_background"}, {"app_foreground"}, last_up)
    locked = windows(events, {"locked"}, {"unlocked"}, last_up)
    for title, spans in (("in the background", bg), ("locked", locked)):
        total = sum(b - a for a, b in spans)
        if not total:
            continue
        print(f"  {title}, {total:.1f} s in {len(spans)} span(s):")
        for name in ("a", "g"):
            if name not in streams:
                continue
            for a, b in spans:
                if b - a < 5:
                    continue
                inside = [t for t, _ in streams[name] if a <= t <= b]
                if not inside:
                    print(f"    {name}: NO samples in a {b - a:.1f} s span")
                    continue
                print("  " + stream_line(name, streams[name], hz, (a, b)))
                print(f"      last sample {b - inside[-1]:.1f} s before the span ended")

    # Q6: is CMLogItem.timestamp on the uptime clock? Then cb_uptime - ts is a small, positive delivery delay.
    if "a" in streams:
        delays = [up / 1e9 - t for t, up in streams["a"]]
        print(f"  clock: callback minus sample timestamp: median {statistics.median(delays) * 1000:.2f} ms, "
              f"min {min(delays) * 1000:.2f}, max {max(delays) * 1000:.2f}")
    offsets = [int(e["detail"].split("=")[1]) for e in events if e["kind"] == "clock"]
    if offsets:
        print(f"  clock: sleep offset grew by {(offsets[-1] - offsets[0]) / 1e9:.3f} s over the run")

    b = battery(events)
    if b:
        print(f"  battery: {b[0]:.0f}% to {b[1]:.0f}% over {b[2]:.2f} h, {b[3]:.1f} %/h")

    quiet = {"clock", "device"}
    print("  events:")
    shown = 0
    for e in events:
        if e["kind"] in quiet:
            continue
        shown += 1
        if shown > 40:
            print("    ...")
            break
        print(f"    {(int(e['wall_ms']) - int(events[0]['wall_ms'])) / 1000:8.1f} s  {e['kind']}  {e['detail']}")
    transfers = run / "transfers.txt"
    if transfers.exists():
        print("  transfers:")
        for line in transfers.read_text().splitlines():
            print(f"    {line}")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for arg in sys.argv[1:]:
        path = Path(arg)
        runs = [path] if (path / "rows.csv").exists() else sorted(p for p in path.iterdir() if (p / "rows.csv").exists())
        for run in runs:
            report(run)


if __name__ == "__main__":
    main()
