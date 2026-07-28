"""Would a lower sample rate still give the same swim report?

The flash holds 163,840 samples (2MB / 12.8 B per sample), so the recordable
time is just that divided by the rate: 52Hz -> 52min, 26Hz -> 105min,
13Hz -> 3h30m. A 2-hour session (typical municipal pool slot) needs <= 22.75Hz
with the current on-device format, i.e. **26Hz is not enough and 13Hz is**.

Before touching the firmware, decimate the real 52Hz captures and re-run the
whole report. If distance / walls / strokes hold up at 13Hz, the rate can drop.

    .venv/bin/python analysis/decimate_check.py

Two decimation methods, because they fail differently:
  mean : average each block of k samples. The averaging is a crude low-pass, so
         it suppresses the swim vibration that would otherwise fold down into
         the stroke band (0.3-1.2Hz). This is what firmware should do -- keep
         the IMU at 52Hz and average down.
  pick : take every k-th sample. This is what "just lower the ODR" looks like
         if the sensor's analog bandwidth stays wide. Shown to make the
         aliasing risk visible rather than assumed.
"""
import os
import re
import subprocess
import sys
import tempfile

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SESSIONS = ["swim_20260621_171349.csv", "swim_20260728_153415.csv"]
# 目標レート。52 は基準（間引かない）
RATES = [52, 26, 13]
# フラッシュ容量（実測で確定: 7/28 のセッションがちょうどこの数で満杯停止した）
CAPACITY_SAMPLES = 163_840


def decimate(df: pd.DataFrame, k: int, how: str) -> pd.DataFrame:
    """k サンプルを1つにまとめる。"""
    n = len(df) // k * k
    cols = ["t", "ax", "ay", "az", "gx", "gy", "gz"]
    a = df[cols].to_numpy(dtype=np.float64)[:n].reshape(-1, k, len(cols))
    out = a.mean(axis=1) if how == "mean" else a[:, 0, :]
    # 時刻だけは常にブロック先頭にそろえる（平均すると半サンプルぶん後ろにずれる）
    out[:, 0] = a[:, 0, 0]
    d = pd.DataFrame(out, columns=cols)
    d.insert(0, "idx", np.arange(len(d)))
    return d


def run_report(csv_path: str) -> dict:
    """swim_report をそのまま回して、出力から数値を拾う（regression_check と同じ流儀）。"""
    out = subprocess.run(
        [sys.executable, os.path.join(HERE, "swim_report.py"), csv_path],
        capture_output=True, text=True, cwd=ROOT).stdout

    sets = [(int(a), float(b)) for a, b in
            re.findall(r"^\s+(\d+)\s+(\d+)m\s", out, re.M)]
    dist = re.search(r"距離\s+(\d+) m", out)
    pace = re.search(r"平均ペース\s+(\S+) /100m", out)
    st = re.search(r"strokes: 中央値 (\d+)/ラップ .*合計 (\d+)\s+\((\d+)/(\d+)ラップ", out)
    swolf = re.search(r"swolf:\s+平均 (\d+)", out)
    cross = len(re.findall(r"CROSS-CHECK", out))
    return {
        "sets": [int(d) for _, d in sets],
        "distance": int(dist.group(1)) if dist else None,
        "pace": pace.group(1) if pace else None,
        "spl": int(st.group(1)) if st else None,
        "strokes": int(st.group(2)) if st else None,
        "laps": int(st.group(4)) if st else None,
        "swolf": int(swolf.group(1)) if swolf else None,
        "crosschecks": cross,
    }


def main():
    print("フラッシュ容量 %s サンプル → 記録可能時間" % f"{CAPACITY_SAMPLES:,}")
    for r in RATES:
        secs = CAPACITY_SAMPLES / r
        print(f"  {r:>2}Hz: {secs/60:5.0f}分" +
              ("  ← 2時間に届く" if secs >= 7200 else ""))
    print()

    tmp = tempfile.mkdtemp(prefix="decimate_")
    for name in SESSIONS:
        path = os.path.join(ROOT, "data", "swim", name)
        if not os.path.exists(path):
            print(f"SKIP {name}")
            continue
        df = pd.read_csv(path)
        base = None
        print(f"=== {name} ({len(df):,} samples) ===")
        print(f"{'rate':>6} {'方式':<5} {'距離':>7} {'セット':<12} "
              f"{'ラップ':>5} {'str':>5} {'中央値':>5} {'SWOLF':>5} {'CC':>3}")
        for rate in RATES:
            k = round(52 / rate)
            methods = ["mean"] if k == 1 else ["mean", "pick"]
            for how in methods:
                d = df if k == 1 else decimate(df, k, how)
                out_csv = os.path.join(tmp, f"{rate}_{how}_{name}")
                d.to_csv(out_csv, index=False,
                         float_format="%.5f", columns=["idx", "t", "ax", "ay",
                                                       "az", "gx", "gy", "gz"])
                res = run_report(out_csv)
                if base is None:
                    base = res
                flag = "" if res["distance"] == base["distance"] else "  ← 距離が変わる"
                print(f"{rate:>4}Hz {how:<5} {res['distance']:>6}m "
                      f"{str(res['sets']):<12} {res['laps']:>5} "
                      f"{res['strokes']:>5} {res['spl']:>5} {res['swolf']:>5} "
                      f"{res['crosschecks']:>3}{flag}")
        print()


if __name__ == "__main__":
    main()
