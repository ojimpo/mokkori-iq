"""One-shot swim report: ingest a flash-logger CSV -> distance, pace, per-rep
breakdown, stroke rate, and a Strava-ready summary. Conservative by policy.

This is the "device output": point it at a pulled session and it prints
everything you'd log. Detection reuses the gz body-axis wall detector
(turn_stand.detect_walls) and the gyro-roll cadence (stroke_rate).

Conservative-bias policy (see CLAUDE.md): distance may read low, never high;
pace may read slow, never fast. Implemented per rep as

    lengths = min(wall_count, round(swim_time / typical_length_time))

- wall_count over-reads on false splits (two walls too close); the pace term
  caps it.
- a missed wall makes wall_count read low; min() keeps that low value -> an
  under-count, which is the allowed direction.
- clean reps agree on both terms, so they stay exact (a verified 100 m stays
  100 m -- plain floor would wrongly shave it).
Distance is therefore biased low; pace = moving_time / distance is biased slow.

Usage:
    python analysis/swim_report.py data/swim/swim_YYYYMMDD_HHMMSS.csv
    python analysis/swim_report.py <csv> --pool 25 --date 2026-06-21
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "src"))
sys.path.insert(0, HERE)
import dataio  # noqa: E402
from turn_stand import detect_walls  # noqa: E402
from stroke_rate import dominant_cadence  # noqa: E402
from turn_stand import ema  # noqa: E402


def fmt(s):
    s = max(0.0, float(s))
    m = int(s // 60)
    return f"{m}:{s - 60 * m:04.1f}" if s >= 60 else f"{s:.1f}s"


def typical_length_time(t, prone, dt, turns, lo=15.0, hi=45.0):
    """Median *swimming* time per length: prone time in each turn-to-turn gap
    (push-off .end -> next .start, so standing time is excluded -- matching the
    prone swim_time used as the numerator in the pace estimate)."""
    ts = sorted(turns)
    gaps = []
    for (a0, a1), (b0, b1) in zip(ts, ts[1:]):
        m = (t >= a1) & (t <= b0)
        st = float(dt[m & prone].sum())
        if lo <= st <= hi:
            gaps.append(st)
    return float(np.median(gaps)) if gaps else 31.0


def swim_segments(bs, be, rests):
    """Swim spans inside [bs,be] split out by the bench rests (rests bound reps)."""
    pts = [bs]
    for a, b in sorted(r for r in rests if bs <= r[0] <= be):
        pts += [a, b]
    pts += [be]
    return [(pts[i], pts[i + 1]) for i in range(0, len(pts) - 1, 2)]


def median_cadence(sess, swim_gz=-2.0, win=8.0, hop=2.0, band=(0.3, 1.2)):
    t, gyro, fs = sess["t"], sess["gyro"], sess["fs"]
    gzg = ema(sess["acc"][:, 2], fs, 1.0)
    w, hp = int(win * fs), int(hop * fs)
    cyc = []
    for i in range(0, len(t) - w, hp):
        if gzg[i:i + w].mean() > swim_gz:
            continue
        best_f, best_p = None, -1.0
        for ax in range(3):
            f, p = dominant_cadence(gyro[i:i + w, ax], fs, band)
            if f is not None and p > best_p:
                best_f, best_p = f, p
        if best_f is not None:
            cyc.append(best_f * 60.0)
    return float(np.median(cyc)) if cyc else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--pool", type=float, default=25.0)
    ap.add_argument("--date", default=None, help="label for the report header")
    ap.add_argument("--verbose", action="store_true",
                    help="print per-rep wall-count vs pace estimate")
    args = ap.parse_args()

    sess = dataio.load_swim_csv(args.csv)
    t, fs = sess["t"], sess["fs"]
    dt = np.diff(t, prepend=t[0])

    d = detect_walls(sess)
    gz = d["gz"]
    prone = gz < -2.0                       # actually swimming (face-down)
    Lt = typical_length_time(t, prone, dt, d["turns"])
    pool = args.pool

    halves = list(zip(d["starts"], d["ends"]))
    total_len = 0
    total_swim = 0.0
    half_rows = []
    rep_lines = []
    for hi, (bs, be) in enumerate(halves):
        hl, hs = 0, 0.0
        for ri, (s0, s1) in enumerate(swim_segments(bs, be, d["rests"])):
            m = (t >= s0) & (t <= s1)
            st = float(dt[m & prone].sum())
            if st < 8.0:                     # warmup / getting in / bobbing
                continue
            wall_len = sum(1 for a, _ in d["turns"] if s0 <= a <= s1) + 1
            pace_len = int(round(st / Lt))
            n = max(1, min(wall_len, pace_len))   # <-- conservative rule
            hl += n
            hs += st
            rep_lines.append(
                f"   半{hi+1} レップ{ri+1}: 泳ぎ {fmt(st):>6}  "
                f"-> {n}本 ({n*int(pool)}m)"
                + (f"   [壁{wall_len}/ペース{pace_len} -> min]" if args.verbose else ""))
        if hl:
            pace = hs / (hl * pool) * 100
            half_rows.append((hi + 1, hl * pool, hs, pace))
            total_len += hl
            total_swim += hs

    dist = total_len * pool
    cad = median_cadence(sess)
    elapsed = float(t[-1] - t[0])
    avg_pace = total_swim / dist * 100 if dist else 0.0

    print(f"=== swim report: {os.path.basename(args.csv)} ===")
    print(f"typical length time: {Lt:.1f}s/{int(pool)}m  (pool {int(pool)}m, "
          f"fs {fs:.1f}Hz, conservative)")
    print("\n".join(rep_lines))
    print("\n  half      dist   moving   pace/100m")
    for h, hd, hsw, hp in half_rows:
        print(f"   {h:>2}   {int(hd):>5}m  {fmt(hsw):>6}   {fmt(hp)}")

    print("\n" + "-" * 42)
    hdr = f"\U0001F4C5 {args.date}  " if args.date else ""
    print(f"{hdr}プールスイム（自由形・{int(pool)}mプール）")
    print(f"  距離        {int(dist):>5} m   （控えめ。実際はこれ以上）")
    print(f"  ペース       約{fmt(avg_pace)} /100m   （遅め寄りの安全値）")
    print(f"  泳ぎ時間     {fmt(total_swim)}（moving time）")
    print(f"  総経過時間   {fmt(elapsed)}（休憩込み）")
    if cad:
        print(f"  ストローク率  約{cad:.0f} cyc/min（≒{cad*2:.0f} strokes/min）")
    if d["triples"]:
        print(f"  タップ境界   {len(d['triples'])}個復元 "
              + "(" + ", ".join(f"{a:.0f}s" for a, _ in d["triples"]) + ")")


if __name__ == "__main__":
    main()
