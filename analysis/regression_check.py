"""Pseudo-GT regression harness over all captured pool sessions.

Every captured session has a .notes.md with the swimmer's own account
(felt distance, rest structure) — the only ground truth this project gets
(no phone at the pool). This script pins the detector + report output
against those accounts and against once-verified detection structure, so
any future tuning that fixes one session but silently breaks another
fails loudly here.

Run after ANY change to turn_stand.py / swim_report.py / preprocessing:

    .venv/bin/python analysis/regression_check.py

Exit code 0 = all pass. Sessions whose CSV is absent are skipped with a
warning (data/swim/ is tracked, so normally all are present).
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "src"))
sys.path.insert(0, HERE)
import dataio  # noqa: E402
from turn_stand import detect_walls  # noqa: E402

# Pinned expectations. Sources:
#   dist_halves/total : swim_report output validated against the swimmer's
#                       account (notes.md). 6/21 half1=500m matches the
#                       intended warmup+100x4; 7/28 half1=625m matches his
#                       own felt count exactly.
#   turns/rests/bigs  : verified detection structure (verticality signal +
#                       stand de-fragmentation, 2026-07-28 detector).
#   recovered_at      : rhythm-recovered walls (one shallow/quick stand per
#                       session, both cross-checked against the time grid).
#   7/28 total 1050 m is EXACT, not conservative: the swimmer confirmed it
#   (planned 1000 m plus an extra 50 m at the end).
#   strokes/swolf     : per-length gyro-roll zero-cross counts (2026-07-28).
#                       Median 14/length is consistent with the spectral SPM
#                       (30 cyc/min x ~29 s/length) and with SWOLF ~44; all
#                       lengths measurable (prone gate kills warmup junk).
EXPECT = {
    "swim_20260621_171349.csv": dict(
        turns=35, rests=13, bigs=2, recovered_at=[724],
        dist_halves=[500, 675], dist_total=1175,
        spl_median=14, strokes_total=647, lengths_measured=(47, 47), swolf_avg=44,
    ),
    "swim_20260728_153415.csv": dict(
        turns=41, rests=1, bigs=3, recovered_at=[533],
        dist_halves=[625, 425], dist_total=1050,
        spl_median=14, strokes_total=576, lengths_measured=(42, 42), swolf_avg=44,
    ),
}
TOL_S = 5.0        # tolerance for recovered-wall timestamps


def check(name, exp):
    path = os.path.join(HERE, "..", "data", "swim", name)
    if not os.path.exists(path):
        print(f"SKIP {name}: csv not present")
        return None

    fails = []
    d = detect_walls(dataio.load_swim_csv(path))
    for key in ("turns", "rests", "bigs"):
        got = len(d[key])
        if got != exp[key]:
            fails.append(f"{key}: got {got}, expected {exp[key]}")
    rec = [(a + b) / 2 for a, b in d["recovered"]]
    if len(rec) != len(exp["recovered_at"]) or any(
            abs(r - e) > TOL_S for r, e in zip(sorted(rec),
                                               sorted(exp["recovered_at"]))):
        fails.append(f"recovered: got {[f'{r:.0f}s' for r in rec]}, "
                     f"expected ~{exp['recovered_at']}s")

    out = subprocess.run(
        [sys.executable, os.path.join(HERE, "swim_report.py"), path],
        capture_output=True, text=True).stdout
    halves = [int(m) for m in re.findall(r"^\s+\d+\s+(\d+)m\s", out, re.M)]
    total = re.search(r"距離\s+(\d+) m", out)
    total = int(total.group(1)) if total else None
    if halves != exp["dist_halves"]:
        fails.append(f"half dists: got {halves}, expected {exp['dist_halves']}")
    if total != exp["dist_total"]:
        fails.append(f"total dist: got {total}, expected {exp['dist_total']}")

    st = re.search(r"strokes: 中央値 (\d+)/本 .*合計 (\d+)\s+\((\d+)/(\d+)本", out)
    sw = re.search(r"swolf:\s+平均 (\d+)", out)
    got_strokes = (int(st.group(1)), int(st.group(2)),
                   (int(st.group(3)), int(st.group(4)))) if st else None
    exp_strokes = (exp["spl_median"], exp["strokes_total"],
                   exp["lengths_measured"])
    if got_strokes != exp_strokes:
        fails.append(f"strokes (med, total, measured): got {got_strokes}, "
                     f"expected {exp_strokes}")
    if (int(sw.group(1)) if sw else None) != exp["swolf_avg"]:
        fails.append(f"swolf avg: got {sw and sw.group(1)}, "
                     f"expected {exp['swolf_avg']}")

    status = "PASS" if not fails else "FAIL"
    print(f"{status} {name}")
    for f in fails:
        print(f"       {f}")
    return not fails


def main():
    results = [check(name, exp) for name, exp in EXPECT.items()]
    ran = [r for r in results if r is not None]
    if not ran:
        print("no sessions checked")
        sys.exit(1)
    print(f"\n{sum(ran)}/{len(ran)} sessions pass")
    sys.exit(0 if all(ran) else 1)


if __name__ == "__main__":
    main()
