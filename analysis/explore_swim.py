"""Explore a mokkori flash-logger swim capture.

Loads a tools/flash_dump.py CSV, plots the (crotch-mounted) IMU signal, and
overlays what the Phase 0 detector -- still tuned on Brunner WRIST data at
30 Hz -- does on it. This is the first look at how the signal and the existing
detector behave in the real mounting position; expect to re-tune from here.

Usage:
    python analysis/explore_swim.py data/swim/session01.csv
    python analysis/explore_swim.py data/swim/session01.csv --out analysis/fig_swim01.png
    python analysis/explore_swim.py data/swim/session01.csv --fs 52
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
import detector as det_mod  # noqa: E402
import preprocessing as pp  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description="Inspect a swim capture + detector.")
    ap.add_argument("csv", help="flash_dump.py CSV (idx,t,ax..gz)")
    ap.add_argument("--fs", type=float, default=None,
                    help="override sampling rate (else inferred from t)")
    ap.add_argument("--out", default=None, help="figure path")
    args = ap.parse_args()

    sess = dataio.load_swim_csv(args.csv, fs=args.fs)
    fs = sess["fs"]
    cfg = pp.make_config_for_fs(fs)            # 52 Hz biquad, seconds-based windows
    det = det_mod.TurnDetector(cfg)
    det.debug = True
    dets = det.process(sess)
    tr = det.trace
    t = sess["t"]
    det_t = sorted(d["t"] for d in dets)

    dur = float(t[-1] - t[0]) if len(t) else 0.0
    print(f"file: {args.csv}")
    print(f"samples: {len(t)}  duration: {dur:.1f}s  fs: {fs:.1f}Hz")
    print(f"|acc| mean: {np.mean(sess['acc_norm']):.2f} m/s^2  "
          f"|gyro| mean: {np.mean(sess['gyro_norm']):.2f} rad/s")
    print(f"detections: {len(dets)}")
    if det_t:
        print("  times(s): " + ", ".join(f"{x:.1f}" for x in det_t))
        if len(det_t) > 1:
            iv = np.diff(det_t)
            print(f"  interval median: {np.median(iv):.1f}s "
                  f"(min {iv.min():.1f}, max {iv.max():.1f})")

    fig, ax = plt.subplots(3, 1, figsize=(15, 9), sharex=True)
    title = (f"{os.path.basename(args.csv)}   {dur:.0f}s @ {fs:.0f}Hz   "
             f"det={len(dets)} (red)")

    ax[0].plot(t, sess["acc_norm"], color="0.7", lw=0.6)
    ax[0].axhline(dataio.G0, color="k", lw=0.5, ls=":")   # 1 g reference
    ax[0].set_ylabel("|acc|  m/s^2")
    ax[0].set_title(title, fontsize=10)

    ax[1].plot(t, np.array(tr["activity"]), color="C0", lw=1.0, label="activity")
    ax[1].plot(t, np.array(tr["thr_low"]), color="C1", lw=0.8, ls="--", label="thr_low")
    ax[1].plot(t, np.array(tr["thr_high"]), color="C2", lw=0.8, ls="--", label="thr_high")
    ax[1].set_ylabel("activity")
    ax[1].legend(loc="upper right", fontsize=8)

    ax[2].plot(t, sess["gyro_norm"], color="C3", lw=0.6)
    ax[2].set_ylabel("|gyro|  rad/s")
    ax[2].set_xlabel("time (s)    red = detected turn")

    for a in ax:
        for x in det_t:
            a.axvline(x, color="red", lw=0.9, alpha=0.6)
        a.grid(alpha=0.3)

    fig.tight_layout()
    stem = os.path.splitext(os.path.basename(args.csv))[0]
    out = args.out or os.path.join(HERE, f"fig_swim_{stem}.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print("wrote", out)


if __name__ == "__main__":
    main()
