"""Combine best settings from all rounds: window 2.0-2.2, enter 0.35-0.40,
refractory 9-12, confirm 0.6-1.0, floor 2.8 fixed."""
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
    det = det_mod.TurnDetector(cfg)
    rows = [ev.evaluate_session(sess, det, tol) for sess in SESSIONS]
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


def make_cfg(window, enter, refr, confirm):
    cfg = copy.deepcopy(base)
    cfg["preprocess"]["activity_window_s"] = window
    d = cfg["detector"]
    d["dip_enter_ratio"] = enter
    d["dip_exit_ratio"] = enter + 0.3
    d["dip_abs_floor"] = 2.8
    d["min_still_s"] = 0.6
    d["max_still_s"] = 4.0
    d["refractory_s"] = refr
    d["confirm_swim_s"] = confirm
    d["confirm_timeout_s"] = 1.5
    d["require_spike"] = False
    return cfg


windows = [2.0, 2.2]
enters = [0.35, 0.40]
refrs = [9.0, 12.0]
confirms = [0.6, 1.0]

combos = list(itertools.product(windows, enters, refrs, confirms))
print("evaluating", len(combos), "configs...")
results = []
for (w, en, rf, cf) in combos:
    m = run_config(make_cfg(w, en, rf, cf))
    results.append(({"w": w, "en": en, "rf": rf, "cf": cf}, m))


def fmt(p):
    return "w=%.1f en=%.2f rf=%.0f cf=%.1f" % (p["w"], p["en"], p["rf"], p["cf"])


results.sort(key=lambda x: x[1]["f1"], reverse=True)
print()
print("=== all by F1 ===")
print("params                       F1     P      R      exact  w1     FP   TP   FN")
for p, m in results:
    print("%-28s  %.3f  %.3f  %.3f  %.2f   %.2f   %3d  %3d  %3d" % (
        fmt(p), m["f1"], m["prec"], m["rec"], m["exact"], m["within1"],
        m["fp"], m["tp"], m["fn"]))
