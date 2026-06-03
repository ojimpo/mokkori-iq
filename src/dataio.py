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

G0 = 9.80665           # standard gravity: convert g -> m/s^2
DEG2RAD = np.pi / 180.0  # deg/s -> rad/s

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


def load_swim_csv(path, fs=None, to_si=True, gt_turns=None):
    """Load a mokkori flash-logger capture (tools/flash_dump.py CSV) into the
    same session dict shape as load_session(), so the Phase 0 pipeline applies.

    Our logger stores accel in g and gyro in deg/s; Brunner -- and therefore the
    detector thresholds (dip_abs_floor, spike_abs) -- use Android units, i.e.
    m/s^2 and rad/s. With to_si=True (default) we convert so the existing config
    and detector carry over directly. (Real device is crotch-mounted at ~52 Hz,
    vs Brunner's wrist at 30 Hz -- expect the morphology to differ.)

    path     : CSV with columns idx,t,ax,ay,az,gx,gy,gz
    fs       : sampling rate (Hz); if None, inferred from the median t step
    gt_turns : optional iterable of ground-truth turn times (s); the nearest
               sample to each is labelled 5 (turn) so evaluate.py can match
    """
    df = pd.read_csv(path)
    t = df["t"].to_numpy(dtype=np.float64)
    acc = df[["ax", "ay", "az"]].to_numpy(dtype=np.float64)
    gyro = df[["gx", "gy", "gz"]].to_numpy(dtype=np.float64)
    if to_si:
        acc = acc * G0
        gyro = gyro * DEG2RAD
    if fs is None:
        dt = np.diff(t)
        med = float(np.median(dt)) if len(dt) else 0.0
        fs = 1.0 / med if med > 0 else 52.0
    acc_norm = np.sqrt(np.square(acc).sum(axis=1))
    gyro_norm = np.sqrt(np.square(gyro).sum(axis=1))
    label = np.zeros(len(t), dtype=np.int8)
    if gt_turns is not None and len(t):
        for tt in gt_turns:
            label[int(np.argmin(np.abs(t - tt)))] = 5
    return {
        "t": t,
        "acc": acc,
        "gyro": gyro,
        "acc_norm": acc_norm,
        "gyro_norm": gyro_norm,
        "label": label,
        "fs": float(fs),
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
