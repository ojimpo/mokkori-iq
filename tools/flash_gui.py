#!/usr/bin/env python3
"""Touch-friendly GUI for the XIAO nRF52840 flash-logger (pool-side capture).

A thin Tkinter front-end over tools/flash_dump.py for use on the Ubuntu tablet
at the poolside: plug the device in, tap one big button to pull a swim to CSV.

    .venv/bin/python tools/flash_gui.py

Three actions, mirroring the CLI:
    PULL  -> DUMP to data/swim/swim_<timestamp>.csv, then ERASE (one swim)
    INFO  -> show how much is currently recorded on the device
    ERASE -> wipe the flash (asks for confirmation first)

All serial work reuses flash_dump's functions and runs on a worker thread so
the UI never freezes. Needs python3-tk on Ubuntu (`sudo apt install python3-tk`).
"""
import contextlib
import datetime
import io
import math
import os
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import messagebox

import serial  # pyserial

# Reuse the CLI's serial logic instead of reimplementing it.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flash_dump as fd  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIM_DIR = os.path.join(REPO_ROOT, "data", "swim")

BG = "#1e1e1e"
FG = "#e0e0e0"
MUTED = "#9aa0a6"


def open_serial(port, baud=115200, attempts=8):
    """Like flash_dump.open_port but raises instead of sys.exit (GUI-friendly)."""
    last = None
    for _ in range(attempts):
        try:
            return serial.Serial(port, baud, timeout=1.0)
        except serial.SerialException as exc:
            last = exc
            time.sleep(0.4)
    raise last or serial.SerialException(f"could not open {port}")


class FlashGui:
    def __init__(self, root):
        self.root = root
        self.q = queue.Queue()
        self.busy = False
        self.buttons = []

        root.title("mokkori-iq  flash logger")
        root.configure(bg=BG)
        root.geometry("520x600")
        root.minsize(420, 520)
        root.bind("<F11>", self._toggle_fullscreen)
        root.bind("<Escape>", lambda e: root.attributes("-fullscreen", False))

        tk.Label(root, text="mokkori-iq  flash logger", bg=BG, fg=FG,
                 font=("Sans", 18, "bold")).pack(pady=(16, 2))
        self.port_lbl = tk.Label(root, text="ポート: 検索中…", bg=BG, fg=MUTED,
                                 font=("Sans", 12))
        self.port_lbl.pack(pady=(0, 10))

        # Big device-status readout.
        self.status = tk.Label(root, text="…", bg="#2a2a2a", fg=FG,
                               font=("Sans", 20, "bold"), height=2,
                               relief="flat", wraplength=460)
        self.status.pack(fill="x", padx=16, pady=(0, 16))

        self._add_button("📥  吸い出して保存 (PULL)", self.act_pull,
                         bg="#2e7d32", primary=True)
        self._add_button("🔄  状態を更新 (INFO)", self.act_info, bg="#37474f")
        self._add_button("🗑  消去 (ERASE)", self.act_erase, bg="#7a2222")

        tk.Label(root, text="ログ", bg=BG, fg=MUTED,
                 font=("Sans", 11)).pack(anchor="w", padx=18, pady=(8, 0))
        self.logbox = tk.Text(root, height=8, bg="#101010", fg="#b8c0b8",
                              font=("Monospace", 10), relief="flat",
                              state="disabled", wrap="word")
        self.logbox.pack(fill="both", expand=True, padx=16, pady=(2, 16))

        self.root.after(150, self._poll)
        # Probe the device on launch (no error popup if absent).
        self.act_info()

    # ---- UI helpers -------------------------------------------------------
    def _add_button(self, text, cmd, bg, primary=False):
        b = tk.Button(self.root, text=text, command=cmd, bg=bg, fg="white",
                      activebackground=bg, activeforeground="white",
                      font=("Sans", 16, "bold" if primary else "normal"),
                      relief="flat", bd=0, height=2, cursor="hand2")
        b.pack(fill="x", padx=16, pady=5)
        self.buttons.append(b)
        return b

    def _toggle_fullscreen(self, _evt=None):
        self.root.attributes("-fullscreen",
                             not self.root.attributes("-fullscreen"))

    def _set_status(self, text, color=FG):
        self.status.config(text=text, fg=color)

    def log(self, text):
        if not text:
            return
        self.logbox.config(state="normal")
        self.logbox.insert("end", text.rstrip() + "\n")
        self.logbox.see("end")
        self.logbox.config(state="disabled")

    def _buttons(self, state):
        for b in self.buttons:
            b.config(state=state)

    # ---- async plumbing ---------------------------------------------------
    def _poll(self):
        try:
            while True:
                self.q.get_nowait()()
        except queue.Empty:
            pass
        self.root.after(150, self._poll)

    def run_async(self, work, label, on_success):
        """Run blocking serial work() off the UI thread; post result back."""
        if self.busy:
            return
        self.busy = True
        self._buttons("disabled")
        self._set_status(f"{label}中…", MUTED)

        def worker():
            buf = io.StringIO()
            err = None
            result = None
            try:
                with contextlib.redirect_stdout(buf):
                    result = work()
            except Exception as exc:  # noqa: BLE001 - surface everything in UI
                err = exc
            self.q.put(lambda: self._finish(label, buf.getvalue(), err,
                                            result, on_success))

        threading.Thread(target=worker, daemon=True).start()

    def _finish(self, label, out, err, result, on_success):
        self.log(out)
        if err is not None:
            self.log(f"[エラー] {err}")
            self._set_status(f"{label}に失敗", "#ff6b6b")
        else:
            on_success(result)
        self.busy = False
        self._buttons("normal")

    @staticmethod
    def _connect():
        port = fd.autodetect_port()
        if not port:
            raise RuntimeError("デバイスが見つかりません（USB接続を確認）")
        return port, open_serial(port)

    def _format_info(self, info):
        samples = int(info.get("samples", 0) or 0)
        secs = float(info.get("seconds", 0) or 0)
        if samples > 0:
            return f"● 記録あり\n{samples} samples / {secs:.1f} s", "#8bc34a"
        return "○ 空（記録なし）", MUTED

    # ---- actions ----------------------------------------------------------
    def act_info(self):
        def work():
            port, ser = self._connect()
            try:
                return port, fd.cmd_info(ser, echo=True)
            finally:
                ser.close()

        def done(result):
            port, info = result
            self.port_lbl.config(text=f"ポート: {port}")
            self._set_status(*self._format_info(info))

        self.run_async(work, "状態取得", done)

    def act_pull(self):
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        path = os.path.join(SWIM_DIR, f"swim_{stamp}.csv")

        def work():
            port, ser = self._connect()
            try:
                info = fd.cmd_info(ser, echo=False)
                rows = fd.cmd_dump(ser, info)
                odr = int(info.get("odr_hz", 52))
                if not rows:
                    return {"port": port, "empty": True}
                os.makedirs(SWIM_DIR, exist_ok=True)
                fd.save_csv(rows, odr, path)
                fd.cmd_erase(ser)
                mags = [math.sqrt(r[0] ** 2 + r[1] ** 2 + r[2] ** 2)
                        for r in rows]
                return {"port": port, "empty": False, "path": path,
                        "n": len(rows), "dur": len(rows) / odr,
                        "accmean": sum(mags) / len(mags)}
            finally:
                ser.close()

        def done(result):
            self.port_lbl.config(text=f"ポート: {result['port']}")
            if result.get("empty"):
                self._set_status("○ 記録なし（吸い出すデータがありません）", MUTED)
                return
            self._set_status(
                f"✓ 保存しました\n{result['n']} samples / {result['dur']:.1f} s",
                "#8bc34a")
            self.log(f"-> {os.path.relpath(result['path'], REPO_ROOT)}")
            self.log(f"|acc| mean: {result['accmean']:.3f} g (静止で ~1.0)")

        self.run_async(work, "吸い出し", done)

    def act_erase(self):
        if self.busy:
            return
        if not messagebox.askyesno(
                "消去の確認",
                "デバイスの記録をすべて消去します。\n"
                "吸い出していないデータは失われます。続けますか？",
                icon="warning"):
            return

        def work():
            port, ser = self._connect()
            try:
                fd.cmd_erase(ser)
                return port
            finally:
                ser.close()

        def done(port):
            self.port_lbl.config(text=f"ポート: {port}")
            self._set_status("○ 消去しました（記録なし）", MUTED)

        self.run_async(work, "消去", done)


def main():
    root = tk.Tk()
    FlashGui(root)
    root.mainloop()


if __name__ == "__main__":
    main()
