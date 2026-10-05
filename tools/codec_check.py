"""Exercise the firmware's on-flash codec on the host, against real sessions.

Builds firmware/flash_logger/log_codec.h into a shared library and runs both
captured pool sessions through the exact encode/decode the device will run,
mirroring the firmware's paging loop (fill a buffer, pack what fits into a
record, carry the remainder over).

Checks the two things that matter before flashing:
  1. every decoded sample equals (raw >> drop) << drop  -- bit-exact, so a
     dump is what the analysis pipeline expects, minus the discarded LSBs
  2. the achieved bytes/sample, i.e. how long we can actually record

    .venv/bin/python tools/codec_check.py            # the shipped settings
    .venv/bin/python tools/codec_check.py --sweep    # compare record sizes

The sweep is how MK_UNITS was chosen: the 24-byte header is the whole argument
for larger records, and the only cost is how many buffered samples a power cut
loses.
"""
import ctypes
import os
import subprocess
import sys
import tempfile

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SESSIONS = ["swim_20260621_171349.csv", "swim_20260728_153415.csv"]

ACC_SENS = 8.0 / 32768.0        # g/LSB   (±8g)
GYRO_SENS = 70e-3               # dps/LSB (±2000dps)

FLASH_BYTES = 2 * 1024 * 1024
ODR = 52.0
TARGET_MIN = 120                # 市民プールの2時間枠

_tmp = tempfile.mkdtemp(prefix="mkcodec_")


def build(units=None, max_samples=None, block=None):
    """log_codec.h をそのままビルドして ctypes で呼べるようにする。"""
    lib = os.path.join(_tmp, f"libmkcodec_{units}_{max_samples}_{block}.so")
    cmd = ["cc", "-O2", "-shared", "-fPIC", "-o", lib]
    for name, val in (("MK_UNITS", units), ("MK_MAX_SAMPLES", max_samples),
                      ("MK_BLOCK", block)):
        if val is not None:
            cmd.append(f"-D{name}={val}")
    cmd.append(os.path.join(HERE, "codec_shim.c"))
    subprocess.run(cmd, check=True)
    d = ctypes.CDLL(lib)
    d.mk_enc.restype = ctypes.c_int
    d.mk_enc.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_ushort,
                         ctypes.c_ushort, ctypes.c_ubyte]
    d.mk_dec.restype = ctypes.c_int
    d.mk_dec.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_ushort]
    return d


def raw_int16(path):
    """CSV（g / dps）から本体が書いている int16 を復元する。"""
    df = pd.read_csv(path)
    acc = df[["ax", "ay", "az"]].to_numpy(dtype=np.float64) / ACC_SENS
    gyro = df[["gx", "gy", "gz"]].to_numpy(dtype=np.float64) / GYRO_SENS
    v = np.concatenate([acc, gyro], axis=1)
    return np.rint(v).astype(np.int16)


def roundtrip(lib, v, drop):
    """ファームと同じ流れ（バッファに貯める → 入るだけ詰める → 残りは繰越）。
    戻り値は (デコード結果, 消費バイト数)。"""
    rec_bytes = lib.mk_rec_bytes()
    max_samples = lib.mk_max_samples()
    rec = ctypes.create_string_buffer(rec_bytes)
    out = (ctypes.c_int16 * (max_samples * 6))()
    decoded = np.empty_like(v)
    written = nrec = pos = 0
    while pos < len(v):
        blk = np.ascontiguousarray(v[pos:pos + max_samples])
        got = lib.mk_enc(rec, blk.ctypes.data, len(blk), nrec & 0xFFFF, drop)
        assert got >= 1, "encoder made no progress"
        back = lib.mk_dec(rec, out, max_samples)
        assert back == got, f"count mismatch {back} != {got}"
        decoded[written:written + got] = np.ctypeslib.as_array(out)[:got * 6].reshape(got, 6)
        written += got
        nrec += 1
        pos += got
    assert written == len(v)
    return decoded, nrec * rec_bytes


def sessions():
    for name in SESSIONS:
        path = os.path.join(ROOT, "data", "swim", name)
        if not os.path.exists(path):
            print(f"SKIP {name} (未取得)")
            continue
        yield name, raw_int16(path)


GRID = [(1, 120, 64), (2, 200, 64), (4, 384, 64), (8, 640, 64),   # record size
        (4, 256, 64), (4, 512, 64),                               # buffer cap
        (4, 384, 16), (4, 384, 32), (4, 384, 128)]                # k block


def sweep():
    """レコード長 × k ブロック長ごとの B/sample。
    レコードを伸ばすとヘッダ 24B が薄まり、k ブロックを縮めると符号が信号に追従する
    （どちらもタダではないのでこの表で釣り合いを見る）。"""
    data = list(sessions())
    print("レコード長 × k ブロックごとの記録可能時間\n")
    print(f"  {'レコード':>8} {'kブロック':>9} {'バッファ':>8} {'停電で失う':>10}   " +
          "  ".join(f"{n[5:13]:>16}" for n, _ in data))
    for units, max_samples, block in GRID:
        lib = build(units, max_samples, block)
        drop = lib.mk_drop_bits()
        cells = []
        for _, v in data:
            decoded, nbytes = roundtrip(lib, v, drop)
            assert np.array_equal(decoded, (v >> drop) << drop)
            bps = nbytes / len(v)
            cells.append(f"{bps:5.2f}B {FLASH_BYTES/bps/ODR/60:4.0f}分")
        print(f"  {units*256:>7}B {block:>9} {max_samples:>8} {max_samples/ODR:>9.1f}s   " +
              "  ".join(f"{c:>16}" for c in cells))
    print()


UNIT = 256
MAGIC_RAW, MAGIC_ANCHOR, MAGIC_RICE = 0xA55A, 0xA55B, 0xA55C


def image_check(lib, v, drop):
    """フラッシュ像として組み立ててから走査し直す。

    レコードが可変長になったので「ヘッダの長さを見て次へ飛ぶ」が新しく壊れうる点。
    時刻アンカー(256B)と旧形式の生ページ(256B)を同じ列に混ぜて、
    サンプル列が一切ずれないことを確かめる。"""
    rec_bytes = lib.mk_rec_bytes()
    max_samples = lib.mk_max_samples()
    rec = ctypes.create_string_buffer(rec_bytes)
    out = (ctypes.c_int16 * (max_samples * 6))()

    image = bytearray()
    pos = nrec = 0
    while pos < len(v):
        blk = np.ascontiguousarray(v[pos:pos + max_samples])
        got = lib.mk_enc(rec, blk.ctypes.data, len(blk), nrec & 0xFFFF, drop)
        image += rec.raw[:rec_bytes]
        pos += got
        nrec += 1
        if nrec == 2:                                  # 時刻アンカーを挟む
            anchor = bytearray(UNIT)
            anchor[0:2] = MAGIC_ANCHOR.to_bytes(2, "little")
            image += anchor
    # 旧ファームで録った生ページが先に居るケース
    legacy = bytearray(UNIT)
    legacy[0:2] = MAGIC_RAW.to_bytes(2, "little")
    legacy[2:4] = (20).to_bytes(2, "little")
    head = np.ascontiguousarray(v[:20]).tobytes()
    legacy[8:8 + len(head)] = head
    image = legacy + image

    got_samples = []
    addr = 0
    while addr + UNIT <= len(image):
        magic = int.from_bytes(image[addr:addr + 2], "little")
        if magic not in (MAGIC_RAW, MAGIC_ANCHOR, MAGIC_RICE):
            break
        step = UNIT if magic != MAGIC_RICE else max(1, image[addr + 7]) * UNIT
        n = lib.mk_dec(bytes(image[addr:addr + step]), out, max_samples)
        if n:
            got_samples.append(np.ctypeslib.as_array(out)[:n * 6].reshape(n, 6).copy())
        addr += step
    assert addr == len(image), f"走査が像を消化しきれていない {addr} != {len(image)}"

    back = np.concatenate(got_samples)
    expect = np.concatenate([v[:20], (v >> drop) << drop])   # 生ページは無圧縮
    return np.array_equal(back, expect), len(back)


def main():
    if "--sweep" in sys.argv:
        sweep()
        return 0

    lib = build()
    drop = lib.mk_drop_bits()
    print(f"codec: record={lib.mk_rec_bytes()}B  "
          f"buffer {lib.mk_max_samples()} samples  drop_bits={drop}\n")

    data = list(sessions())
    if len(data) != len(SESSIONS):
        print("FAIL: both original captured sessions are required; no empty/partial PASS")
        return 1
    ok = True
    for name, v in data:
        decoded, nbytes = roundtrip(lib, v, drop)
        expect = (v >> drop) << drop
        exact = np.array_equal(decoded, expect)
        err = int(np.abs(decoded.astype(np.int32) - v).max())
        bps = nbytes / len(v)
        minutes = FLASH_BYTES / bps / ODR / 60

        print(f"=== {name} ({len(v):,} samples) ===")
        print(f"  往復  {'一致 (bit-exact)' if exact else '**不一致**'}"
              f"   生との最大差 {err} LSB（切り捨て {(1 << drop) - 1} 以内なら想定通り）")
        print(f"  {nbytes // lib.mk_rec_bytes():,} レコード = {bps:.2f} B/sample"
              f"（生 12.80 → {12.8 / bps:.2f}倍）")
        print(f"  記録可能  {minutes:.0f}分"
              f"{'  ← 2時間に届く' if minutes >= TARGET_MIN else '  ← 2時間に届かない'}")

        img_ok, ntotal = image_check(lib, v[:20000], drop)
        print(f"  フラッシュ像（アンカー・旧生ページ混在）を走査し直して "
              f"{'一致' if img_ok else '**不一致**'} ({ntotal:,} samples)\n")
        ok = ok and exact and img_ok and err < (1 << drop)

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
