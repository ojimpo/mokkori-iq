"""Explore the signal signature of freestyle turns.

Hypothesis (touch turn): steady stroke activity -> brief low-activity valley at
the wall (touch/glide) -> acceleration spike at push-off.

We characterise this with an "activity envelope" = rolling std of the accel
norm. For exploration we use a centered window (non-causal); the detector will
use a causal variant. Saves figures to analysis/ and prints quantitative stats.
"""
import os
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import dataio  # noqa: E402

FS = dataio.FS_HZ
HERE = os.path.dirname(__file__)


def rolling_std(x, w):
    """Centered rolling std via cumulative sums. w in samples."""
    n = len(x)
    if w < 2:
        return np.zeros(n)
    c1 = np.cumsum(np.insert(x, 0, 0.0))
    c2 = np.cumsum(np.insert(np.square(x), 0, 0.0))
    half = w // 2
    out = np.zeros(n)
    for i in range(n):
        a = max(0, i - half)
        b = min(n, i + half + 1)
        cnt = b - a
        mean = (c1[b] - c1[a]) / cnt
        var = (c2[b] - c2[a]) / cnt - mean * mean
        out[i] = np.sqrt(var) if var > 0.0 else 0.0
    return out


W_ENV = int(round(0.5 * FS))  # 0.5 s activity window (15 samples)

# ---- 1. accel-norm level by class (is gravity included?) -------------------
levels = {0: [], 1: [], 5: []}
for s in dataio.list_sessions(style="Freestyle"):
    d = dataio.load_session(s["path"])
    an = d["acc_norm"]
    lab = d["label"]
    for k in levels:
        if np.any(lab == k):
            levels[k].append(an[lab == k])
print("=== accel norm by class (Freestyle) ===")
for k in (0, 1, 5):
    v = np.concatenate(levels[k]) if levels[k] else np.array([0.0])
    print("  %-9s mean=%.2f  median=%.2f  p05=%.2f  p95=%.2f" % (
        dataio.LABEL_NAMES[k], v.mean(), np.median(v),
        np.percentile(v, 5), np.percentile(v, 95)))
print()

# ---- 2. per-turn features --------------------------------------------------
turn_valley = []
turn_spike = []
turn_still_len_s = []
swim_env_level = []

for s in dataio.list_sessions(style="Freestyle"):
    d = dataio.load_session(s["path"])
    an = d["acc_norm"]
    lab = d["label"]
    env = rolling_std(an, W_ENV)
    if np.any(lab == 1):
        swim_ref = np.median(env[lab == 1])
        swim_env_level.append(swim_ref)
    else:
        swim_ref = np.median(env)
    for (a, b, ln) in dataio.find_segments(lab, 5):
        seg_env = env[a:b + 1]
        seg_an = an[a:b + 1]
        turn_valley.append(seg_env.min())
        turn_spike.append(seg_an.max())
        thr = 0.4 * swim_ref
        still = seg_env < thr
        best = 0
        run = 0
        for f in still:
            run = run + 1 if f else 0
            if run > best:
                best = run
        turn_still_len_s.append(best / FS)

turn_valley = np.array(turn_valley)
turn_spike = np.array(turn_spike)
turn_still_len_s = np.array(turn_still_len_s)
swim_env_level = np.array(swim_env_level)

print("=== per-turn features (Freestyle, n=%d) ===" % len(turn_valley))
print("swimming env level (median per session): mean=%.2f median=%.2f" % (
    swim_env_level.mean(), np.median(swim_env_level)))
print("turn valley (min env in window): median=%.2f p25=%.2f p75=%.2f" % (
    np.median(turn_valley), np.percentile(turn_valley, 25),
    np.percentile(turn_valley, 75)))
print("turn kick spike (max acc_norm): median=%.1f p25=%.1f p75=%.1f" % (
    np.median(turn_spike), np.percentile(turn_spike, 25),
    np.percentile(turn_spike, 75)))
print("still-period length (env<0.4*swim) s: median=%.2f p25=%.2f p75=%.2f frac_with_still=%.2f" % (
    np.median(turn_still_len_s), np.percentile(turn_still_len_s, 25),
    np.percentile(turn_still_len_s, 75), float((turn_still_len_s > 0.2).mean())))
print()

# ---- 3. figure: example turns from different swimmers ----------------------
examples = []
seen = set()
for s in dataio.list_sessions(style="Freestyle"):
    if s["swimmer"] in seen:
        continue
    d = dataio.load_session(s["path"])
    turns = dataio.find_segments(d["label"], 5)
    if not turns:
        continue
    a, b, ln = turns[len(turns) // 2]
    examples.append((s["swimmer"], d, a, b))
    seen.add(s["swimmer"])
    if len(examples) >= 12:
        break

fig, axes = plt.subplots(4, 3, figsize=(15, 12), sharex=True)
for ax, (sw, d, a, b) in zip(axes.ravel(), examples):
    an = d["acc_norm"]
    gn = d["gyro_norm"]
    env = rolling_std(an, W_ENV)
    c = (a + b) // 2
    lo = max(0, c - int(5 * FS))
    hi = min(len(an), c + int(5 * FS))
    tt = (np.arange(lo, hi) - c) / FS
    ax.plot(tt, an[lo:hi], color="0.7", lw=0.8, label="acc_norm")
    ax.plot(tt, env[lo:hi], color="C0", lw=1.5, label="env(acc)")
    ax.plot(tt, gn[lo:hi] / 50.0, color="C3", lw=0.9, alpha=0.7, label="gyro_norm/50")
    ax.axvspan((a - c) / FS, (b - c) / FS, color="orange", alpha=0.2)
    ax.set_title("swimmer %s" % sw, fontsize=9)
    ax.grid(alpha=0.3)
axes[0, 0].legend(fontsize=7, loc="upper right")
fig.suptitle("Freestyle turn examples (orange = labeled turn window, t=0 at center)")
fig.supxlabel("time (s) relative to turn center")
fig.tight_layout()
p = os.path.join(HERE, "fig_turn_examples_freestyle.png")
fig.savefig(p, dpi=110)
plt.close(fig)
print("wrote", p)

# ---- 4. figure: turn-aligned mean envelope, by style -----------------------
HALF = int(5 * FS)
fig2, ax2 = plt.subplots(figsize=(9, 5))
for style, col in [("Freestyle", "C0"), ("Butterfly", "C1"),
                   ("Breaststroke", "C2"), ("Backstroke", "C3")]:
    style_label = dataio.STYLE_TO_LABEL[style]
    stack = []
    for s in dataio.list_sessions(style=style):
        d = dataio.load_session(s["path"])
        env = rolling_std(d["acc_norm"], W_ENV)
        ref = np.median(env[d["label"] == style_label]) if np.any(
            d["label"] == style_label) else np.median(env)
        ref = ref if ref > 1e-6 else 1.0
        for (a, b, ln) in dataio.find_segments(d["label"], 5):
            c = (a + b) // 2
            if c - HALF < 0 or c + HALF >= len(env):
                continue
            stack.append(env[c - HALF:c + HALF] / ref)
    if not stack:
        continue
    arr = np.array(stack)
    tt = (np.arange(-HALF, HALF)) / FS
    m = arr.mean(axis=0)
    ax2.plot(tt, m, color=col, lw=2, label="%s (n=%d)" % (style, len(stack)))
ax2.axvline(0, color="k", lw=0.8, ls="--")
ax2.set_xlabel("time (s) relative to turn center")
ax2.set_ylabel("activity envelope / swimming activity")
ax2.set_title("Turn-aligned activity envelope by style (center-aligned)")
ax2.legend()
ax2.grid(alpha=0.3)
fig2.tight_layout()
p2 = os.path.join(HERE, "fig_turn_aligned_by_style.png")
fig2.savefig(p2, dpi=110)
plt.close(fig2)
print("wrote", p2)
