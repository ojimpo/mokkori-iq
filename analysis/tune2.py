"""Refined grid search: adds kick-spike confirmation and wider ranges.

Same preload-once strategy as tune.py.
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

STYLE = "Freestyle"
print("preloading...")
SESSIONS = [dataio.load_session(s["path"]) for s in dataio.list_sessions(style=STYLE)]
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
            "within1": within1, "fp": fp, "fn": fn}


def make_cfg(window, enter, floor, min_still, spike_on, spike_abs):
    cfg = copy.deepcopy(base)
    cfg["preprocess"]["activity_window_s"] = window
    d = cfg["detector"]
    d["dip_enter_ratio"] = enter
    d["dip_exit_ratio"] = enter + 0.3
    d["dip_abs_floor"] = floor
    d["min_still_s"] = min_still
    d["max_still_s"] = 4.0
    d["refractory_s"] = 2.5
    d["require_spike"] = spike_on
    d["spike_abs"] = spike_abs
    return cfg


windows = [1.4, 1.8, 2.2]
enters = [0.3, 0.4]
floors = [1.8, 2.8]
min_stills = [0.9, 1.3]
spikes = [(False, 18.0), (True, 18.0), (True, 24.0)]

combos = list(itertools.product(windows, enters, floors, min_stills, spikes))
print("evaluating", len(combos), "configs...")

results = []
for (w, en, fl, ms, sp) in combos:
    cfg = make_cfg(w, en, fl, ms, sp[0], sp[1])
    m = run_config(cfg)
    p = {"w": w, "en": en, "fl": fl, "ms": ms, "spike": sp[0], "sp_abs": sp[1]}
    results.append((p, m))

def fmt(p):
    sp = "spk%d" % int(p["sp_abs"]) if p["spike"] else "noSpk"
    return "w=%.1f en=%.2f fl=%.1f ms=%.1f %s" % (p["w"], p["en"], p["fl"], p["ms"], sp)

results.sort(key=lambda x: x[1]["f1"], reverse=True)
print()
print("=== top 15 by F1 ===")
print("params                                 F1     P      R      exact  w1     FP")
for p, m in results[:15]:
    print("%-38s   %.3f  %.3f  %.3f  %.2f   %.2f   %d" % (
        fmt(p), m["f1"], m["prec"], m["rec"], m["exact"], m["within1"], m["fp"]))

results.sort(key=lambda x: (x[1]["exact"], x[1]["f1"]), reverse=True)
print()
print("=== top 10 by lap-count exact ===")
print("params                                 exact  w1     F1     P      R")
for p, m in results[:10]:
    print("%-38s   %.2f   %.2f   %.3f  %.3f  %.3f" % (
        fmt(p), m["exact"], m["within1"], m["f1"], m["prec"], m["rec"]))
