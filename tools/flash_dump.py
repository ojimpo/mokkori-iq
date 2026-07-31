#!/usr/bin/env python3
"""Drive the XIAO nRF52840 Sense flash-logger (firmware/flash_logger) over USB.

The logger boots into CONSOLE mode when plugged into USB and accepts:
    INFO | DUMP | TIMES | TIME <epoch> | ERASE | TESTLOG <sec> | VIB | HELP
This host tool issues those commands, and for DUMP it reads the raw int16
stream back and converts to g / deg-per-second using the scales the firmware
reports via INFO.

Time anchors ("sample K was taken at epoch E") are written alongside the CSV as
`<name>.anchors.json` rather than as an extra CSV column, because the column
layout `idx,t,ax..gz` is a contract with the app's int16 codec (MokkoriCore
RawRecording reads exactly 8 columns) and the Phase 0 loader.

Usage:
    python tools/flash_dump.py --info
    python tools/flash_dump.py --times          # list the recorded anchors
    python tools/flash_dump.py --set-time       # anchor "now" onto the log
    python tools/flash_dump.py --erase
    python tools/flash_dump.py --testlog 5
    python tools/flash_dump.py --dump -o session.csv
    python tools/flash_dump.py --selftest 5        # erase+testlog+dump+report
"""
import argparse
import datetime
import glob
import json
import math
import os
import statistics as st
import struct
import sys
import time

import serial  # pyserial

# LSM6DS3 sensitivities (datasheet): accel = fs/32768 g/LSB; gyro from table.
GYRO_SENS_DPS = {125: 4.375e-3, 250: 8.75e-3, 500: 17.5e-3,
                 1000: 35e-3, 2000: 70e-3}


def autodetect_port():
    # macOS exposes the CDC port as /dev/cu.usbmodem*, Linux as /dev/ttyACM*.
    for pat in ("/dev/cu.usbmodem*", "/dev/tty.usbmodem*", "/dev/ttyACM*"):
        ports = sorted(glob.glob(pat))
        if ports:
            return ports[0]
    return None


def open_port(port, baud):
    for _ in range(10):
        try:
            return serial.Serial(port, baud, timeout=1.0)
        except serial.SerialException:
            time.sleep(0.5)
    sys.exit(f"could not open {port}")


def read_until(ser, sentinel, timeout_s):
    """Read text lines until one starts with `sentinel`. Returns the lines."""
    deadline = time.monotonic() + timeout_s
    lines = []
    while time.monotonic() < deadline:
        raw = ser.readline().decode("ascii", "replace").strip()
        if not raw:
            continue
        lines.append(raw)
        if raw.startswith(sentinel):
            return lines
    raise TimeoutError(f"timed out waiting for '{sentinel}'")


def read_exact(ser, n, timeout_s):
    deadline = time.monotonic() + timeout_s
    buf = bytearray()
    while len(buf) < n and time.monotonic() < deadline:
        chunk = ser.read(n - len(buf))
        if chunk:
            buf.extend(chunk)
    if len(buf) != n:
        raise TimeoutError(f"got {len(buf)}/{n} bytes")
    return bytes(buf)


def parse_info(lines):
    """Pull odr_hz / accel_fs_g / gyro_fs_dps / samples out of INFO output."""
    info = {}
    for ln in lines:
        for tok in ln.replace("#", "").split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                try:
                    info[k] = int(v)
                except ValueError:
                    try:
                        info[k] = float(v)
                    except ValueError:
                        info[k] = v
    return info


def format_battery(info):
    """One-line human-friendly battery summary, or None if INFO had no battery."""
    if "vbat_mv" not in info:
        return None
    mv = info["vbat_mv"]
    pct = info.get("pct", "?")
    state = "charging" if info.get("charging") else "on USB (full)"
    return f"battery: {mv} mV  ~{pct}%  ({state})"


def cmd_info(ser, echo=True):
    ser.reset_input_buffer()
    ser.write(b"INFO\n")
    lines = read_until(ser, "OK", 10)
    if echo:
        for ln in lines:
            print(ln)
    info = parse_info(lines)
    if echo:
        batt = format_battery(info)
        if batt:
            print(batt)
    return info


def cmd_times(ser, echo=True):
    """Read the time anchors: [{epoch_ms, sample_index, millis}, ...]."""
    ser.reset_input_buffer()
    ser.write(b"TIMES\n")
    anchors = []
    for ln in read_until(ser, "OK", 15):
        if not ln.startswith("TIME "):
            continue
        a = {}
        for tok in ln[5:].split():
            k, _, v = tok.partition("=")
            a[k] = int(v)
        anchors.append(a)
        if echo:
            when = datetime.datetime.fromtimestamp(a["epoch_ms"] / 1000)
            print(f"anchor: sample {a['sample_index']} = {when:%Y-%m-%d %H:%M:%S.%f}"[:-3])
    if echo and not anchors:
        print("no time anchors (the device clock was never set)")
    return anchors


def cmd_set_time(ser):
    """Anchor the current host clock onto the log. The device has no RTC across
    a power cycle, so this is what makes absolute timestamps possible at all."""
    now = time.time()
    ser.reset_input_buffer()
    ser.write(f"TIME {now:.3f}\n".encode())
    print("\n".join(read_until(ser, "OK", 10)))
    print(f"anchored {datetime.datetime.fromtimestamp(now):%Y-%m-%d %H:%M:%S}")


def save_anchors(anchors, odr, csv_path):
    """Sidecar next to the CSV. Keeping it out of the CSV means the existing
    8-column contract (and everything that parses it) is untouched."""
    if not anchors:
        return
    path = os.path.splitext(csv_path)[0] + ".anchors.json"
    with open(path, "w") as f:
        json.dump({"odr_hz": odr, "anchors": anchors}, f, indent=2)
    first = anchors[0]
    start = (first["epoch_ms"] - first["sample_index"] * 1000 / odr) / 1000
    print(f"saved {len(anchors)} time anchor(s) -> {path}")
    print(f"  sample 0 = {datetime.datetime.fromtimestamp(start):%Y-%m-%d %H:%M:%S}")


def cmd_erase(ser):
    ser.reset_input_buffer()
    ser.write(b"ERASE\n")
    lines = read_until(ser, "ERASED", 40)   # chip erase can take many seconds
    print("\n".join(lines))


def cmd_testlog(ser, sec):
    ser.reset_input_buffer()
    ser.write(f"TESTLOG {sec}\n".encode())
    # firmware erases (slow) then logs `sec` s then prints INFO ending in OK
    lines = read_until(ser, "OK", sec + 45)
    for ln in lines:
        print(ln)
    return parse_info(lines)


def cmd_dump(ser, info):
    ser.reset_input_buffer()
    ser.write(b"DUMP\n")
    begin = read_until(ser, "DUMP_BEGIN", 15)[-1]
    parts = begin.split()
    nsamples = int(parts[1])
    bps = int(parts[2]) if len(parts) > 2 else 12
    raw = read_exact(ser, nsamples * bps, 30 + nsamples / 2000)
    read_until(ser, "DUMP_END", 10)

    a_sens = info.get("accel_fs_g", 8) / 32768.0
    g_sens = GYRO_SENS_DPS.get(int(info.get("gyro_fs_dps", 2000)), 70e-3)
    rows = []
    for i in range(nsamples):
        ax, ay, az, gx, gy, gz = struct.unpack_from("<6h", raw, i * 12)
        rows.append((ax * a_sens, ay * a_sens, az * a_sens,
                     gx * g_sens, gy * g_sens, gz * g_sens))
    return rows


def summarize(rows, odr):
    n = len(rows)
    if n == 0:
        print("no samples")
        return
    print(f"\nsamples: {n}   duration: {n / odr:.2f}s @ {odr}Hz")
    names = ["ax", "ay", "az", "gx", "gy", "gz"]
    print(f"{'chan':>6} {'min':>10} {'max':>10} {'mean':>10}")
    for j, name in enumerate(names):
        col = [r[j] for r in rows]
        print(f"{name:>6} {min(col):10.3f} {max(col):10.3f} {st.fmean(col):10.3f}")
    mags = [math.sqrt(r[0] ** 2 + r[1] ** 2 + r[2] ** 2) for r in rows]
    print(f"\n|acc| mean: {st.fmean(mags):.3f} g (expect ~1.0 at rest)")


def save_csv(rows, odr, path):
    with open(path, "w") as f:
        f.write("idx,t,ax,ay,az,gx,gy,gz\n")
        for i, r in enumerate(rows):
            f.write(f"{i},{i / odr:.4f}," + ",".join(f"{v:.5f}" for v in r) + "\n")
    print(f"saved {len(rows)} rows -> {path}")


def main():
    ap = argparse.ArgumentParser(description="XIAO flash-logger host tool.")
    ap.add_argument("-p", "--port", default=None)
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-o", "--out", default=None, help="CSV path for --dump/--selftest")
    ap.add_argument("--info", action="store_true")
    ap.add_argument("--times", action="store_true", help="list the time anchors")
    ap.add_argument("--set-time", action="store_true",
                    help="anchor the host clock onto the log (BLE does this too)")
    ap.add_argument("--erase", action="store_true")
    ap.add_argument("--testlog", type=int, metavar="SEC")
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--pull", nargs="?", const="__AUTO__", default=None,
                    metavar="PATH",
                    help="one swim: DUMP to CSV then ERASE. Omit PATH to "
                         "auto-name under data/swim/.")
    ap.add_argument("--selftest", type=int, metavar="SEC",
                    help="erase, log SEC s, dump and report (bench round-trip)")
    args = ap.parse_args()

    port = args.port or autodetect_port()
    if not port:
        sys.exit("no usbmodem serial port found")
    ser = open_port(port, args.baud)
    time.sleep(0.3)

    if args.pull is not None:
        path = args.pull
        if path == "__AUTO__":
            stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            path = os.path.join("data", "swim", f"swim_{stamp}.csv")
        info = cmd_info(ser, echo=False)
        rows = cmd_dump(ser, info)
        anchors = cmd_times(ser, echo=False)
        odr = int(info.get("odr_hz", 52))
        if not rows:
            print("# no data on device -- nothing to pull (device left as-is)")
            return
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        save_csv(rows, odr, path)
        save_anchors(anchors, odr, path)
        cmd_erase(ser)
        summarize(rows, odr)
        print(f"# pulled {len(rows)} samples and erased device")
        return

    if args.selftest is not None:
        print(f"# self-test on {port}: erase -> testlog {args.selftest}s -> dump")
        cmd_erase(ser)
        info = cmd_testlog(ser, args.selftest)
        rows = cmd_dump(ser, info)
        odr = int(info.get("odr_hz", 52))
        summarize(rows, odr)
        if args.out:
            save_csv(rows, odr, args.out)
        return

    if args.set_time:
        cmd_set_time(ser)
    if args.erase:
        cmd_erase(ser)
    if args.testlog is not None:
        cmd_testlog(ser, args.testlog)
    if args.times:
        cmd_times(ser)
    if args.info or not (args.erase or args.times or args.set_time
                         or args.testlog is not None or args.dump):
        info = cmd_info(ser)
    if args.dump:
        info = cmd_info(ser, echo=False)
        rows = cmd_dump(ser, info)
        anchors = cmd_times(ser, echo=False)
        odr = int(info.get("odr_hz", 52))
        summarize(rows, odr)
        if args.out:
            save_csv(rows, odr, args.out)
            save_anchors(anchors, odr, args.out)


if __name__ == "__main__":
    main()
