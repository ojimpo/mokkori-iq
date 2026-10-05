# A3 dry-bench firmware review

**REVIEW / DRY BENCH ONLY. Not a hardware safety release, motor qualification, battery approval, wet-use approval, or production image.**

Base: `ojimpo/mokkori-iq` main `2d62eabeadcdc6730c39efd129d703911f55026b`, verified from GitHub before this local review. Hardware: A3 38-reference minimum prototype, R8 removed, D7/P1.12 VBUS_N, D2/P0.28 passive DET. The parent hardware package remains NOT_FOR_ORDER.

Program the XIAO separately, or with **motor and battery physically disconnected**. Start with a protected, current-limited bench supply. No device was flashed or operated during this work. The delivered build sets `A3_ENABLE_MOTOR=0`; every VIB path is inhibited. Do not enable motors or attach the selected cell until the electrical gates below are passed.

## What changed

- Patched the exact Seeed 1.1.13 core and Sense variant: LOW motor/ADC-divider latches before PWM release; safe GPIO before other core initialization; preserve those LOW latches through the core's usual all-HIGH initialization; remove its pre-setup P0.14 HIGH. Unknown core revisions fail the patch script. The sketch requires the patch marker and both link guards
- D0/P0.02 MOTOR_EN and D10/P1.15 MOTOR_PWM are explicitly LOW first and before OFF. Stop detaches PWM ownership rather than relying on analogWrite(0)
- D7 is input/pull-up, never Serial1 RX or external SPI SS. VBUS begins UNKNOWN. Initial bring-up candidates: 10 ms settle plus 10 ms stable sampling. Raw VBUS assertion inhibits immediately; absence must qualify
- D2 uses the external bias, no internal pull. Initial candidates: 600 ms reset settling plus 1 second stable debounce. Raw DET HIGH inhibits motors immediately. D1/D3/D4 remain unused/no-pull inputs; IMU uses internal Wire1
- P0.13 is input/no pull for nominal 50 mA selection. P0.14 stays LOW continuously, including System OFF; no HIGH battery-read cleanup. Battery measurement retains the existing 40 μs ADC acquisition and divider calibration
- Existing log layout, BLE UUIDs/36-byte status, samples, anchors, USB dump and app pull compatibility are retained. No autoerase. Record writes check erased space, verify the payload, then commit the existing 2-byte magic last. Write/corrupt-tail failures latch a storage fault and inhibit further append/OFF. Decoder bounds reject invalid record lengths/drop counts
- Cold boot/reset/wake is awake idle. RUN explicitly arms append logging in RAM; resets clear it. VBUS and an active BLE connection pause logging; the arm remains until STOP/STANDBY/reset. DET alone never stops or discards a recording
- D2 HIGH wakes OFF-undocked on attachment. A sustained attachment can re-arm LOW-removal wake. D2 LOW wakes OFF-docked into awake BLE idle. This is standby, not battery isolation

**A passive conductive bridge cannot distinguish water from an unpowered dock.** This firmware makes no dry-contact claim and cannot turn the stock hardware charger off. Energize contacts only when dry and off-body. No powered/wet/swimming charging. The charger has no actual cell-temperature measurement on the stock module.

## Bench controls and state expectations

The existing app is still usable for status, time sync and log retrieval. Its UI has not been updated for A3 RUN/STOP/STANDBY. The supplied BLE probe exposes those controls without requiring a USB serial connection.

| Command | USB console | BLE control characteristic ...0005 | Result |
|---|---|---|---|
| Arm logging | RUN | byte 0x20 / `tools/ble_probe.py --run` | Append after disconnect + qualified VBUS absence; never erase |
| Stop | STOP | byte 0x21 / `--stop` | Flush log, motor LOW, awake BLE idle |
| Standby | STANDBY | byte 0x22 / `--standby` | Flush, wait for BLE disconnect and VBUS absence, then arm opposite stable D2 level |
| Diagnostics | SAFETY | Existing status remains compatible | USB reports raw inputs, qualified states, reset reason, arm/faults |
| Explicit USB append test | TESTLOG 5 | Existing logging only | Five-second dry-bench append exception while USB is present; no motor |
| Motor | VIB | Existing VIB | Delivered motor-disabled image inhibits it |

USB parser runs when VBUS is present and BLE is disconnected. BLE helper needs its existing `bleak`/`pyserial` Python dependencies and an authorized Bluetooth-enabled host. These commands are instructions for a later physical bench session; they were not sent here.

- **Unpowered dock + STANDBY:** true System OFF, D2 LOW wake on removal, then awake idle/advertising
- **Powered dock + STANDBY:** remains awake with motor/logging inhibited while VBUS is present. If power is removed while still docked, enters OFF with removal wake. If the unit itself is detached, the pending sleep is cancelled and it remains awake idle. Detaching does not send it straight back to sleep
- **Undocked + STANDBY:** D2 HIGH attach wake first, then stable attachment can re-arm D2 LOW removal wake
- **Wet/brief DET while logging:** motor inhibit; append logging continues. Even sustained DET alone does not terminate the log
- **OFF call fails or debugger emulates OFF:** fail closed with motor LOW. BLE/IMU may already be stopped; a physical reset is required. Do not interpret a returned OFF call as sleep success
- **Storage fault:** valid stored prefix remains readable; further append and OFF are inhibited. Buffered unwritten samples remain in RAM for diagnosis, not a supported recovery guarantee. Back up readable data before deciding to reset or explicitly erase. Existing old records have no CRC; this patch cannot prove historical data integrity after a past power interruption

RUN does not itself turn the motor on. All motors are compiled out in this deliverable, and automatic periodic haptic pulses were removed.

## Reproduce the dry-bench build

Use a **private Arduino data/user directory**. Do not modify a shared workstation's installed core by accident. Commands below build only; they do not flash or update a bootloader.

```sh
# From this review's repository/source root, with arduino-cli already installed:
mkdir -p .a3-tools/data .a3-tools/downloads .a3-tools/user build/a3
cat > .a3-tools/arduino-cli.yaml <<CFG
directories:
  data: $PWD/.a3-tools/data
  downloads: $PWD/.a3-tools/downloads
  user: $PWD/.a3-tools/user
board_manager:
  additional_urls:
    - https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
CFG
CLI_CONFIG="$PWD/.a3-tools/arduino-cli.yaml"
arduino-cli --config-file "$CLI_CONFIG" core update-index
arduino-cli --config-file "$CLI_CONFIG" core install Seeeduino:nrf52@1.1.13
arduino-cli --config-file "$CLI_CONFIG" lib install \
  'Seeed Arduino LSM6DS3@2.0.7' 'Adafruit SPIFlash@5.1.1' 'SdFat - Adafruit Fork@2.3.103'
python3 -m venv .a3-tools/venv
.a3-tools/venv/bin/pip install adafruit-nrfutil==0.5.3.post16
CORE="$PWD/.a3-tools/data/packages/Seeeduino/hardware/nrf52/1.1.13"
python3 tools/prepare_a3_core.py "$CORE"
PATH="$PWD/.a3-tools/venv/bin:$PATH" arduino-cli --config-file "$CLI_CONFIG" compile \
  --fqbn Seeeduino:nrf52:xiaonRF52840Sense --warnings all \
  --build-path "$PWD/build/a3-objects" --output-dir "$PWD/build/a3" firmware/flash_logger
bash tests/a3/run_host_tests.sh
python3 tests/a3/check_core_patch.py "$CORE"
# Needs original captured data/swim CSVs and numpy/pandas:
python3 tools/codec_check.py
```

The core patch script verifies SHA-256 of all three official input files, saves originals beside them, and is idempotent. An unsupported core is rejected. Build-time marker plus linker guards prevent silently using the unpatched stock initialization. The separate review bundle includes application HEX/ELF, the standard Adafruit application DFU ZIP, and a separately converted application-only UF2. UF2 was generated with the board package’s uf2conv.py --convert option and family 0xADA52840; it was not sent to a device. It does not replace or qualify the bootloader/SoftDevice.

Generated binaries and the private Arduino directories are not committed to the repository. The checked-in source and pinned dependency instructions reproduce the build.

No motor-enabled binary is supplied. Do not set A3_ENABLE_MOTOR=1 on the assembled prototype merely to try it. Current-limit/inrush/startup/stall gates still apply even when the intended running current is only 80 mA.

## Required physical acceptance, in order

Record actual board revision, bootloader version, supply, temperatures, scope captures and results. Use no debugger for real System OFF/current measurements.

1. **Unloaded GPIO/startup.** Battery and motor absent. Measure D0/D10 LOW across power-on, reset pin, watchdog, software reset, double-reset bootloader entry and System OFF wake. Confirm GPIO pull-downs and no unintended LDO pulse. This application patch cannot control the earlier factory bootloader interval
2. **Pinmap and VBUS.** Confirm physical D7/P1.12, input buffer and pull-up; D2/P0.28 no internal pull. Verify D7 LOW≤0.3×VDD and HIGH≥0.7×VDD over supply/temperature/tolerances, direct USB and dock attach/remove, including resets. Validate candidate settling/debounce timings rather than treating them as measured
3. **Charge/ADC circuit.** With a protected bench battery simulator or appropriate supervised test fixture, measure nominal ~50 mA selection, P0.13 high impedance, and P0.14 LOW throughout application/bootloader/reset. Measure P0.31 stays within the MCU's ratings. Compare ADC millivolts against a meter. A simulator must support charger current safely; an ordinary bench supply that cannot sink current is not a substitute
4. **Dry passive contacts.** Open, real unpowered dock, powered dry dock, bounce, removal during OFF preparation and known resistance bridges. A conductive bridge must never authorize charging. Do contamination tests separately from energized charging
5. **Standby/wake.** Test both undocked-attach and docked-remove sense levels; removal must return awake idle with advertising and no motor/autologging. Verify powered-dock removal cancels pending sleep. Check already-asserted sense never produces a rapid reset loop. Measure actual standby current
6. **Data.** Record append sessions, connect/disconnect BLE, pause/resume VBUS, short and sustained DET, STOP/STANDBY flush, full flash, intentional power interruption on disposable test data, dump/resume and time anchors. Existing logs must survive without implicit ERASE. Full/corrupt storage must inhibit append without erasing
7. **Motor rail without motor or cell.** On the protected current-limited external fixture only, separately review a motor-enabled test image and measure LDO/output-capacitor inrush. No such image is included here
8. **Motor + eventual cell.** Measure startup/stall/run peaks, total BLE/logging demand, rail dips, stop/coast time and temperature before selecting/connecting a cell. The 100 mAh candidate's reported 105 mA continuous rating, with no specified pulse allowance, does not yet qualify it

The dry-bench firmware closes the source/build preparation step only. Actual-device measurements remain mandatory before calling the A3 startup path safe, especially bootloader behavior and charger/ADC voltage.

## Primary references

- [Base firmware commit](https://github.com/ojimpo/mokkori-iq/commit/2d62eabeadcdc6730c39efd129d703911f55026b)
- [Seeed 1.1.13 core init and System OFF](https://github.com/Seeed-Studio/Adafruit_nRF52_Arduino/blob/1.1.13/cores/nRF5/wiring.c)
- [Sense pinmap/variant initialization](https://github.com/Seeed-Studio/Adafruit_nRF52_Arduino/blob/1.1.13/variants/Seeed_XIAO_nRF52840_Sense/variant.cpp)
- [Seeed battery ADC charging warning](https://wiki.seeedstudio.com/battery_charging_considerations/)
- [Seeed XIAO hardware guide](https://wiki.seeedstudio.com/XIAO_BLE/)
- [Nordic nRF52840 GPIO wake behavior](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/gpiote.html)
- [S140 bundled POWER SVC APIs](https://github.com/Seeed-Studio/Adafruit_nRF52_Arduino/blob/1.1.13/cores/nRF5/nordic/softdevice/s140_nrf52_7.3.0_API/include/nrf_soc.h)

Trusted dry-bench radio only: the inherited BLE service is open and unbonded, including ERASE. No authentication redesign was performed. Keep unrelated centrals away and back up data. Charge flags are voltage/VBUS estimates, not actual charger termination or cell-temperature measurements.
