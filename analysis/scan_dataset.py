"""Scan every session, build a manifest, and print aggregate turn statistics."""
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import dataio  # noqa: E402

rows = []
for s in dataio.list_sessions():
    d = dataio.load_session(s["path"])
    label = d["label"]
    n = len(label)
    dur = d["t"][-1] - d["t"][0] if n > 1 else 0.0
    turns = dataio.find_segments(label, 5)
    turn_lens = np.array([t[2] for t in turns]) if turns else np.array([0])
    rows.append({
        "swimmer": s["swimmer"],
        "style": s["style"],
        "epoch_ms": s["epoch_ms"],
        "n_rows": n,
        "dur_s": round(dur, 1),
        "n_turns": len(turns),
        "turn_len_med_samp": int(np.median(turn_lens)) if turns else 0,
        "turn_len_min_samp": int(turn_lens.min()) if turns else 0,
        "turn_len_max_samp": int(turn_lens.max()) if turns else 0,
        "frac_null": round(float((label == 0).mean()), 3),
        "frac_free": round(float((label == 1).mean()), 3),
        "frac_turn": round(float((label == 5).mean()), 3),
    })

man = pd.DataFrame(rows)
out = os.path.join(os.path.dirname(__file__), "session_manifest.csv")
man.to_csv(out, index=False)
print("wrote", out, "with", len(man), "sessions")
print()

print("=== sessions & turns by style ===")
g = man.groupby("style").agg(
    n_sessions=("swimmer", "size"),
    n_swimmers=("swimmer", "nunique"),
    total_turns=("n_turns", "sum"),
    med_turns_per_session=("n_turns", "median"),
    total_dur_min=("dur_s", lambda x: round(x.sum() / 60.0, 1)),
)
print(g)
print()

print("=== Freestyle focus ===")
fs = man[man["style"] == "Freestyle"]
print("sessions:", len(fs), " swimmers:", fs["swimmer"].nunique())
print("total turns:", int(fs["n_turns"].sum()))
print("turns per session: min/median/max =",
      int(fs["n_turns"].min()), int(fs["n_turns"].median()), int(fs["n_turns"].max()))
print("sessions with 0 turns:", int((fs["n_turns"] == 0).sum()))
print()

# Aggregate turn-length distribution across all freestyle turns (in seconds)
all_turn_lens = []
for s in dataio.list_sessions(style="Freestyle"):
    d = dataio.load_session(s["path"])
    for (_a, _b, ln) in dataio.find_segments(d["label"], 5):
        all_turn_lens.append(ln / dataio.FS_HZ)
all_turn_lens = np.array(all_turn_lens)
print("Freestyle turn segment length (s):")
for p in [0, 5, 25, 50, 75, 95, 100]:
    print("  p%3d = %.2f" % (p, np.percentile(all_turn_lens, p)))
print("  mean = %.2f  n = %d" % (all_turn_lens.mean(), len(all_turn_lens)))
print()

print("=== null fraction by style (median over sessions) ===")
print(man.groupby("style")["frac_null"].median())
