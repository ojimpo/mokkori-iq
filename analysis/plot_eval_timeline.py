"""Plot detector behaviour over full sessions: envelope, thresholds, GT windows,
and detected turns. Visual sanity check of the tuned config.

Usage: python analysis/plot_eval_timeline.py [Style] [n_sessions]
"""
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
import evaluate as ev  # noqa: E402
import preprocessing as pp  # noqa: E402

STYLE = sys.argv[1] if len(sys.argv) > 1 else "Freestyle"
NSESS = int(sys.argv[2]) if len(sys.argv) > 2 else 4

cfg = pp.load_config()
tol = float(cfg["matching"]["tolerance_s"])
detector = det_mod.TurnDetector(cfg)
detector.debug = True

# pick sessions with a healthy number of turns, from different swimmers
chosen = []
seen = set()
for s in dataio.list_sessions(style=STYLE):
    if s["swimmer"] in seen:
        continue
    d = dataio.load_session(s["path"])
    n_turn = len(dataio.find_segments(d["label"], 5))
    if 4 <= n_turn <= 12:
        chosen.append((s, d))
        seen.add(s["swimmer"])
    if len(chosen) >= NSESS:
        break

fig, axes = plt.subplots(len(chosen), 1, figsize=(15, 3.2 * len(chosen)))
if len(chosen) == 1:
    axes = [axes]

for ax, (s, d) in zip(axes, chosen):
    dets = detector.process(d)
    tr = detector.trace
    t = d["t"]
    an = d["acc_norm"]
    env = np.array(tr["activity"])
    thr_low = np.array(tr["thr_low"])
    swim_ref = np.array(tr["swim_ref"])

    ax.plot(t, an, color="0.8", lw=0.6, label="acc_norm")
    ax.plot(t, env, color="C0", lw=1.1, label="activity env")
    ax.plot(t, thr_low, color="C1", lw=0.9, ls="--", label="thr_low")
    ax.plot(t, swim_ref, color="C2", lw=0.8, alpha=0.7, label="swim_ref")

    gt = ev.gt_turn_windows(d)
    det_t = [dd["t"] for dd in dets]
    matches, fp, fn = ev.match(det_t, gt, tol)
    matched_gt = set(gi for (gi, di) in matches)
    matched_det = set(di for (gi, di) in matches)
    # GT windows: green=matched (TP), red=missed (FN)
    for gi, (a0, b0, c0) in enumerate(gt):
        col = "green" if gi in matched_gt else "red"
        ax.axvspan(a0, b0, color=col, alpha=0.15)
    # detections: blue=TP, red=FP
    for di, dd in enumerate(dets):
        col = "blue" if di in matched_det else "red"
        ax.axvline(dd["t"], color=col, lw=1.3, alpha=0.85)
    ax.set_title("swimmer %s  (%s)  GT=%d det=%d  TP=%d FP=%d FN=%d" % (
        s["swimmer"], s["epoch_ms"], len(gt), len(dets),
        len(matches), len(fp), len(fn)), fontsize=9)
    ax.set_ylim(0, max(30, float(np.percentile(an, 99))))
    ax.grid(alpha=0.3)

axes[0].legend(fontsize=7, ncol=5, loc="upper right")
axes[-1].set_xlabel("time (s)   |   green=GT turn window, red=detected turn")
fig.suptitle("Detector timeline -- %s (tuned config)" % STYLE)
fig.tight_layout()
out = os.path.join(HERE, "fig_eval_timeline_%s.png" % STYLE)
fig.savefig(out, dpi=110)
plt.close(fig)
print("wrote", out)
