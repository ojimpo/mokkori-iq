#!/usr/bin/env python3
"""Capture / inspect the IMU CSV stream from the XIAO nRF52840 Sense.

The bring-up firmware (firmware/imu_bringup) streams lines of

    millis,ax,ay,az,gx,gy,gz

over USB CDC serial (accel in g, gyro in deg/s). This tool reads that stream,
echoes any '#' banner lines, and reports the effective sample rate plus
per-channel ranges so we can sanity-check the sensor and axis orientation.
Optionally saves the raw CSV for offline analysis.

Usage:
    python tools/serial_capture.py                      # 5 s, autodetect port
    python tools/serial_capture.py -s 20 -o cap.csv
    python tools/serial_capture.py -p /dev/cu.usbmodem112101
"""
import argparse
import glob
import math
import statistics as st
import sys
import time

import serial  # pyserial

COLS = ["millis", "ax", "ay", "az", "gx", "gy", "gz"]


def autodetect_port():
    for pat in ("/dev/cu.usbmodem*", "/dev/tty.usbmodem*"):
        ports = sorted(glob.glob(pat))
        if ports:
            return ports[0]
    return None


def main():
    ap = argparse.ArgumentParser(description="Capture XIAO IMU CSV stream.")
    ap.add_argument("-p", "--port", default=None,
                    help="serial port (autodetected if omitted)")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-s", "--seconds", type=float, default=5.0,
                    help="capture duration in seconds")
    ap.add_argument("-o", "--out", default=None, help="save captured CSV here")
    args = ap.parse_args()

    port = args.port or autodetect_port()
    if not port:
        sys.exit("no usbmodem serial port found")

    # The port may still be settling right after a flash -> retry the open.
    ser = None
    for _ in range(10):
        try:
            ser = serial.Serial(port, args.baud, timeout=1.0)
            break
        except serial.SerialException:
            time.sleep(0.5)
    if ser is None:
        sys.exit(f"could not open {port}")

    print(f"# reading {port} @ {args.baud} for {args.seconds:.1f}s ...",
          file=sys.stderr)

    rows = []
    t_end = time.monotonic() + args.seconds
    ser.readline()  # discard a possibly-partial first line
    while time.monotonic() < t_end:
        raw = ser.readline().decode("ascii", "replace").strip()
        if not raw:
            continue
        if raw.startswith("#"):
            print(raw, file=sys.stderr)
            continue
        parts = raw.split(",")
        if len(parts) != 7:
            continue
        try:
            rows.append([float(x) for x in parts])
        except ValueError:
            continue
    ser.close()

    if not rows:
        sys.exit("no valid samples parsed -- is the bring-up firmware flashed?")

    n = len(rows)
    dur_s = (rows[-1][0] - rows[0][0]) / 1000.0
    hz = (n - 1) / dur_s if dur_s > 0 else float("nan")
    print(f"\nsamples: {n}   span: {dur_s:.2f}s   effective rate: {hz:.1f} Hz")

    print(f"{'chan':>6} {'min':>10} {'max':>10} {'mean':>10}")
    for j, name in enumerate(COLS):
        if j == 0:
            continue
        col = [r[j] for r in rows]
        print(f"{name:>6} {min(col):10.3f} {max(col):10.3f} {st.fmean(col):10.3f}")

    mags = [math.sqrt(r[1] ** 2 + r[2] ** 2 + r[3] ** 2) for r in rows]
    print(f"\n|acc| mean: {st.fmean(mags):.3f} g (expect ~1.0 at rest)")

    if args.out:
        with open(args.out, "w") as f:
            f.write(",".join(COLS) + "\n")
            for r in rows:
                f.write(f"{int(r[0])}," +
                        ",".join(f"{v:.5f}" for v in r[1:]) + "\n")
        print(f"\nsaved {n} rows -> {args.out}")


if __name__ == "__main__":
    main()
