"""Data loading utilities for the Brunner swimming dataset.

The dataset lives under data/brunner/data/processed_30hz_relabeled/<swimmer_id>/
with one CSV per session, named <Style>_<epoch_ms>.csv. Resampled at 30 Hz.

Columns of interest:
  timestamp : nanoseconds of watch uptime
  ACC_0/1/2 : accelerometer X/Y/Z   (Android TYPE_ACCELEROMETER, includes gravity)
  GYRO_0/1/2: gyroscope X/Y/Z
  ACC_012   : precomputed L2 norm of (ACC_0, ACC_1, ACC_2)
  GYRO_012  : precomputed L2 norm of (GYRO_0, GYRO_1, GYRO_2)
  label     : 0=null, 1=freestyle, 2=breaststroke, 3=backstroke, 4=butterfly, 5=turn

This module deliberately depends only on numpy/pandas and returns plain numpy
arrays, so downstream detector code stays close to what is portable to C.
"""
import os
import glob

import numpy as np
import pandas as pd

FS_HZ = 30.0  # dataset sampling rate (resampled)

LABEL_NAMES = {
    0: "null",
    1: "freestyle",
    2: "breaststroke",
    3: "backstroke",
    4: "butterfly",
    5: "turn",
}
STYLE_TO_LABEL = {
    "Freestyle": 1,
    "Breaststroke": 2,
    "Backstroke": 3,
    "Butterfly": 4,
}

DATA_ROOT = os.path.join("data", "brunner", "data", "processed_30hz_relabeled")


def list_sessions(root=DATA_ROOT, style=None):
    """Return a list of session dicts: {swimmer, style, epoch_ms, path}.

    style: optional filter, e.g. "Freestyle". If None, return all.
    """
    sessions = []
    for swimmer in sorted(os.listdir(root), key=_int_key):
        sdir = os.path.join(root, swimmer)
        if not os.path.isdir(sdir):
            continue
        for path in sorted(glob.glob(os.path.join(sdir, "*.csv"))):
            base = os.path.basename(path)
            name = base[:-4]  # strip .csv
            parts = name.rsplit("_", 1)
            st = parts[0]
            epoch = parts[1] if len(parts) > 1 else ""
            if style is not None and st != style:
                continue
            sessions.append({
                "swimmer": swimmer,
                "style": st,
                "epoch_ms": epoch,
                "path": path,
            })
    return sessions


def _int_key(s):
    try:
        return (0, int(s))
    except ValueError:
        return (1, s)


def load_session(path):
    """Load one session CSV into a dict of numpy arrays.

    Returns:
      t       : float64[N] time in seconds, zero-based (from uptime ns)
      acc     : float64[N,3] accelerometer xyz
      gyro    : float64[N,3] gyroscope xyz
      acc_norm: float64[N] L2 norm of acc (uses precomputed ACC_012)
      gyro_norm: float64[N] L2 norm of gyro
      label   : int8[N] ground-truth class
      fs      : sampling rate (Hz)
    """
    df = pd.read_csv(path)
    ts_ns = df["timestamp"].to_numpy(dtype=np.float64)
    t = (ts_ns - ts_ns[0]) / 1e9
    acc = df[["ACC_0", "ACC_1", "ACC_2"]].to_numpy(dtype=np.float64)
    gyro = df[["GYRO_0", "GYRO_1", "GYRO_2"]].to_numpy(dtype=np.float64)
    if "ACC_012" in df.columns:
        acc_norm = df["ACC_012"].to_numpy(dtype=np.float64)
    else:
        acc_norm = np.sqrt(np.square(acc).sum(axis=1))
    if "GYRO_012" in df.columns:
        gyro_norm = df["GYRO_012"].to_numpy(dtype=np.float64)
    else:
        gyro_norm = np.sqrt(np.square(gyro).sum(axis=1))
    label = df["label"].to_numpy()
    label = np.nan_to_num(label, nan=0.0).astype(np.int8)
    return {
        "t": t,
        "acc": acc,
        "gyro": gyro,
        "acc_norm": acc_norm,
        "gyro_norm": gyro_norm,
        "label": label,
        "fs": FS_HZ,
        "path": path,
    }


def find_segments(label, value):
    """Find contiguous runs where label == value.

    Returns list of (start_idx, end_idx_inclusive, length).
    """
    segs = []
    n = len(label)
    i = 0
    while i < n:
        if label[i] == value:
            j = i
            while j < n and label[j] == value:
                j += 1
            segs.append((i, j - 1, j - i))
            i = j
        else:
            i += 1
    return segs


def segment_centers(segments):
    """Center index of each (start, end, length) segment."""
    return [(s + e) // 2 for (s, e, _ln) in segments]
