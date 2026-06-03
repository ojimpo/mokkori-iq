"""Plot specific swimmers' sessions to inspect suspected label gaps."""
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

want = sys.argv[1:] if len(sys.argv) > 1 else ["20", "31"]
cfg = pp.load_config()
tol = float(cfg["matching"]["tolerance_s"])
detector = det_mod.TurnDetector(cfg)
detector.debug = True

best = {}
for s in dataio.list_sessions(style="Freestyle"):
    if s["swimmer"] not in want:
        continue
    d = dataio.load_session(s["path"])
    cur = best.get(s["swimmer"])
    if cur is None or len(d["t"]) > len(cur[1]["t"]):
        best[s["swimmer"]] = (s, d)
chosen = [best[w] for w in want if w in best]

fig, axes = plt.subplots(len(chosen), 1, figsize=(15, 3.4 * len(chosen)))
if len(chosen) == 1:
    axes = [axes]

for ax, (s, d) in zip(axes, chosen):
    dets = detector.process(d)
    tr = detector.trace
    t = d["t"]
    ax.plot(t, d["acc_norm"], color="0.8", lw=0.5)
    ax.plot(t, np.array(tr["activity"]), color="C0", lw=1.0)
    ax.plot(t, np.array(tr["thr_low"]), color="C1", lw=0.8, ls="--")
    gt = ev.gt_turn_windows(d)
    for (a0, b0, c0) in gt:
        ax.axvspan(a0, b0, color="green", alpha=0.25)
    dt = sorted(dd["t"] for dd in dets)
    for x in dt:
        ax.axvline(x, color="red", lw=1.0, alpha=0.7)
    iv = np.diff(dt) if len(dt) > 1 else np.array([0.0])
    ax.set_title("swimmer %s  GT=%d det=%d  interval med=%.1fs std=%.1f" % (
        s["swimmer"], len(gt), len(dt), float(np.median(iv)), float(np.std(iv))),
        fontsize=9)
    ax.set_ylim(0, 30)
    ax.grid(alpha=0.3)

axes[-1].set_xlabel("time (s)   green=GT turn, red=detected turn")
fig.tight_layout()
out = os.path.join(HERE, "fig_suspect_sessions.png")
fig.savefig(out, dpi=110)
plt.close(fig)
print("wrote", out)
for (s, d) in chosen:
    dets = detector.process(d)
    dt = sorted(dd["t"] for dd in dets)
    iv = np.diff(dt) if len(dt) > 1 else np.array([0.0])
    print("swimmer %s: det=%d, interval med=%.1fs p25=%.1f p75=%.1f" % (
        s["swimmer"], len(dt), float(np.median(iv)),
        float(np.percentile(iv, 25)), float(np.percentile(iv, 75))))
