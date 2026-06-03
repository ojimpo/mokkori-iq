"""Evaluation pipeline: turn detection + lap-log accuracy over the dataset.

Run:  python src/evaluate.py [--style Freestyle] [--config config/default.json]

Outputs (under results/):
  - per_session_<style>.csv   one row per session
  - per_subject_<style>.csv   aggregated by swimmer
  - prints aggregate metrics

Ground truth: each contiguous label==5 segment is one true turn, represented by
its (start, end, center) time. A detection (a point in time) is a true positive
if it lands inside [start - tol, end + tol] of an unused GT turn; matching is
greedy by distance to the window center (one detection per turn).
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import dataio  # noqa: E402
import detector as det_mod  # noqa: E402
import lap_logger  # noqa: E402
import preprocessing as pp  # noqa: E402


def gt_turn_windows(session):
    """List of (start_t, end_t, center_t) for each label==5 segment."""
    t = session["t"]
    segs = dataio.find_segments(session["label"], 5)
    out = []
    for (a, b, _ln) in segs:
        out.append((float(t[a]), float(t[b]), float(t[(a + b) // 2])))
    return out


def match(det_times, gt_windows, tol):
    """Greedy distance-minimizing match. Returns (matches, fp_idx, fn_idx).

    matches: list of (gt_idx, det_idx).
    """
    pairs = []
    for di, dt in enumerate(det_times):
        for gi, (s, e, c) in enumerate(gt_windows):
            if (s - tol) <= dt <= (e + tol):
                pairs.append((abs(dt - c), gi, di))
    pairs.sort()
    gt_taken = set()
    det_taken = set()
    matches = []
    for _dist, gi, di in pairs:
        if gi in gt_taken or di in det_taken:
            continue
        gt_taken.add(gi)
        det_taken.add(di)
        matches.append((gi, di))
    fp = [di for di in range(len(det_times)) if di not in det_taken]
    fn = [gi for gi in range(len(gt_windows)) if gi not in gt_taken]
    return matches, fp, fn


def evaluate_session(session, detector, tol):
    dets = detector.process(session)
    det_times = [d["t"] for d in dets]
    gt = gt_turn_windows(session)
    matches, fp, fn = match(det_times, gt, tol)

    # timing errors (signed: detection - gt_center)
    timing = []
    for (gi, di) in matches:
        timing.append(det_times[di] - gt[gi][2])

    # lap-time errors from consecutive GT turns that are both matched
    gt_match = {gi: di for (gi, di) in matches}
    lap_errs = []
    for gi in range(len(gt) - 1):
        if gi in gt_match and (gi + 1) in gt_match:
            gt_lap = gt[gi + 1][2] - gt[gi][2]
            det_lap = det_times[gt_match[gi + 1]] - det_times[gt_match[gi]]
            lap_errs.append(abs(det_lap - gt_lap))

    # cumulative drift across the session (first..last matched GT turn)
    drift = np.nan
    matched_gis = sorted(gt_match.keys())
    if len(matched_gis) >= 2:
        g0, g1 = matched_gis[0], matched_gis[-1]
        gt_span = gt[g1][2] - gt[g0][2]
        det_span = det_times[gt_match[g1]] - det_times[gt_match[g0]]
        drift = abs(det_span - gt_span)

    n_gt = len(gt)
    n_det = len(det_times)
    return {
        "n_gt_turns": n_gt,
        "n_det_turns": n_det,
        "tp": len(matches),
        "fp": len(fp),
        "fn": len(fn),
        "count_exact": int(n_det == n_gt),
        "count_within1": int(abs(n_det - n_gt) <= 1),
        "timing_err_s": timing,
        "lap_errs_s": lap_errs,
        "drift_s": drift,
        "lapcount_gt": lap_logger.n_lengths(n_gt),
        "lapcount_det": lap_logger.n_lengths(n_det),
    }


def evaluate_dataset(style, cfg):
    detector = det_mod.TurnDetector(cfg)
    tol = float(cfg["matching"]["tolerance_s"])
    rows = []
    all_timing = []
    all_lap_errs = []
    for s in dataio.list_sessions(style=style):
        session = dataio.load_session(s["path"])
        r = evaluate_session(session, detector, tol)
        all_timing.extend(r["timing_err_s"])
        all_lap_errs.extend(r["lap_errs_s"])
        rows.append({
            "swimmer": s["swimmer"],
            "style": s["style"],
            "epoch_ms": s["epoch_ms"],
            "n_gt_turns": r["n_gt_turns"],
            "n_det_turns": r["n_det_turns"],
            "tp": r["tp"], "fp": r["fp"], "fn": r["fn"],
            "count_exact": r["count_exact"],
            "count_within1": r["count_within1"],
            "drift_s": r["drift_s"],
            "lap_mae_s": float(np.mean(r["lap_errs_s"])) if r["lap_errs_s"] else np.nan,
        })
    df = pd.DataFrame(rows)
    agg = aggregate(df, all_timing, all_lap_errs)
    return df, agg


def aggregate(df, all_timing, all_lap_errs):
    tp = int(df["tp"].sum())
    fp = int(df["fp"].sum())
    fn = int(df["fn"].sum())
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
    timing = np.array(all_timing) if all_timing else np.array([np.nan])
    lap_errs = np.array(all_lap_errs) if all_lap_errs else np.array([np.nan])
    return {
        "n_sessions": len(df),
        "n_swimmers": df["swimmer"].nunique(),
        "tp": tp, "fp": fp, "fn": fn,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "timing_mean_s": float(np.nanmean(timing)),
        "timing_abs_med_s": float(np.nanmedian(np.abs(timing))),
        "timing_abs_p90_s": float(np.nanpercentile(np.abs(timing), 90)),
        "count_exact_rate": float(df["count_exact"].mean()),
        "count_within1_rate": float(df["count_within1"].mean()),
        "lap_time_mae_s": float(np.nanmean(lap_errs)),
        "drift_mean_s": float(np.nanmean(df["drift_s"].to_numpy())),
    }


def per_subject(df):
    g = df.groupby("swimmer").agg(
        n_sessions=("swimmer", "size"),
        gt_turns=("n_gt_turns", "sum"),
        det_turns=("n_det_turns", "sum"),
        tp=("tp", "sum"), fp=("fp", "sum"), fn=("fn", "sum"),
        count_exact_rate=("count_exact", "mean"),
    )
    g["recall"] = g["tp"] / (g["tp"] + g["fn"]).replace(0, np.nan)
    g["precision"] = g["tp"] / (g["tp"] + g["fp"]).replace(0, np.nan)
    g["f1"] = 2 * g["precision"] * g["recall"] / (g["precision"] + g["recall"])
    return g


def print_summary(style, agg):
    print("=" * 60)
    print("STYLE:", style)
    print("sessions: %d   swimmers: %d" % (agg["n_sessions"], agg["n_swimmers"]))
    print("-- turn detection --")
    print("TP=%d FP=%d FN=%d" % (agg["tp"], agg["fp"], agg["fn"]))
    print("Precision = %.3f" % agg["precision"])
    print("Recall    = %.3f" % agg["recall"])
    print("F1        = %.3f" % agg["f1"])
    print("timing error: mean=%.2fs  |median|=%.2fs  |p90|=%.2fs" % (
        agg["timing_mean_s"], agg["timing_abs_med_s"], agg["timing_abs_p90_s"]))
    print("-- lap log --")
    print("lap-count exact match : %.1f%%" % (100 * agg["count_exact_rate"]))
    print("lap-count within +-1  : %.1f%%" % (100 * agg["count_within1_rate"]))
    print("lap-time MAE          : %.2fs" % agg["lap_time_mae_s"])
    print("cumulative drift mean : %.2fs" % agg["drift_mean_s"])
    print("=" * 60)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", default="Freestyle")
    ap.add_argument("--config", default=None)
    ap.add_argument("--all-styles", action="store_true")
    args = ap.parse_args()

    cfg = pp.load_config(args.config)
    resdir = os.path.join(os.path.dirname(__file__), "..", "results")
    os.makedirs(resdir, exist_ok=True)

    styles = ["Freestyle", "Butterfly", "Backstroke", "Breaststroke"] if args.all_styles else [args.style]
    for style in styles:
        df, agg = evaluate_dataset(style, cfg)
        df.to_csv(os.path.join(resdir, "per_session_%s.csv" % style), index=False)
        per_subject(df).to_csv(os.path.join(resdir, "per_subject_%s.csv" % style))
        print_summary(style, agg)


if __name__ == "__main__":
    main()
