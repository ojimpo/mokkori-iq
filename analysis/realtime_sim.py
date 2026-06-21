"""Causal (online) lap-counter + haptic-buzz simulation.

Feasibility probe for real-time per-100 m vibration feedback while swimming.
The vibration motor hasn't arrived yet; this lets us test the exact on-device
logic against a *recorded* session, before any hardware.

Why this maps cleanly to an MCU:
  - gz is a causal EMA of acc_z (O(1) memory, no look-ahead).
  - thresholds are ABSOLUTE gravity levels (vertical ~ +9.8, prone ~ -g_fwd),
    not session percentiles -> no whole-session calibration, runs from sample 1.
  - the whole thing is a ~20-line state machine.

Logic: detect each wall as a confirmed standing event (open turn = plant feet,
torso vertical -> gz peak > GZ_VERT), with a refractory floor of one length-time.
Count walls; every LAPBUZZ-th wall is a 100 m mark -> buzz. The buzz fires the
instant vertical is confirmed, i.e. while the swimmer is standing at the wall.

NOTE: this is open-loop counting with no look-ahead, so it cannot apply the
offline pace/min() correction -- a rare missed/false wall permanently shifts
every later buzz. Use to measure that drift, not to claim exactness.

Usage:
    python analysis/realtime_sim.py data/swim/swim_YYYYMMDD_HHMMSS.csv
    python analysis/realtime_sim.py <csv> --pool 25 --lapbuzz 4
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "src"))
import dataio  # noqa: E402


def simulate(t, acc, fs, pool=25.0, lapbuzz=4,
             gz_stand=2.0, gz_vert=5.0, gz_swim=-2.0, refrac=12.0, tau=1.0):
    alpha = 1.0 - np.exp(-1.0 / (tau * fs))
    gz = 0.0
    state = "SWIM"
    peak = -99.0
    last_wall = -1e9
    swam_since_wall = False
    walls = 0
    wall_times = []
    buzzes = []
    for i in range(len(t)):
        gz += alpha * (acc[i, 2] - gz)            # causal gravity on body axis
        if gz < gz_swim:
            swam_since_wall = True
            state = "SWIM"
        if state == "SWIM" and gz > gz_stand:
            state, peak = "RISE", gz
        elif state == "RISE":
            peak = max(peak, gz)
            if gz < gz_stand:                     # never reached vertical -> bob
                state = "SWIM"
            elif peak > gz_vert and (t[i] - last_wall) > refrac and swam_since_wall:
                walls += 1
                last_wall = t[i]
                swam_since_wall = False
                state = "STAND"
                wall_times.append(t[i])
                if walls % lapbuzz == 0:
                    buzzes.append((t[i], walls, walls * pool))
        elif state == "STAND":
            if gz < gz_swim:
                state = "SWIM"
    return walls, wall_times, buzzes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--pool", type=float, default=25.0)
    ap.add_argument("--lapbuzz", type=int, default=4,
                    help="buzz every N walls (25m pool * 4 = 100m)")
    args = ap.parse_args()

    sess = dataio.load_swim_csv(args.csv)
    t, acc, fs = sess["t"], sess["acc"], sess["fs"]
    walls, wt, buzzes = simulate(t, acc, fs, args.pool, args.lapbuzz)

    print(f"file: {os.path.basename(args.csv)}  (causal / online sim)")
    print(f"causal wall count: {walls}  (~{walls*args.pool:.0f}m at {int(args.pool)}m/length)")
    print(f"buzzes (every {args.lapbuzz} walls = {int(args.lapbuzz*args.pool)}m): {len(buzzes)}")
    print(f"\n{'#':>2} {'t':>7} {'walls':>5} {'dist':>6}  gap")
    prev = 0.0
    for k, (tt, w, dd) in enumerate(buzzes):
        print(f"{k+1:>2} {tt:>6.0f}s {w:>5} {int(dd):>5}m  {tt-prev:>4.0f}s")
        prev = tt
    print("\n[!] open-loop: count drift accumulates (no look-ahead correction).")


if __name__ == "__main__":
    main()
