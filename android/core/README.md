# Android core prototype

Pure Kotlin/JVM module, package `com.ojimpo.mokkori.core`. Runtime dependency: Kotlin
standard library only. Tests use JUnit 4.13.2 and run with JDK 17:

```sh
cd android
./gradlew :core:test
```

## Implemented scope

- `BleProtocol`: exact service/characteristic UUIDs, little-endian command payloads,
  and the 36-byte v1 status prefix
- `DeviceStatus`: nullable unknown state, unsigned counters stored as `Long`, anchor
  time projection, battery and memory calculations
- `HapticPattern` / `HapticSettings`: the same three patterns, distances and strength
  settings as the iOS model; these are data models, not persistence or hardware calls
- `DumpAssembler`: ordered, full-dump validation; produces `RawRecording` only after
  receiving the promised count **and** a standalone end marker
- `RawRecording`: headerless six-axis signed int16 little-endian `raw.bin`, binary
  round-trip, and iOS-compatible rounded SI-unit decoding
- `SwimReport`: iOS report/lap/interval/set names, units, and summary properties
- `DemoData`: three invented, fixed sessions with stable IDs and a fake device status

No BLE GATT transport, permissions, scanning, connection lifecycle, CSV import,
session persistence, wall/stroke detector, Strava client or upload is implemented
in this module. The demo reports are handcrafted synthetic fixtures; they are
**not** output from the iOS/Python analysis engine and are not an analysis-parity claim.
No actual user raw logs or workout data are read or included in the demo.

## App interface

```kotlin
val initialSessions = DemoData.sessions.take(2)
val fakeImport = DemoData.sessions[2] // stable id: demo-500; deduplicate on id
val report = initialSessions.first().report
val settings = HapticSettings(listOf(100, null, 500), strengthPercent = 75)
val bytesForFutureTransport = BleProtocol.setHaptics(settings)
```

Always display `DemoData.disclosure` or equivalent when using these fixtures. Do not
present `DemoData.deviceStatus` as real telemetry. Haptic settings may contain duplicate
distances so a UI can flag them; the command builder refuses to send duplicates.

### Wire contract

All integer fields are little-endian. UUID base is
`6D6B6F69-A55A-4000-8000-00000000000N`: service 1; time 2; status 3; data 4; control 5.
Time writes are 8-byte Unix milliseconds. Control payloads are:

- `01`: erase (a future transport must ask before a real destructive write)
- `02 pct n [n × u16 ms]`: vibration ON/OFF train, at most six durations
- `03 pct [3 × u16 meters]`: distance settings, zero disables a pattern
- `10 u32`: start dump at absolute sample index
- `11`: stop dump

Status offsets: version 0; flags 1; ODR 2; samples 4; capacity 8; battery mV 12;
battery percent 14; haptic percent 15; epoch ms 16; anchor index 24; uptime ms 28;
dump progress 32. Extra bytes after the v1 prefix are ignored. An unknown version
is explicitly rejected, rather than guessing its layout. A zero ODR uses the iOS
52 Hz fallback. Epoch zero means no anchor. Epoch values above `Long.MAX_VALUE`
are rejected instead of wrapping a uint64 into a negative date.

### Safe transfer integration

1. Capture the status's sample count and ODR before starting a dump. Validate the
   `Long` count before conversion to `Int`; `DumpAssembler.MAX_SAMPLES` is 1,000,000
2. Enable notifications and wait for their completion before sending DUMP_START
3. Create `DumpAssembler(count, odr)` and feed ordered DATA notifications to `accept`
4. `null` means still receiving, including when all sample bytes have arrived but
   the terminator has not. Persist only the non-null complete recording
5. Any malformed, gap, duplicate, overrun or premature end frame permanently fails
   the assembler and discards its buffer. Call `abort()` on disconnect, notification
   failure or timeout, or `cancel()` on user cancel; make a fresh assembler to retry
6. Serialize access to the assembler. It is deliberately not thread-safe

The assembler supports full dumps from sample zero. `BleProtocol.dumpStart` can
encode a future resume index, but resume assembly/storage is not implemented.
The binary byte sequence is decoded raw sensor data, not the compressed on-flash
record format. Keep ODR alongside `raw.bin` in metadata. SI conversion intentionally
rounds times to 4 decimals and g/dps values to 5 decimals using ties-to-even before
converting to m/s² and rad/s, matching `RawRecording.swift`.

## Sources and checks

Repository source of truth:

- `CLAUDE.md`, `docs/app_handoff.md`
- `firmware/flash_logger/flash_logger.ino` (wire offsets and command bytes)
- `app/MokkoriIQ/Sources/Models/BLEManager.swift`, `DeviceSettings.swift`
- `app/MokkoriCore/Sources/MokkoriCore/RawRecording.swift`, `SwimSession.swift`,
  `SwimReport.swift`

Tests cover exact byte vectors, signed/unsigned boundaries, append-only status
extensions, malformed and interrupted dumps, the full int16 binary domain, golden
synthetic SI conversions, ties-to-even rounding, internally consistent demo reports,
and missing-stroke aggregation. Hardware and full detector parity require separate
future integration work; a passing JVM suite does not establish either.
