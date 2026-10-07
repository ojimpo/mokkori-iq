# Android prototype verification

Verified on 2026-10-07 in Linux with JDK 17, SDK Platform 35 and Build-Tools 35.0.0.
The local source is based on `2d62eabeadcdc6730c39efd129d703911f55026b`.

## Commands

```sh
cd android
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

- Core: **30 tests passed** (7 raw recording, 8 dump assembler, 5 demo/report, 10 BLE protocol)
- App: **13 tests passed** (6 state/persistence, 5 Compose screen flows, 2 activity startup cases)
- Actual MainActivity startup: Robolectric API **23 and 35**
- Compose screen navigation/rendering: Robolectric API **35**, 412 × 892 dp, 2× density
- Lint: **0 errors, 0 warnings** (`No issues found`; forced full rerun)
- Gradle Wrapper: official 8.13 distribution downloaded with pinned checksum; `./gradlew --version` passed
- Review patch: `git apply --check` passed against the original baseline files
- Working-tree whitespace check: `git diff --check` passed
- Debug APK: built and signed; `apksigner verify` verifies v1 and v2 signatures
- APK metadata: app ID `com.ojimpo.mokkori.android.demo`, minSdk 23, targetSdk 35
- Native ABIs: armeabi-v7a, arm64-v8a, x86, x86_64
- APK permission inspection: no INTERNET, Bluetooth, location or vibration permission
- No existing iOS/firmware source was modified

## Exercised behavior

- Log → report → laps → Back → report → Back → logs, plus tab switching
- Bluetooth-off demo state disables import; reconnect demo re-enables it
- Cancelling the erase confirmation leaves the fake device unchanged
- Haptic distance assignment through the UI is persisted
- Strava preview is explicitly unable to publish; Back returns to report
- Repeated import deduplicates; import persists only after successful completion
- Transfer cancellation, simulated connection loss and injected failure leave no partial session
- Retry after cancellation or failure succeeds
- Demo memory erase does not delete previously imported logs
- Settings survive construction of a new model; values are range-validated
- Golden BLE bytes, unsigned boundaries, malformed/partial/gapped/duplicate/overrun dumps,
  cancellation/abort, raw int16 round-trips, SI conversion and internally consistent fake reports

## Screenshots

The six PNGs are **actual Compose/native Android view renders produced by Robolectric**,
not design mockups or web recreations. They were visually checked for legible Japanese,
clipping and navigation layout. They do not show a booted Android emulator or a physical phone.
The test produces them in `app/build/screenshots/`.

## Not verified / not implemented

- No Android emulator was booted; this environment has no hardware virtualization device
- No physical Android device or Galaxy S5 was tested
- No real BLE scanning/GATT, real transfer, firmware erase, clock write or motor output
- No CSV import, wall/stroke detection, turn editing or iOS/Python analysis parity
- No Strava sign-in or upload
- iOS, firmware and Python checks were not rerun because those trees were unchanged
- Release signing, Play Store publication and merging were not performed
- Source publication is limited to a review-only draft pull request; the delivered APK is a local debug build

The project is a tested native UI/demo slice, not a completed production Android port.

APK SHA-256: `4f097da61408049404500b843108d9a73c101c0c5d3e917490aa2522c9aebf13`
