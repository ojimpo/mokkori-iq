"""Focused grid: minimum lap interval (refractory) to kill burst false-fires."""
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

print("preloading...")
SESSIONS = [dataio.load_session(s["path"]) for s in dataio.list_sessions(style="Freestyle")]
print("loaded", len(SESSIONS))
base = pp.load_config()
tol = float(base["matching"]["tolerance_s"])


def run_config(cfg):
    detector = det_mod.TurnDetector(cfg)
    rows = [ev.evaluate_session(sess, detector, tol) for sess in SESSIONS]
    tp = sum(r["tp"] for r in rows)
    fp = sum(r["fp"] for r in rows)
    fn = sum(r["fn"] for r in rows)
    prec = tp / (tp + fp) if (tp + fp) else 0.0
    rec = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2.0 * prec * rec / (prec + rec) if (prec + rec) else 0.0
    exact = float(np.mean([r["count_exact"] for r in rows]))
    within1 = float(np.mean([r["count_within1"] for r in rows]))
    return {"prec": prec, "rec": rec, "f1": f1, "exact": exact,
            "within1": within1, "fp": fp, "fn": fn, "tp": tp}


def make_cfg(refr, floor, confirm, max_still):
    cfg = copy.deepcopy(base)
    d = cfg["detector"]
    d["refractory_s"] = refr
    d["dip_abs_floor"] = floor
    d["confirm_swim_s"] = confirm
    d["max_still_s"] = max_still
    return cfg


refrs = [2.5, 5.0, 7.0, 9.0, 12.0]
floors = [2.8, 3.5]
confirms = [0.6, 1.0]
max_stills = [4.0]

combos = list(itertools.product(refrs, floors, confirms, max_stills))
print("evaluating", len(combos), "configs...")
results = []
for (rf, fl, cf, mx) in combos:
    m = run_config(make_cfg(rf, fl, cf, mx))
    results.append(({"rf": rf, "fl": fl, "cf": cf, "mx": mx}, m))


def fmt(p):
    return "refr=%.1f fl=%.1f cf=%.1f" % (p["rf"], p["fl"], p["cf"])


results.sort(key=lambda x: x[1]["f1"], reverse=True)
print()
print("=== top by F1 ===")
print("params                    F1     P      R      exact  w1     FP")
for p, m in results[:12]:
    print("%-24s  %.3f  %.3f  %.3f  %.2f   %.2f   %d" % (
        fmt(p), m["f1"], m["prec"], m["rec"], m["exact"], m["within1"], m["fp"]))

results.sort(key=lambda x: (x[1]["exact"], x[1]["f1"]), reverse=True)
print()
print("=== top by lap-count exact ===")
for p, m in results[:8]:
    print("%-24s  exact=%.2f w1=%.2f  F1=%.3f P=%.3f R=%.3f" % (
        fmt(p), m["exact"], m["within1"], m["f1"], m["prec"], m["rec"]))
