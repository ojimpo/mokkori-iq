"""Segment a swim capture into swim bouts and rests, and find 3-tap markers.

Addresses two practical questions about a real pool capture:
  1) Where are the interval boundaries? The swimmer taps the device 3x at the
     wall to mark them, but taps done underwater / mid-stroke get buried.
  2) Which intervals are actually ~100m vs shorter? -> swim-bout durations.

Approach (all causal-friendly, but here we just analyse offline):
  - activity = trailing rolling std of |acc| (same idea as the detector).
  - swim vs rest by hysteresis threshold on the activity envelope.
  - tap candidates = sharp |acc| jerk impulses found *in rest windows* (taps at
    the wall while still). Cluster impulses spaced <~1.5s into groups; a group
    of ~3 is a marker.

Usage:
    python analysis/segment_swim.py data/swim/swim_YYYYMMDD_HHMMSS.csv
"""
import argparse
import os
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "src"))
import dataio  # noqa: E402


def rolling_std(x, w):
    """Trailing rolling std, window w samples (O(N) via cumsum)."""
    n = len(x)
    c1 = np.concatenate([[0.0], np.cumsum(x)])
    c2 = np.concatenate([[0.0], np.cumsum(x * x)])
    out = np.zeros(n)
    for i in range(n):
        a = max(0, i - w + 1)
        cnt = i + 1 - a
        s = c1[i + 1] - c1[a]
        ss = c2[i + 1] - c2[a]
        var = max(0.0, ss / cnt - (s / cnt) ** 2)
        out[i] = var ** 0.5
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--out", default=None)
    ap.add_argument("--act-win", type=float, default=2.0,
                    help="activity window (s)")
    ap.add_argument("--rest-min", type=float, default=3.0,
                    help="min rest duration to count as a real rest (s)")
    args = ap.parse_args()

    sess = dataio.load_swim_csv(args.csv)
    fs = sess["fs"]
    t = sess["t"]
    acc_n = sess["acc_norm"]
    gyro_n = sess["gyro_norm"]
    dur = float(t[-1] - t[0])

    # --- activity envelope ---
    w = max(1, int(round(args.act_win * fs)))
    act = rolling_std(acc_n, w)

    # hysteresis thresholds from the activity distribution
    hi = float(np.percentile(act, 60))   # clearly swimming
    lo = float(np.percentile(act, 25))   # clearly resting
    swim = np.zeros(len(act), dtype=bool)
    state = False
    for i, a in enumerate(act):
        if not state and a > hi:
            state = True
        elif state and a < lo:
            state = False
        swim[i] = state

    # --- swim bouts (contiguous swim runs) and rests ---
    def runs(mask):
        out = []
        i = 0
        n = len(mask)
        while i < n:
            if mask[i]:
                j = i
                while j < n and mask[j]:
                    j += 1
                out.append((i, j - 1))
                i = j
            else:
                i += 1
        return out

    bouts = runs(swim)
    # merge tiny gaps between bouts (< rest-min) -> treat as same bout
    merged = []
    for b in bouts:
        if merged and (t[b[0]] - t[merged[-1][1]]) < args.rest_min:
            merged[-1] = (merged[-1][0], b[1])
        else:
            merged.append(list(b))
    # drop trivially short bouts (<5s) as noise
    bouts = [b for b in merged if (t[b[1]] - t[b[0]]) >= 5.0]

    # --- tap candidates: |acc| jerk impulses in low-activity windows ---
    jerk = np.abs(np.diff(acc_n, prepend=acc_n[0])) * fs   # m/s^3-ish
    # only consider impulses where we're NOT vigorously swimming
    rest_mask = act < float(np.percentile(act, 40))
    jthr = float(np.percentile(jerk, 99.0))
    peaks = []
    last = -1e9
    for i in range(len(jerk)):
        if jerk[i] > jthr and rest_mask[i] and (t[i] - last) > 0.20:
            peaks.append(i)
            last = t[i]
    # cluster peaks into groups (gap < 1.5s)
    groups = []
    for p in peaks:
        if groups and (t[p] - t[groups[-1][-1]]) < 1.5:
            groups[-1].append(p)
        else:
            groups.append([p])
    triple_markers = [g for g in groups if 2 <= len(g) <= 5]

    # --- report ---
    print(f"file: {args.csv}")
    print(f"duration: {dur:.1f}s ({dur/60:.1f} min)  fs: {fs:.1f}Hz")
    print(f"\n=== swim bouts (activity-segmented) -> {len(bouts)} ===")
    print(f"{'#':>2} {'start':>8} {'end':>8} {'dur':>7} {'rest_after':>10}")
    for k, b in enumerate(bouts):
        ts, te = t[b[0]], t[b[1]]
        rest_after = (t[bouts[k + 1][0]] - te) if k + 1 < len(bouts) else 0.0
        print(f"{k+1:>2} {ts:>8.1f} {te:>8.1f} {te-ts:>6.1f}s {rest_after:>9.1f}s")
    durs = np.array([t[b[1]] - t[b[0]] for b in bouts])
    if len(durs):
        print(f"\nbout dur: median {np.median(durs):.1f}s  "
              f"min {durs.min():.1f}s  max {durs.max():.1f}s")

    print(f"\n=== tap-marker clusters (rest impulses) -> {len(triple_markers)} ===")
    for g in triple_markers:
        print(f"  t={t[g[0]]:>8.1f}s  n={len(g)}  span={t[g[-1]]-t[g[0]]:.2f}s")

    # --- plot ---
    out = args.out or os.path.join(
        HERE, "fig_segment_" + os.path.splitext(os.path.basename(args.csv))[0] + ".png")
    fig, ax = plt.subplots(2, 1, figsize=(16, 7), sharex=True)
    ax[0].plot(t, act, lw=0.5, color="steelblue")
    ax[0].axhline(hi, color="orange", lw=0.8, ls="--", label=f"hi={hi:.2f}")
    ax[0].axhline(lo, color="green", lw=0.8, ls="--", label=f"lo={lo:.2f}")
    for b in bouts:
        ax[0].axvspan(t[b[0]], t[b[1]], color="steelblue", alpha=0.12)
    ax[0].set_ylabel("activity (std|acc|)")
    ax[0].legend(loc="upper right", fontsize=8)
    ax[0].set_title(os.path.basename(args.csv) +
                    f"  {len(bouts)} bouts, {len(triple_markers)} tap-markers")
    ax[1].plot(t, jerk, lw=0.4, color="gray")
    ax[1].axhline(jthr, color="red", lw=0.8, ls="--", label=f"jthr={jthr:.1f}")
    for g in triple_markers:
        ax[1].axvline(t[g[0]], color="red", lw=1.0, alpha=0.7)
    ax[1].set_ylabel("|acc| jerk")
    ax[1].set_xlabel("time (s)")
    ax[1].legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=110)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
