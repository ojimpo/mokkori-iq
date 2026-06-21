"""Wall / turn / rest detector via body-axis orientation (gravity on z).

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


def detect_walls(sess, thr=2.0, vthr=5.0, refractory=12.0, tau=1.0):
    """Detect walls/turns/rests from body-axis gravity (gz). Shared by the
    report tool. Returns a dict of episode lists (each item is (start, end)),
    plus block start/end times. turns keep their full (start, end) span.
    """
    t, acc, fs = sess["t"], sess["acc"], sess["fs"]
    gz = ema(acc[:, 2], fs, tau)                  # gravity on body-long axis
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

    # refractory: drop a turn within `refractory` s of the previous kept wall
    order = sorted([(a, b, 'turn') for a, b in turns_e] +
                   [(a, b, 'rest') for a, b in rests] +
                   [(a, b, 'big') for a, b in bigs])
    kept, last = [], -1e9
    for a, b, kind in order:
        if kind != 'turn' or (a - last) >= refractory:
            kept.append((a, b, kind))
            last = a
    turns = [(a, b) for a, b, k in kept if k == 'turn']

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
        "taps": taps, "triples": triples,
        "starts": [t[0]] + [b for _, b in bigs],
        "ends": [a for a, _ in bigs] + [t[-1]],
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
    for a, _ in turns:
        ax.axvline(a, color="red", lw=0.8, alpha=0.7)
    for a, b in rests:
        ax.axvspan(a, b, color="green", alpha=0.25)
    for a, b in bigs:
        ax.axvspan(a, b, color="purple", alpha=0.20)
    for a, b in triples:
        ax.axvspan(a - 0.5, b + 0.5, color="blue", alpha=0.5)
    ax.set_ylabel("gz gravity (m/s^2)")
    ax.set_xlabel("time (s)")
    ax.set_title(os.path.basename(args.csv) +
                 f"  red=turn green=rest purple=bigrest blue=tap  ~{total_len} lengths")
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=110)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
