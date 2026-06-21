"""Stroke-rate (cadence / SPM) tracker for crotch-mounted swim captures.

The hips/crotch carry a clean rhythmic signal: the body rolls left-right once
per stroke cycle (left arm + right arm), strongest on the gyro roll axes. In a
clean freestyle length the dominant gyro frequency is the stroke-CYCLE rate; arm
strokes = 2x that. (On this session a clean length read 0.479 Hz = 29 cycle/min
= ~58 arm strokes/min, consistent across gx/gy/gz; |acc|/|gyro| show 2x/4x
rectification harmonics, so we key on a single signed gyro axis, not the norm.)

Method: slide an 8 s window; in each window pick the gyro axis with the strongest
spectral peak in the stroke band (0.3-1.2 Hz) and call that the cycle rate. Only
report where the swimmer is prone (gz gravity < swim level) -- i.e. actually
swimming, not standing/resting. Optionally segment per length/rep via the same
gz walls as turn_stand.py.

Usage:
    python analysis/stroke_rate.py data/swim/swim_YYYYMMDD_HHMMSS.csv
    python analysis/stroke_rate.py <csv> --win 8 --band 0.3 1.2
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
from turn_stand import ema, episodes  # noqa: E402  (reuse gz helpers)


def dominant_cadence(seg, fs, band):
    """Return (freq_hz, power) of the strongest spectral peak in band."""
    n = len(seg)
    if n < int(2 / band[0] * fs):      # need a couple of cycles
        return None, 0.0
    x = (seg - seg.mean()) * np.hanning(n)
    f = np.fft.rfftfreq(n, 1.0 / fs)
    P = np.abs(np.fft.rfft(x)) ** 2
    sel = (f >= band[0]) & (f <= band[1])
    if not sel.any():
        return None, 0.0
    k = np.argmax(P[sel])
    return float(f[sel][k]), float(P[sel][k])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--win", type=float, default=8.0, help="window (s)")
    ap.add_argument("--hop", type=float, default=2.0, help="hop (s)")
    ap.add_argument("--band", type=float, nargs=2, default=[0.3, 1.2],
                    help="stroke-cycle band (Hz)")
    ap.add_argument("--swim-gz", type=float, default=-2.0,
                    help="report cadence only where gz gravity < this (prone)")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    sess = dataio.load_swim_csv(args.csv)
    t, gyro, fs = sess["t"], sess["gyro"], sess["fs"]
    gzg = ema(sess["acc"][:, 2], fs, 1.0)        # gravity on body axis

    w = int(args.win * fs)
    hop = int(args.hop * fs)
    ct, cyc = [], []
    for i in range(0, len(t) - w, hop):
        if gzg[i:i + w].mean() > args.swim_gz:   # not prone -> skip
            continue
        best_f, best_p = None, -1.0
        for ax in range(3):                      # pick cleanest gyro axis
            f, p = dominant_cadence(gyro[i:i + w, ax], fs, tuple(args.band))
            if f is not None and p > best_p:
                best_f, best_p = f, p
        if best_f is not None:
            ct.append(t[i + w // 2])
            cyc.append(best_f * 60.0)            # cycles per minute
    ct, cyc = np.array(ct), np.array(cyc)

    print(f"file: {args.csv}")
    if len(cyc) == 0:
        print("no swimming windows found")
        return
    print(f"stroke-cycle rate over {len(cyc)} swimming windows "
          f"({args.win:.0f}s win):")
    print(f"  median {np.median(cyc):.0f} cyc/min  "
          f"(IQR {np.percentile(cyc,25):.0f}-{np.percentile(cyc,75):.0f})")
    print(f"  -> arm strokes ~{np.median(cyc)*2:.0f} /min")

    # per-block (split at gz big-rests >90s)
    bigs = [e for e in episodes(gzg > 2.0, t, gzg, 0.8) if e[1] - e[0] >= 90.0]
    starts = [t[0]] + [b for _, b, _ in bigs]
    ends = [a for a, _, _ in bigs] + [t[-1]]
    print("  per half:")
    for k, (bs, be) in enumerate(zip(starts, ends)):
        m = (ct >= bs) & (ct <= be)
        if m.any():
            print(f"    block{k+1} ({bs:.0f}-{be:.0f}s): "
                  f"median {np.median(cyc[m]):.0f} cyc/min "
                  f"(~{np.median(cyc[m])*2:.0f} strokes/min)")

    out = args.out or os.path.join(
        HERE, "fig_spm_" + os.path.splitext(os.path.basename(args.csv))[0] + ".png")
    fig, ax = plt.subplots(figsize=(17, 4))
    # break the line across rest gaps (where windows were skipped)
    cyc_plot = cyc.astype(float).copy()
    gap = np.where(np.diff(ct) > 3 * args.hop)[0]
    cyc_plot_nan = cyc_plot.copy()
    ct_plot = ct.astype(float).copy()
    for gi in gap:
        ct_plot = np.insert(ct_plot, gi + 1, ct[gi] + args.hop)
        cyc_plot_nan = np.insert(cyc_plot_nan, gi + 1, np.nan)
        gap = gap + 1
    ax.plot(ct_plot, cyc_plot_nan, ".-", ms=3, lw=0.5, color="teal")
    ax.axhline(np.median(cyc), color="orange", lw=0.8, ls="--",
               label=f"median {np.median(cyc):.0f} cyc/min")
    ax.set_ylabel("stroke-cycle rate (cyc/min)")
    ax.set_xlabel("time (s)")
    ax.set_ylim(0, max(60, np.percentile(cyc, 99) * 1.2))
    ax.set_title(os.path.basename(args.csv) + "  stroke cadence (prone windows)")
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=110)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
