# A3 dry-bench verification record

Verification date: 2026-10-05 UTC. No hardware connected or flashed.

## Passed

- Current remote main verified at `2d62eabeadcdc6730c39efd129d703911f55026b`; draft-PR branch `review/a3-safe-startup`; source, host tests, build guards and documentation are tracked, generated binaries are not
- Official Seeeduino:nrf52 1.1.13 + private exact-hash A3 patch. Core/variant link guards present in final ELF
- Target build: `Seeeduino:nrf52:xiaonRF52840Sense`; motor default disabled; **146,516 bytes program / 811,008 available**, **25,524 bytes globals / 237,568 available**
- Final ELF audit: initial motor/ADC OUTCLR precedes PWM disable, safe variant writes LOW to logical VBAT_ENABLE 14 before setting OUTPUT; both A3 guard symbols present; no linked `analogWrite` symbol in this motor-disabled image
- Host policy tests under AddressSanitizer/UndefinedBehaviorSanitizer: startup UNKNOWN and timing boundaries, raw VBUS inhibit, brief/sustained DET preserving logging, manual arm reset, fault requalification, opposite wake levels, millis wrap and powered-dock-removal cancellation
- Host storage/codec tests under ASan/UBSan: erased-only append, out-of-bounds/full rejection, payload-first/magic-last order, short payload/commit, failed read/readback, malformed units 0/255, invalid drop 32, exhausted payload and synthetic round-trip
- Core patch tests: exact-source idempotence, unknown revision refusal, stock-core preprocessing rejection
- Original `tools/codec_check.py`: 144,360 and 163,840 recorded samples round-trip bit-exactly to the same 2-LSB quantization. Legacy samples/anchors/records mixed-image checks pass. Capacity estimates remain **123 and 130 minutes**, dependent on signal/compression; not an endurance guarantee
- UF2/HEX/DFU cross-check: 573 UF2 blocks, NRF52840 family 0xADA52840, 146,524 HEX image bytes match; application-only addresses 0x27000..0x4AC5B; DFU contains application plus its init/metadata only. No bootloader/SoftDevice image
- Python syntax checks and `git diff --check`
- Independent read-only source review found no remaining blockers for this **motor-disabled, trusted dry-bench** scope; the same host tests were independently rerun under sanitizers

Compiler reports one inherited unused static `recorded_samples()` warning with `--warnings all`. No application compile errors. LeakSanitizer is disabled in the host runner because this execution environment uses ptrace; AddressSanitizer and UndefinedBehaviorSanitizer remain enabled. No assertion-only host simulation is claimed to validate physical GPIO behavior.

## Build dependencies used

- arduino-cli 1.5.2-rc.1, commit fef6e48df
- Seeeduino:nrf52 1.1.13
- ARM GCC 9-2019q4 (official Seeed board-package toolchain)
- Seeed Arduino LSM6DS3 2.0.7
- Adafruit SPIFlash 5.1.1
- SdFat – Adafruit Fork 2.3.103
- Board-bundled Bluefruit 0.21.0, TinyUSB 1.7.0
- adafruit-nrfutil 0.5.3.post16
- UF2 conversion by the board package's own uf2conv.py, with `--convert` explicitly set; no device probing/flashing

## Not run / not established

Hardware startup/bootloader waveforms, actual charge current, P0.31 ADC voltage during charging/reset, actual motor or LDO inrush/current, battery qualification, measured System OFF current or wake, flash interruption on a real P25Q16H, BLE radio throughput, full 2-hour hardware recording, wet-contact behavior, enclosure/RF/thermal/waterproof testing and app UI for new A3 controls.

The bootloader precedes the application core patch and remains a mandatory physical audit. Firmware cannot inhibit the stock charger or authenticate dry contacts. The supplied binaries remain motor-disabled. Read BRINGUP.md and keep motor/battery disconnected until the corresponding acceptance gates pass.

## Artifact identity

The separately delivered review bundle contains `evidence/artifact-sha256.txt` and `SHA256SUMS.txt`; these generated artifacts are not committed here. Source reviewed: flash_logger.ino SHA-256 `f925c619694ee0121014704c6523e913bbdbc1d4f167a71bc8512d3ebf53b369`.

## Draft PR verification

Before publication, the target build, sanitizer host tests, exact-core patch checks, both original-session codec regressions, Python syntax checks and `git diff --check` were rerun against the source in this branch. The target build remains 146,516 bytes program / 25,524 bytes globals. The firmware source is unchanged from the reviewed bundle. No `.github` workflows are defined at the base revision; GitHub check status is reported separately on the PR.
