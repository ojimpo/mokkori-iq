"""Can the device record 2 hours at 52Hz if it compresses as it writes?

Dropping to 13Hz would fit, but it throws the high-frequency content away for
good, which fights the "keep the raw data so a better detector can reprocess
old sessions" policy. Compression keeps every bit instead -- if it fits.

The budget, from the flash we actually have:

    2MB / (7200s * 52Hz) = 5.60 bytes per sample

against 12 bytes raw (6 axes * int16), so we need **2.14x lossless**. This
script measures what the real captures actually give, for schemes that a
Cortex-M4 can run in the write path:

  raw        12 B/sample, what we store today (plus page header = 12.8)
  delta-fix  first-order delta, one fixed bit width per axis per page
  delta2-fix second-order delta (the signal is smooth, so this is often tighter)
  varint     zigzag varint on first-order deltas (byte-aligned, simplest to code)

Every scheme is measured **per 256-byte page, self-contained** (each page
re-anchors with one absolute sample), because that is what makes a half-written
flash still readable -- the property the current format has and must keep.

    .venv/bin/python analysis/compress_check.py
"""
import os
import sys

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SESSIONS = ["swim_20260621_171349.csv", "swim_20260728_153415.csv"]

ACC_SENS = 8.0 / 32768.0        # g/LSB   (±8g)
GYRO_SENS = 70e-3               # dps/LSB (±2000dps)

FLASH_BYTES = 2 * 1024 * 1024
PAGE = 256
ODR = 52.0
TARGET_SECONDS = 7200.0         # 市民プールの2時間枠


def raw_int16(path: str) -> np.ndarray:
    """CSV（g / dps）から本体が書いている int16 を復元する。"""
    df = pd.read_csv(path)
    acc = df[["ax", "ay", "az"]].to_numpy(dtype=np.float64) / ACC_SENS
    gyro = df[["gx", "gy", "gz"]].to_numpy(dtype=np.float64) / GYRO_SENS
    v = np.concatenate([acc, gyro], axis=1)
    return np.rint(v).astype(np.int64)


def bits_for(values: np.ndarray) -> int:
    """符号付き値をそのまま入れるのに要るビット幅。"""
    if values.size == 0:
        return 1
    m = int(np.abs(values).max())
    return max(1, int(m).bit_length() + 1)     # +1 は符号ぶん


def pack_fixed(v: np.ndarray, order: int, samples_per_page: int) -> float:
    """ページごとに「軸ごと固定ビット幅」で詰めたときの bytes/sample。
    ページ先頭は必ず絶対値（＋2次差分なら2サンプル）で再アンカーする。"""
    anchor = 1 if order == 1 else 2
    total_bytes = 0.0
    total_samples = 0
    for s in range(0, len(v) - samples_per_page, samples_per_page):
        blk = v[s:s + samples_per_page]
        d = np.diff(blk, n=order, axis=0)
        # ヘッダ: magic/seq 4B + 軸ごとのビット幅 6 x 4bit = 3B
        bits = 8 * (4 + 3 + 2 * 6 * anchor)
        for ax in range(6):
            bits += bits_for(d[:, ax]) * d.shape[0]
        total_bytes += np.ceil(bits / 8)
        total_samples += samples_per_page
    return total_bytes / total_samples if total_samples else float("nan")


def pack_varint(v: np.ndarray, samples_per_page: int) -> float:
    """1次差分 → zigzag varint（7bit/byte）。バイト境界なので実装が一番楽。"""
    total_bytes = 0.0
    total_samples = 0
    for s in range(0, len(v) - samples_per_page, samples_per_page):
        blk = v[s:s + samples_per_page]
        d = np.diff(blk, axis=0)
        z = (d << 1) ^ (d >> 63)                       # zigzag
        n = np.where(z < 128, 1, np.where(z < 16384, 2, 3))
        total_bytes += 4 + 12 + int(n.sum())           # ヘッダ + 絶対1サンプル
        total_samples += samples_per_page
    return total_bytes / total_samples if total_samples else float("nan")


def entropy_bits(values: np.ndarray) -> float:
    """差分値の実測エントロピー = どんな可逆方式でも下回れない床（bit/値）。"""
    _, counts = np.unique(values, return_counts=True)
    p = counts / counts.sum()
    return float(-(p * np.log2(p)).sum())


def rice_bits(u: np.ndarray, k: int) -> int:
    """Rice(Golomb) 符号のビット数。商を unary + 下位 k bit。
    ラプラス分布に近い差分にはほぼ最適で、テーブル不要なので M4 でも軽い。"""
    return int((u >> k).sum() + len(u) * (1 + k))


def pack_rice(v: np.ndarray, samples_per_page: int, drop_bits: int = 0) -> float:
    """1次差分 → zigzag → Rice。k はページ・軸ごとに最良のものを選ぶ（4bitで記録）。
    `drop_bits` は下位ビットの切り捨て量（センサのノイズ床より下は捨てる）。"""
    total_bytes = 0.0
    total_samples = 0
    for s in range(0, len(v) - samples_per_page, samples_per_page):
        blk = v[s:s + samples_per_page] >> drop_bits
        d = np.diff(blk, axis=0)
        bits = 8 * (4 + 3 + 12)                # ヘッダ + k×6 + 絶対1サンプル
        for ax in range(6):
            u = (d[:, ax] << 1) ^ (d[:, ax] >> 63)
            bits += min(rice_bits(u, k) for k in range(0, 14))
        total_bytes += np.ceil(bits / 8)
        total_samples += samples_per_page
    return total_bytes / total_samples if total_samples else float("nan")


def report(label: str, bps: float) -> None:
    secs = FLASH_BYTES / bps / ODR
    ok = "  ← 2時間に届く" if secs >= TARGET_SECONDS else ""
    print(f"  {label:<26} {bps:5.2f} B/sample  {secs/60:5.0f}分{ok}")


def main():
    need = FLASH_BYTES / (TARGET_SECONDS * ODR)
    print(f"52Hz で2時間 = {int(TARGET_SECONDS*ODR):,} サンプル")
    print(f"→ 予算 {need:.2f} B/sample（生 12 B に対して {12/need:.2f}倍の圧縮が要る）\n")

    for name in SESSIONS:
        path = os.path.join(ROOT, "data", "swim", name)
        if not os.path.exists(path):
            print(f"SKIP {name}")
            continue
        v = raw_int16(path)
        print(f"=== {name} ({len(v):,} samples) ===")
        report("raw（現行・ヘッダ込み）", PAGE / 20)
        for spp in (20, 40, 60):
            report(f"1次差分・固定幅 {spp}/page", pack_fixed(v, 1, spp))
        for spp in (20, 40, 60):
            report(f"2次差分・固定幅 {spp}/page", pack_fixed(v, 2, spp))
        report("1次差分・zigzag varint", pack_varint(v, 40))
        for spp in (40, 80):
            report(f"1次差分・Rice {spp}/page", pack_rice(v, spp))
        for drop in (1, 2, 3):
            report(f"Rice + 下位{drop}bit切り捨て", pack_rice(v, 80, drop))

        d0 = np.diff(v, axis=0)
        ent = sum(entropy_bits(d0[:, a]) for a in range(6))
        print(f"  可逆の理論下限（1次差分の実測エントロピー）: "
              f"{ent:.1f} bit/sample = {ent/8:.2f} B/sample "
              f"→ {FLASH_BYTES/(ent/8)/ODR/60:.0f}分")

        d = np.diff(v, axis=0)
        print("  参考: 1次差分の絶対値 中央値 / 99% / 最大（軸順 ax,ay,az,gx,gy,gz）")
        print("    中央値 " + " ".join(f"{np.median(np.abs(d[:, a])):5.0f}" for a in range(6)))
        print("    99%    " + " ".join(f"{np.percentile(np.abs(d[:, a]), 99):5.0f}" for a in range(6)))
        print("    最大   " + " ".join(f"{np.abs(d[:, a]).max():5.0f}" for a in range(6)))
        print()


if __name__ == "__main__":
    main()
