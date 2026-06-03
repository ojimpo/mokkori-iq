"""Grid-search detector parameters on preloaded Freestyle sessions.

Preloads every session once (CSV loading is the slow part), then evaluates many
configs fast by reusing evaluate.evaluate_session on in-memory session dicts.
Prints the best configs by F1 and by lap-count exact-match rate.
"""
import copy
import itertools
import os
import sys

import numpy as np

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "src"))
import dataio  # noqa: E402
import detector as det_mod  # noqa: E402
import evaluate as ev  # noqa: E402
import preprocessing as pp  # noqa: E402

STYLE = sys.argv[1] if len(sys.argv) > 1 else "Freestyle"

print("preloading %s sessions..." % STYLE)
SESSIONS = []
META = dataio.list_sessions(style=STYLE)
for s in META:
    SESSIONS.append(dataio.load_session(s["path"]))
print("loaded", len(SESSIONS), "sessions")

base = pp.load_config()
tol = float(base["matching"]["tolerance_s"])


def run_config(cfg):
    detector = det_mod.TurnDetector(cfg)
    rows = []
    all_lap = []
    for sess in SESSIONS:
        r = ev.evaluate_session(sess, detector, tol)
        all_lap.extend(r["lap_errs_s"])
        rows.append(r)
    tp = sum(r["tp"] for r in rows)
    fp = sum(r["fp"] for r in rows)
    fn = sum(r["fn"] for r in rows)
    prec = tp / (tp + fp) if (tp + fp) else 0.0
    rec = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2.0 * prec * rec / (prec + rec) if (prec + rec) else 0.0
    exact = float(np.mean([r["count_exact"] for r in rows]))
    within1 = float(np.mean([r["count_within1"] for r in rows]))
    lap_mae = float(np.mean(all_lap)) if all_lap else float("nan")
    return {"prec": prec, "rec": rec, "f1": f1, "exact": exact,
            "within1": within1, "tp": tp, "fp": fp, "fn": fn, "lap_mae": lap_mae}


def make_cfg(window, enter, exit_r, floor, min_still, max_still, refr):
    cfg = copy.deepcopy(base)
    cfg["preprocess"]["activity_window_s"] = window
    d = cfg["detector"]
    d["dip_enter_ratio"] = enter
    d["dip_exit_ratio"] = exit_r
    d["dip_abs_floor"] = floor
    d["min_still_s"] = min_still
    d["max_still_s"] = max_still
    d["refractory_s"] = refr
    return cfg


grid = {
    "window": [0.6, 1.0, 1.4],
    "enter": [0.2, 0.3],
    "floor": [1.0, 1.8],
    "min_still": [0.5, 0.9],
    "max_still": [4.0],
    "refr": [2.5],
}
keys = list(grid.keys())
arrays = [grid[k] for k in keys]
combos = list(itertools.product(arrays[0], arrays[1], arrays[2], arrays[3], arrays[4], arrays[5]))
print("evaluating", len(combos), "configs over", len(SESSIONS), "sessions...")

results = []
for vals in combos:
    p = dict(zip(keys, vals))
    cfg = make_cfg(p["window"], p["enter"], p["enter"] + 0.3, p["floor"],
                   p["min_still"], p["max_still"], p["refr"])
    m = run_config(cfg)
    results.append((p, m))

results.sort(key=lambda x: x[1]["f1"], reverse=True)
print()
print("=== top 12 by F1 ===")
print("params                              F1     P      R      exact  w1     FP")
for p, m in results[:12]:
    ps = "w=%.1f en=%.2f fl=%.1f ms=%.1f" % (p["window"], p["enter"], p["floor"], p["min_still"])
    print("%-34s  %.3f  %.3f  %.3f  %.2f   %.2f   %d" % (
        ps, m["f1"], m["prec"], m["rec"], m["exact"], m["within1"], m["fp"]))

print()
print("=== top 8 by lap-count exact-match ===")
results.sort(key=lambda x: (x[1]["exact"], x[1]["f1"]), reverse=True)
for p, m in results[:8]:
    ps = "w=%.1f en=%.2f fl=%.1f ms=%.1f" % (p["window"], p["enter"], p["floor"], p["min_still"])
    print("%-34s  exact=%.2f  F1=%.3f  P=%.3f  R=%.3f" % (
        ps, m["exact"], m["f1"], m["prec"], m["rec"]))
