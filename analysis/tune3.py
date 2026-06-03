"""Grid search including the CONFIRM (post-dip swim resumption) feature."""
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
            "within1": within1, "fp": fp, "fn": fn}


def make_cfg(window, enter, floor, min_still, confirm, spike_on):
    cfg = copy.deepcopy(base)
    cfg["preprocess"]["activity_window_s"] = window
    d = cfg["detector"]
    d["dip_enter_ratio"] = enter
    d["dip_exit_ratio"] = enter + 0.3
    d["dip_abs_floor"] = floor
    d["min_still_s"] = min_still
    d["max_still_s"] = 4.0
    d["refractory_s"] = 2.5
    d["confirm_swim_s"] = confirm
    d["confirm_timeout_s"] = 1.5
    d["require_spike"] = spike_on
    d["spike_abs"] = 20.0
    return cfg


windows = [1.4, 2.0]
floors = [1.8, 2.8]
min_stills = [0.6, 0.9]
confirms = [0.0, 0.6, 1.0]
spikes = [False, True]
enter = 0.35

combos = list(itertools.product(windows, floors, min_stills, confirms, spikes))
print("evaluating", len(combos), "configs...")

results = []
for (w, fl, ms, cf, sp) in combos:
    cfg = make_cfg(w, enter, fl, ms, cf, sp)
    m = run_config(cfg)
    p = {"w": w, "fl": fl, "ms": ms, "cf": cf, "sp": sp}
    results.append((p, m))


def fmt(p):
    return "w=%.1f fl=%.1f ms=%.1f cf=%.1f %s" % (
        p["w"], p["fl"], p["ms"], p["cf"], "spk" if p["sp"] else "noSpk")


results.sort(key=lambda x: x[1]["f1"], reverse=True)
print()
print("=== top 15 by F1 ===")
print("params                            F1     P      R      exact  w1     FP")
for p, m in results[:15]:
    print("%-32s   %.3f  %.3f  %.3f  %.2f   %.2f   %d" % (
        fmt(p), m["f1"], m["prec"], m["rec"], m["exact"], m["within1"], m["fp"]))

results.sort(key=lambda x: (x[1]["exact"], x[1]["f1"]), reverse=True)
print()
print("=== top 10 by lap-count exact ===")
print("params                            exact  w1     F1     P      R")
for p, m in results[:10]:
    print("%-32s   %.2f   %.2f   %.3f  %.3f  %.3f" % (
        fmt(p), m["exact"], m["within1"], m["f1"], m["prec"], m["rec"]))
