#!/usr/bin/env python3
"""Talk to the mokkori-iq logger over BLE from a laptop (firmware/flash_logger).

This exists so the firmware can be verified without the iPhone app in the
loop -- when something doesn't work, this tells you which side is wrong. It
speaks the same GATT the app does (docs/ble_time_sync_design.md):

    service  6D6B6F69-A55A-4000-8000-000000000001
      ...0002  write   8 B uint64 LE epoch_ms  -> appends a time anchor
      ...0003  read/notify  36 B status blob
      ...0004  notify  dump frames: u32 first sample index + N x 12 B samples,
                       terminated by a lone u32 0xFFFFFFFF
      ...0005  write   1 B opcode + args (erase / vibrate / haptics / dump)

Note: macOS only hands Bluetooth to a process whose responsible app has the
Bluetooth permission, so run this from Terminal.app (grant it under System
Settings > Privacy & Security > Bluetooth). Under a sandbox it reports
"Bluetooth device is turned off" even when the radio is on.

Usage:
    python tools/ble_probe.py --scan
    python tools/ble_probe.py --status
    python tools/ble_probe.py --sync            # set the device clock now
    python tools/ble_probe.py --vib 300 100
    python tools/ble_probe.py --pull out.csv    # dump over BLE (+ throughput)
    python tools/ble_probe.py --erase

macOS asks for Bluetooth permission the first time; grant it to the terminal
app or the scan silently returns nothing.
"""
import argparse
import asyncio
import datetime
import struct
import sys
import time

from bleak import BleakClient, BleakScanner

from flash_dump import save_csv

BASE = "6d6b6f69-a55a-4000-8000-0000000000{:02d}"
UUID_SVC = BASE.format(1)
UUID_TIME = BASE.format(2)
UUID_STATUS = BASE.format(3)
UUID_DATA = BASE.format(4)
UUID_CONTROL = BASE.format(5)

OP_ERASE, OP_VIB, OP_SET_HAPTIC = 0x01, 0x02, 0x03
OP_DUMP_START, OP_DUMP_STOP = 0x10, 0x11

FLAGS = [(0x01, "logging"), (0x02, "usb"), (0x04, "charging"), (0x08, "full"),
         (0x10, "erasing"), (0x20, "dumping"), (0x40, "imu_ok"),
         (0x80, "flash_ok")]

ACC_SENS = 8 / 32768.0
GYRO_SENS = 70e-3


def parse_status(b):
    """36-byte status blob -> dict. Extra trailing bytes are ignored on
    purpose: the firmware only ever appends fields, so a newer device stays
    readable by an older host."""
    if len(b) < 36:
        raise ValueError(f"short status: {len(b)} B")
    (ver, flags, odr, samples, capacity, vbat_mv, pct, haptic,
     anchor_epoch, anchor_idx, uptime, progress) = struct.unpack_from(
        "<BBHIIHBBQIII", b, 0)
    return dict(version=ver, flags=flags, odr=odr, samples=samples,
                capacity=capacity, vbat_mv=vbat_mv, pct=pct,
                haptic_strength=haptic, anchor_epoch_ms=anchor_epoch,
                anchor_index=anchor_idx, uptime_ms=uptime, progress=progress)


def show_status(s):
    on = " ".join(n for bit, n in FLAGS if s["flags"] & bit) or "-"
    secs = s["samples"] / s["odr"] if s["odr"] else 0
    left = (s["capacity"] - s["samples"]) / s["odr"] if s["odr"] else 0
    print(f"status v{s['version']}  flags: {on}")
    print(f"  recorded : {s['samples']} samples  {secs / 60:.1f} min @ {s['odr']}Hz")
    print(f"  free     : {left / 60:.1f} min  "
          f"({s['samples']}/{s['capacity']} = {100 * s['samples'] / max(1, s['capacity']):.1f}% used)")
    print(f"  battery  : {s['vbat_mv']} mV  ~{s['pct']}%")
    print(f"  uptime   : {s['uptime_ms'] / 1000:.1f}s   haptic strength "
          f"{s['haptic_strength']}%")
    if s["anchor_epoch_ms"]:
        when = datetime.datetime.fromtimestamp(s["anchor_epoch_ms"] / 1000)
        print(f"  anchor   : sample {s['anchor_index']} = {when:%Y-%m-%d %H:%M:%S}")
    else:
        print("  anchor   : none (clock never set)")


async def find_device(timeout=10.0):
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: UUID_SVC in [u.lower() for u in ad.service_uuids],
        timeout=timeout)
    if dev is None:
        sys.exit("no mokkori-iq device advertising "
                 "(is it powered? is Bluetooth permission granted?)")
    return dev


async def read_status(client):
    return parse_status(await client.read_gatt_char(UUID_STATUS))


async def do_pull(client, path):
    """Stream the log over notifications and write the same CSV the USB path
    produces, so everything downstream is unchanged."""
    st = await read_status(client)
    total = st["samples"]
    if total == 0:
        print("device has no data")
        return
    print(f"pulling {total} samples ({total * 12 / 1e6:.2f} MB of frames)")

    chunks = {}
    done = asyncio.Event()
    got = 0
    t0 = time.monotonic()

    def on_frame(_, data):
        nonlocal got
        (idx,) = struct.unpack_from("<I", data, 0)
        if idx == 0xFFFFFFFF:
            done.set()
            return
        body = data[4:]
        chunks[idx] = body
        got += len(body) // 12
        if got % 5000 < 20:
            el = time.monotonic() - t0
            print(f"  {got}/{total}  {got * 12 / el / 1024:.1f} kB/s", end="\r")

    await client.start_notify(UUID_DATA, on_frame)
    await client.write_gatt_char(UUID_CONTROL, struct.pack("<BI", OP_DUMP_START, 0),
                                 response=True)
    try:
        await asyncio.wait_for(done.wait(), timeout=60 + total / 200)
    except asyncio.TimeoutError:
        print(f"\ntimed out with {got}/{total} samples")
    await client.stop_notify(UUID_DATA)
    el = time.monotonic() - t0
    print(f"\ngot {got}/{total} samples in {el:.1f}s "
          f"({got * 12 / max(el, 1e-6) / 1024:.1f} kB/s)")

    # Reassemble in index order and check for gaps -- notifications are ordered
    # and reliable on the link layer, but a silent hole would corrupt the whole
    # session, so say so rather than write a plausible-looking CSV.
    rows, expect = [], 0
    for idx in sorted(chunks):
        if idx != expect:
            print(f"GAP at sample {expect} (next frame is {idx})")
        body = chunks[idx]
        for i in range(len(body) // 12):
            ax, ay, az, gx, gy, gz = struct.unpack_from("<6h", body, i * 12)
            rows.append((ax * ACC_SENS, ay * ACC_SENS, az * ACC_SENS,
                         gx * GYRO_SENS, gy * GYRO_SENS, gz * GYRO_SENS))
        expect = idx + len(body) // 12
    if path:
        save_csv(rows, st["odr"], path)


async def main():
    ap = argparse.ArgumentParser(description="mokkori-iq BLE host probe")
    ap.add_argument("--scan", action="store_true", help="list advertising devices")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--sync", action="store_true", help="write the current time")
    ap.add_argument("--erase", action="store_true")
    ap.add_argument("--vib", nargs="*", metavar="MS PCT", type=int)
    ap.add_argument("--haptic", nargs=4, metavar=("PCT", "M1", "M2", "M3"), type=int)
    ap.add_argument("--pull", nargs="?", const="__AUTO__", metavar="PATH")
    args = ap.parse_args()

    if args.scan:
        for d in await BleakScanner.discover(timeout=6.0):
            print(f"{d.address}  {d.name}")
        return

    dev = await find_device()
    print(f"connecting to {dev.name} ({dev.address})")
    async with BleakClient(dev) as client:
        if args.sync:
            epoch_ms = int(time.time() * 1000)
            await client.write_gatt_char(UUID_TIME, struct.pack("<Q", epoch_ms),
                                         response=True)
            print(f"wrote epoch_ms={epoch_ms} "
                  f"({datetime.datetime.now():%Y-%m-%d %H:%M:%S})")
            await asyncio.sleep(0.5)
        if args.vib is not None:
            ms = args.vib[0] if len(args.vib) > 0 else 300
            pct = args.vib[1] if len(args.vib) > 1 else 100
            await client.write_gatt_char(
                UUID_CONTROL, struct.pack("<BBBH", OP_VIB, pct, 1, ms), response=True)
            print(f"vibrate {ms}ms @ {pct}%")
        if args.haptic:
            pct, m1, m2, m3 = args.haptic
            await client.write_gatt_char(
                UUID_CONTROL, struct.pack("<BBHHH", OP_SET_HAPTIC, pct, m1, m2, m3),
                response=True)
            print(f"haptics: {pct}% {m1}/{m2}/{m3} m")
        if args.pull is not None:
            path = args.pull
            if path == "__AUTO__":
                stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
                path = f"data/swim/swim_{stamp}.csv"
            await do_pull(client, path)
        if args.erase:
            await client.write_gatt_char(UUID_CONTROL, bytes([OP_ERASE]),
                                         response=True)
            print("erase requested (chip erase takes a few seconds) ...")
            for _ in range(60):
                await asyncio.sleep(1.0)
                st = await read_status(client)
                if not st["flags"] & 0x10 and st["samples"] == 0:
                    break
            print("erased")
        show_status(await read_status(client))


if __name__ == "__main__":
    asyncio.run(main())
