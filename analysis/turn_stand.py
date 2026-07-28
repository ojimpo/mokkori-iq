"""Wall / turn / rest detector via body-axis orientation (gravity).

Orientation-independent since 2026-07-28: the device can be tossed into the
suit in any orientation. `verticality()` self-calibrates per session (swim
posture from high-gyro samples, stand posture from short repeated vertical
episodes) and projects gravity onto the swim->stand axis, mapped to the
canonical gz scale of the first session (swim ~ -7.5, stand ~ +9.5).
Known trade-off: 3-tap blips tend to merge into the surrounding stand episode
on the projected signal (tap recovery on 2026-06-21 is lost; move taps to the
jerk domain within stands if they are needed again).

Tuned to how this swimmer actually swims a citizen pool (no phone GT available):
  - OPEN turns, no flip: at each wall he plants his feet on the bottom and
    stands briefly before pushing off. Standing rotates the crotch-mounted
    device from horizontal (prone swimming) to vertical, so the *gravity*
    component on the device z-axis swings from ~-6 m/s^2 (swimming) to ~+9 m/s^2
    (standing). That swing is the cleanest, most reliable turn signature here --
    far better than glide gaps or flip-rotation, which barely register.
  - Between 100 m reps he SITS on a bench (also torso-vertical -> gz positive),
    with ~10 s of standing/walking on either side. So rests look like long
    standing episodes; reps are bounded by them.
  - The deliberate 3-tap markers, unrecoverable in the jerk domain (buried
    mid-stroke underwater), reappear here as tight triples of ~1 s gz blips
    while standing at the wall.

Classification of standing episodes (gz-gravity > THR):
    tap-blip  < 1.2 s   (clustered triples = the 3-tap markers)
    turn      1.2-7 s   (open turn: plant + push off)        -> a mid-rep wall
    rest      7-90 s    (bench sit, +walk in/out)            -> a rep boundary
    big-rest  > 90 s    (the half-way split)                 -> a block split

lengths(block) = (#turns + #rests) in block + 1     # walls + the opening length
A 100 m rep in a 25 m pool = 4 lengths = 3 turns then a rest.

Usage:
    python analysis/turn_stand.py data/swim/swim_YYYYMMDD_HHMMSS.csv
    python analysis/turn_stand.py <csv> --thr 2.0 --pool 25
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


def ema(x, fs, tau):
    a = 1.0 - np.exp(-1.0 / (tau * fs))
    out = np.empty_like(x)
    s = x[0]
    for i in range(len(x)):
        s += a * (x[i] - s)
        out[i] = s
    return out


def episodes(mask, t, sig, min_dur):
    """Contiguous True runs >= min_dur. Returns (start, end, peak_sig)."""
    out = []
    i, n = 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            if t[j - 1] - t[i] >= min_dur:
                out.append((t[i], t[j - 1], float(sig[i:j].max())))
            i = j
        else:
            i += 1
    return out


def _index_runs(mask):
    """Contiguous True runs as (i, j) index pairs (j exclusive)."""
    out = []
    i, n = 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            out.append((i, j))
            i = j
        else:
            i += 1
    return out


def verticality(sess, tau=1.0):
    """Orientation-independent 'torso vertical' signal, mapped onto the
    canonical gz scale of the 2026-06-21 session (swim ~ -7.5, stand ~ +9.5)
    so downstream thresholds keep their meaning regardless of how the device
    was tossed into the suit.

    Calibration (self-contained, per session):
      1. g_swim  = median low-passed gravity over high-gyro-activity samples
                   (swimming dominates rotation activity).
      2. Candidate verticals = episodes where |g - g_swim| exceeds ~55% of the
         session's robust max deviation.
      3. g_stand = median gravity at the peaks of the SHORT repeated candidates
                   (1.2-7 s = open-turn wall stands). Anchoring on these, not on
                   the global max posture, matters: bench sitting deviates MORE
                   than standing but in a different direction, and projecting on
                   the sit axis would bury the wall stands.
      4. Signal  = (g - g_swim) . unit(g_stand - g_swim), affinely mapped so
                   swim -> -7.5 and g_stand -> +9.5.
    """
    t, acc, gyro, fs = sess["t"], sess["acc"], sess["gyro"], sess["fs"]
    g = np.column_stack([ema(acc[:, i], fs, tau) for i in range(3)])
    act = ema(np.linalg.norm(gyro, axis=1), fs, 2.0)
    g_swim = np.median(g[act > np.percentile(act, 60)], axis=0)

    dev = np.linalg.norm(g - g_swim, axis=1)
    ref = np.percentile(dev, 99.0)
    runs = _index_runs(dev > 0.55 * ref)
    peaks = [i + int(np.argmax(dev[i:j])) for i, j in runs]
    short = [p for (i, j), p in zip(runs, peaks)
             if 1.2 <= t[j - 1] - t[i] <= 7.0]
    anchor = short if len(short) >= 3 else peaks   # fallback: few/no wall stands
    if not anchor:                                 # degenerate: never stood up
        return ema(acc[:, 2], fs, tau)
    g_stand = np.median(g[anchor], axis=0)

    u = g_stand - g_swim
    scale = float(np.linalg.norm(u))
    v = (g - g_swim) @ (u / scale)
    return -7.5 + v * (17.0 / scale)


def detect_walls(sess, thr=2.0, vthr=5.0, refractory=12.0, tau=1.0):
    """Detect walls/turns/rests from body-verticality gravity. Shared by the
    report tool. Returns a dict of episode lists (each item is (start, end)),
    plus block start/end times. turns keep their full (start, end) span.
    """
    t = sess["t"]
    gz = verticality(sess, tau)       # gravity on body-long axis (auto-oriented)
    eps = episodes(gz > thr, t, gz, 0.8)

    # classify; a real plant/stand must reach clearly vertical (peak gz > vthr),
    # else it's in-water bobbing/half-roll, not a wall.
    taps, turns_e, rests, bigs = [], [], [], []
    for a, b, pk in eps:
        d = b - a
        if d >= 90.0:
            bigs.append((a, b))
        elif d >= 7.0 and pk > vthr:
            rests.append((a, b))
        elif d < 1.2:
            taps.append((a, b))
        elif pk > vthr:
            turns_e.append((a, b))
        # else: dropped (short + not clearly vertical = bob/noise)

    # De-fragment: a single wall arrival splits into two episodes when the
    # verticality dips briefly under thr mid-stand (6/21 @2251+2259, 4 s apart;
    # 7/28 @2430+2471, 0.8 s apart). Two *real* walls are always at least one
    # length-time apart, so anything closer than `refractory` is the same wall
    # and gets unioned. Measured gaps are bimodal with a wide empty band --
    # fragments 0.8-8.4 s, next genuine gap 14.4 s -- so 12 s sits in the gap.
    # Union (not drop, as the old refractory did) also keeps the stand's true
    # end time, which the report uses to bound swim spans.
    merged = []
    for a, b in sorted(turns_e + rests + bigs):
        if merged and a - merged[-1][1] < refractory:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    turns, rests, bigs = [], [], []
    for a, b in merged:                       # reclassify by the merged span
        (bigs if b - a >= 90.0 else rests if b - a >= 7.0 else turns).append((a, b))

    # rhythm recovery: walls are near-equidistant within a block. A swim gap
    # (end of one stand -> start of the next, standing time excluded) of ~2x
    # the block's median, with a clear sub-threshold vertical excursion at its
    # midpoint, is a missed shallow/quick stand -> recover one wall there.
    # Both known misses (6/21 @721s peak 3.5, 7/28 @532s peak 1.35) have
    # exactly this shape; gz > 0 is ~45% of the swim->stand swing, far above
    # mid-swim noise (~ -7.5 +/- 1.5). Needs >= 6 walls for a stable median.
    starts = [t[0]] + [b for _, b in bigs]
    ends = [a for a, _ in bigs] + [t[-1]]
    walls_all = sorted(turns + rests)
    recovered = []
    for bs, be in zip(starts, ends):
        w = [(a, b) for a, b in walls_all if bs <= a <= be]
        if len(w) < 6:
            continue
        gaps = [w[k + 1][0] - w[k][1] for k in range(len(w) - 1)]
        med = float(np.median(gaps))
        for (a0, b0), (a1, _), g in zip(w, w[1:], gaps):
            if not (1.6 * med <= g <= 2.6 * med):
                continue
            m = (t >= b0 + 0.3 * g) & (t <= b0 + 0.7 * g)
            if not m.any():
                continue
            k = np.flatnonzero(m)[int(np.argmax(gz[m]))]
            if gz[k] > 0.0:
                recovered.append((t[k] - 0.5, t[k] + 0.5))
    turns = sorted(turns + recovered)

    # tap triples: >=3 tap-blips within a 4 s span (the 3-tap markers)
    triples, i = [], 0
    while i < len(taps):
        j = i
        while j + 1 < len(taps) and taps[j + 1][0] - taps[i][0] < 4.0:
            j += 1
        if j - i + 1 >= 3:
            triples.append((taps[i][0], taps[j][1]))
            i = j + 1
        else:
            i += 1

    return {
        "gz": gz, "turns": turns, "rests": rests, "bigs": bigs,
        "taps": taps, "triples": triples, "recovered": recovered,
        "starts": starts, "ends": ends,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--thr", type=float, default=2.0,
                    help="gz-gravity threshold (m/s^2) for 'torso vertical'")
    ap.add_argument("--vthr", type=float, default=5.0,
                    help="peak gz a real plant/stand must reach (rejects in-water bobbing)")
    ap.add_argument("--refractory", type=float, default=12.0,
                    help="min seconds between walls (one length-time floor)")
    ap.add_argument("--pool", type=float, default=25.0)
    ap.add_argument("--tau", type=float, default=1.0, help="gravity EMA tau (s)")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    sess = dataio.load_swim_csv(args.csv)
    t, acc, fs = sess["t"], sess["acc"], sess["fs"]

    d = detect_walls(sess, args.thr, args.vthr, args.refractory, args.tau)
    gz = d["gz"]
    turns, rests, bigs = d["turns"], d["rests"], d["bigs"]
    taps, triples = d["taps"], d["triples"]
    starts, ends = d["starts"], d["ends"]
    walls = sorted([a for a, _ in turns] + [a for a, _ in rests])

    print(f"file: {args.csv}")
    print(f"duration {t[-1]-t[0]:.0f}s ({(t[-1]-t[0])/60:.1f}min)  fs {fs:.1f}Hz  "
          f"gz_thr {args.thr}  pool {args.pool:.0f}m")
    print(f"episodes: {len(turns)} turns, {len(rests)} rests, "
          f"{len(bigs)} big-rests, {len(taps)} tap-blips ({len(triples)} triples)")
    if d["recovered"]:
        print("rhythm-recovered walls: "
              + ", ".join(f"{(a+b)/2:.0f}s" for a, b in d["recovered"]))

    total_len = 0
    print(f"\n{'block':>5} {'start':>7} {'end':>7} {'turns':>5} {'rests':>5} "
          f"{'lengths':>7} {'dist':>6}")
    for k, (bs, be) in enumerate(zip(starts, ends)):
        nt = sum(1 for a, _ in turns if bs <= a <= be)
        nr = sum(1 for a, _ in rests if bs <= a <= be)
        n_len = nt + nr + 1
        total_len += n_len
        print(f"{k+1:>5} {bs:>7.0f} {be:>7.0f} {nt:>5} {nr:>5} "
              f"{n_len:>7} {int(n_len*args.pool):>5}m")
    print(f"\nTOTAL ~{total_len} lengths ~= {int(total_len*args.pool)}m")

    # per-rep breakdown within each block (reps split by bench rests)
    print("\n=== rep breakdown (turns between bench rests; 3 turns = 100m) ===")
    for k, (bs, be) in enumerate(zip(starts, ends)):
        bnd = [bs] + sorted(a for a, _ in rests if bs <= a <= be) + [be]
        print(f" block{k+1}:")
        for r in range(len(bnd) - 1):
            lo, hi = bnd[r], bnd[r + 1]
            tns = [a for a, _ in turns if lo < a < hi]
            if not tns and r > 0:
                continue
            laps = len(tns) + 1
            print(f"   rep {r+1}: {lo:6.0f}-{hi:6.0f}s  {len(tns)} turns "
                  f"-> {laps}x{int(args.pool)}m = {laps*int(args.pool)}m"
                  + ("   <- not 100m?" if laps != 4 else ""))

    if triples:
        print(f"\ntap-triple markers recovered (gz domain): "
              + ", ".join(f"{a:.0f}s" for a, _ in triples))

    # plot
    out = args.out or os.path.join(
        HERE, "fig_stand_" + os.path.splitext(os.path.basename(args.csv))[0] + ".png")
    fig, ax = plt.subplots(figsize=(17, 5))
    ax.plot(t, gz, lw=0.4, color="0.5")
    ax.axhline(args.thr, color="orange", lw=0.8, ls="--", label=f"thr={args.thr}")
    rec = set(d["recovered"])
    for a, b in turns:
        ax.axvline(a, color=("darkorange" if (a, b) in rec else "red"),
                   lw=0.8, alpha=0.7)
    for a, b in rests:
        ax.axvspan(a, b, color="green", alpha=0.25)
    for a, b in bigs:
        ax.axvspan(a, b, color="purple", alpha=0.20)
    for a, b in triples:
        ax.axvspan(a - 0.5, b + 0.5, color="blue", alpha=0.5)
    ax.set_ylabel("gz gravity (m/s^2)")
    ax.set_xlabel("time (s)")
    ax.set_title(os.path.basename(args.csv) +
                 f"  red=turn orange=recovered green=rest purple=bigrest blue=tap"
                 f"  ~{total_len} lengths")
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=110)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
