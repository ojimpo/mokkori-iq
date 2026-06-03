"""Where do the false positives concentrate? Per-session FP diagnosis."""
import os
import sys

import numpy as np

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "src"))
import dataio  # noqa: E402
import detector as det_mod  # noqa: E402
import evaluate as ev  # noqa: E402
import preprocessing as pp  # noqa: E402

cfg = pp.load_config()
tol = float(cfg["matching"]["tolerance_s"])
detector = det_mod.TurnDetector(cfg)

rows = []
for s in dataio.list_sessions(style="Freestyle"):
    d = dataio.load_session(s["path"])
    r = ev.evaluate_session(d, detector, tol)
    frac_null = float((d["label"] == 0).mean())
    dur = float(d["t"][-1] - d["t"][0])
    rows.append((s["swimmer"], s["epoch_ms"], r["n_gt_turns"], r["n_det_turns"],
                 r["tp"], r["fp"], r["fn"], frac_null, dur))

tot_fp = sum(r[5] for r in rows)
tot_tp = sum(r[4] for r in rows)
tot_fn = sum(r[6] for r in rows)
print("TP=%d FP=%d FN=%d  P=%.3f R=%.3f" % (
    tot_tp, tot_fp, tot_fn, tot_tp / (tot_tp + tot_fp), tot_tp / (tot_tp + tot_fn)))
print()

zero = [r for r in rows if r[2] == 0]
nonzero = [r for r in rows if r[2] > 0]
print("zero-GT-turn sessions: %d, FP total = %d (%.0f pct of all FP)" % (
    len(zero), sum(r[5] for r in zero),
    100.0 * sum(r[5] for r in zero) / max(1, tot_fp)))
print("has-turn sessions: %d, FP total = %d" % (
    len(nonzero), sum(r[5] for r in nonzero)))
print()

print("=== top 12 sessions by FP ===")
print("swimmer  epoch          GT det TP FP FN  nullf  dur_s")
rows.sort(key=lambda r: r[5], reverse=True)
for r in rows[:12]:
    print("%-7s  %-13s  %2d %3d %2d %2d %2d   %.2f   %.0f" % (
        r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8]))
print()

fps = np.array([r[5] for r in rows], dtype=float)
nulls = np.array([r[7] for r in rows])
durs = np.array([r[8] for r in rows])
fp_per_min = fps / (durs / 60.0 + 1e-9)
print("FP per minute: mean=%.2f median=%.2f" % (fp_per_min.mean(), np.median(fp_per_min)))
print("corr(FP, nullfrac) = %.2f" % np.corrcoef(fps, nulls)[0, 1])
