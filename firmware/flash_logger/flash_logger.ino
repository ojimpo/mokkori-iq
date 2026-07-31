/*
 * mokkori-iq -- QSPI flash data-logger for the Seeed XIAO nRF52840 Sense.
 *
 * Records the onboard LSM6DS3TR-C 6-axis IMU to the 2 MB QSPI flash so we can
 * collect real crotch-mounted swimming data (no host needed in the pool), then
 * retrieve it -- over BLE from the phone, or over USB at the desk.
 *
 * The mode follows USB VBUS *live* (no reset needed), which matches the
 * "swim a little -> plug into the laptop -> pull & clear -> swim again" loop:
 *   - USB unplugged (battery) -> LOG: append IMU samples to the flash.
 *   - USB plugged            -> CONSOLE: never logs, accepts commands, so
 *                               plugging in is always safe and ready to dump.
 * A connected BLE central overrides both: logging pauses while the phone is
 * talking to us, and resumes on disconnect. See "BLE" below.
 *
 * Storage is append-only; the flash is cleared ONLY by an explicit ERASE, so
 * unplugging to swim again never destroys data. Samples are raw int16 sensor
 * counts packed into 256-byte pages:
 *     [0:2] magic 0xA55A   [2:4] sample count (1..20)   [4:6] page seq
 *     [6:8] reserved       [8:248] 20 samples x (ax,ay,az,gx,gy,gz) int16 LE
 * Time anchors are appended to the same stream as their own page kind so the
 * host can turn sample indices into absolute time (the nRF52 has no RTC across
 * a power cycle, so the phone hands us the clock):
 *     [0:2] magic 0xA55B   [2:4] count = 0   [4:6] page seq   [6:8] reserved
 *     [8:16] epoch_ms uint64 LE   [16:20] sample index uint32 LE
 *     [20:24] millis() uint32 LE
 * The log ends at the first page whose magic is neither of those (erased flash
 * reads 0xFFFF). Host-side tools/flash_dump.py pulls the stream and converts
 * the raw counts to g / deg-per-second.
 *
 * Console commands (newline-terminated, CONSOLE mode):
 *   INFO            print header + recorded sample/page count + duration
 *   DUMP            stream the recorded samples as raw bytes (see protocol)
 *   TIMES           list the time anchors recorded in the log
 *   TIME <epoch_ms> append a time anchor now (the BLE path does this too)
 *   ERASE           erase the whole flash (the only way data is cleared)
 *   TESTLOG <sec>   append <sec> seconds now (even on USB) -- bench round-trip
 *   VIB [ms] [pct]  run the vibration motor (default 500 ms at 100%)
 *   HELP            list commands
 */
#include "LSM6DS3.h"
#include "Wire.h"
#include <SPI.h>
#include <Adafruit_SPIFlash.h>
#include <bluefruit.h>
#include "log_format.h"

// ---- sensor configuration (kept in sync with the on-flash data) -----------
static const uint16_t ODR_HZ      = 52;      // sample rate
static const uint16_t ACCEL_FS_G  = 8;       // +/- g
static const uint16_t GYRO_FS_DPS = 2000;    // +/- deg/s

// ---- flash page format: see log_format.h ----------------------------------

LSM6DS3 imu(I2C_MODE, 0x6A);
Adafruit_FlashTransport_QSPI flashTransport;     // uses the variant's QSPI pins
Adafruit_SPIFlash flash(&flashTransport);

enum Mode { M_BOOT, M_CONSOLE, M_LOGGING, M_FULL };
static Mode g_mode = M_BOOT;
static bool g_flash_ok = false;
static bool g_imu_ok = false;
static uint32_t g_jedec = 0;

// --- USB VBUS: present means we're plugged into a host / charger -----------
static bool vbus_present() {
  return (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0;
}

// --- battery gauge (XIAO nRF52840) -----------------------------------------
// VBAT goes through a 1M / 0.51M divider to PIN_VBAT (P0.31). VBAT_ENABLE
// (P0.14) LOW connects the divider; we enable it only while measuring so the
// divider doesn't leak current the rest of the time. Read against the chip's
// 3.0 V internal reference at 12-bit, then undo the divider.
//   Vbat = raw * (3000mV / 4096) * (1M+0.51M)/0.51M
// NOTE: the divider ratio comes from the Seeed variant/wiki; if the reported
// mV is off, sanity-check against a multimeter and adjust VBAT_DIVIDER.
static const float    VBAT_DIVIDER = (1000.0f + 510.0f) / 510.0f;  // ~2.961
static const float    ADC_REF_MV   = 3000.0f;   // AR_INTERNAL_3_0
static const float    ADC_FULL     = 4096.0f;   // 12-bit
static const uint16_t VBAT_FULL_MV = 4150;      // charger tapers near 4.2V

// **analogSampleTime(40) is not optional here.** The divider looks like
// ~340k (1M || 0.51M) to the ADC, and the core's default acquisition time is
// 3 us -- the datasheet wants 40 us above ~100k. With 3 us the sampling
// capacitor never charges, so a conversion mostly returns whatever the
// previous one left behind: readings stuck to either 3715 or 4103 mV at
// random, and averaging 32 of them didn't help because consecutive reads of
// the same channel just agree with each other (measured on hardware
// 2026-07-31 -- the first guess, a too-short settle delay, was wrong).
static uint16_t read_vbat_mv() {
  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, LOW);               // connect the divider
  pinMode(PIN_VBAT, INPUT);
  analogReference(AR_INTERNAL_3_0);
  analogReadResolution(12);
  analogSampleTime(40);                          // us -- for the 340k source
  delay(10);                                     // let the divider settle
  for (int i = 0; i < 4; i++) (void)analogRead(PIN_VBAT);   // discard
  uint32_t acc = 0;
  for (int i = 0; i < 32; i++) acc += analogRead(PIN_VBAT);
  digitalWrite(VBAT_ENABLE, HIGH);              // disconnect (stop the leak)
  analogSampleTime(3);                           // leave the default for others
  float raw = acc / 32.0f;
  return (uint16_t)(raw * ADC_REF_MV / ADC_FULL * VBAT_DIVIDER + 0.5f);
}

// The BLE status blob is republished every second (twice a second while
// dumping), and a battery reading now costs 25 ms of settling -- far too much
// to spend on a value that moves over minutes. Read it at most every 10 s.
static uint16_t g_vbat_mv = 0;
static uint32_t g_vbat_at = 0;

static uint16_t vbat_cached() {
  uint32_t now = millis();
  if (g_vbat_mv == 0 || now - g_vbat_at >= 10000) {
    g_vbat_mv = read_vbat_mv();
    g_vbat_at = now;
  }
  return g_vbat_mv;
}

// Rough Li-ion state-of-charge from resting voltage (piecewise linear). While
// on the charger the pack reads high, so this is a coarse estimate -- the main
// use is "is it charged enough" and the charging flag below.
static uint8_t vbat_pct(uint16_t mv) {
  static const uint16_t v[] = {3300, 3500, 3600, 3700, 3800, 3900, 4000, 4200};
  static const uint8_t  p[] = {   0,    8,   20,   45,   62,   75,   85,  100};
  if (mv <= v[0]) return 0;
  for (int i = 1; i < 8; i++) {
    if (mv < v[i]) {
      return p[i - 1] + (uint8_t)((uint32_t)(mv - v[i - 1]) *
             (p[i] - p[i - 1]) / (v[i] - v[i - 1]));
    }
  }
  return 100;
}

// No dedicated charge-status GPIO is broken out on the XIAO, so derive it:
// on the charger (VBUS) and not yet topped off => charging; topped off => done.
static bool battery_charging(uint16_t mv) {
  return vbus_present() && mv < VBAT_FULL_MV;
}

// --- vibration motor (coin ERM, low-side BSS138 switch on D10) --------------
// 3V3 -- motor(+) ... motor(-) -- BSS138 drain; source -- GND;
// D10 --[100R..1k]-- gate, gate --[100k]-- GND (off while the pin floats);
// 1N4148 flyback across the motor, cathode on the 3V3 side.
// Motor: JYUDAUFU 10x2.7 mm ERM, 3 V rated / 80 mA max (works 3-4.2 V).
static const uint8_t PIN_MOTOR = 10;             // D10, same header as 3V3/GND

// While logging (= in the pool), buzz a short double pulse every N seconds so
// we can tell whether the vibration is felt through the case + swimsuit while
// actually swimming. The bursts land at known offsets from the session start,
// so they are easy to identify (and ignore) in the IMU data. 0 disables.
static const uint32_t BUZZ_PERIOD_S = 60;
static const uint32_t BUZZ_ON_MS = 200, BUZZ_GAP_MS = 200;

static void motor_set(uint8_t duty_pct) {        // 0 = off
  analogWrite(PIN_MOTOR, (uint16_t)duty_pct * 255 / 100);
}

// Haptic feedback preferences pushed from the phone. Held in RAM only: the app
// re-sends them on every connect, and the on-device causal wall counter that
// would actually fire them isn't written yet (see CLAUDE.md). Storing them here
// keeps the transport honest and lets the phone read back what it sent.
static uint8_t  g_haptic_strength = 100;
static uint16_t g_haptic_meters[3] = {0, 0, 0};  // 0 = pattern disabled

// --- RGB status LED (common-anode on XIAO: drive LOW to light) --------------
static void led(bool r, bool g, bool b) {
  digitalWrite(LED_RED,   r ? LOW : HIGH);
  digitalWrite(LED_GREEN, g ? LOW : HIGH);
  digitalWrite(LED_BLUE,  b ? LOW : HIGH);
}

// --- scan the log: count valid pages / samples and the next free address ----
// End of log = first page whose magic isn't one of ours (erased = 0xFFFF).
// Partial pages (count < 20) are allowed mid-log so sessions can be appended,
// and anchor pages (0xA55B) carry no samples but still consume a page.
static void scan_log(uint32_t *out_pages, uint32_t *out_samples,
                     uint32_t *out_end, Anchor *out_last, uint32_t *out_anchors) {
  uint32_t addr = 0, pages = 0, samples = 0, anchors = 0, size = flash.size();
  uint8_t hdr[24];
  while (addr + PAGE_SIZE <= size) {
    flash.readBuffer(addr, hdr, sizeof(hdr));
    uint16_t magic, count;
    memcpy(&magic, hdr, 2);
    memcpy(&count, hdr + 2, 2);
    if (magic == ANCHOR_MAGIC) {
      anchors++;
      if (out_last) {
        memcpy(&out_last->epoch_ms, hdr + 8, 8);
        memcpy(&out_last->sample_index, hdr + 16, 4);
        memcpy(&out_last->millis_at_sync, hdr + 20, 4);
      }
    } else if (magic == PAGE_MAGIC) {
      if (count == 0 || count > SAMPLES_PER_PAGE) break;   // corrupt -> stop
      samples += count;
    } else {
      break;                                     // erased / end of log
    }
    pages++;
    addr += PAGE_SIZE;
  }
  if (out_pages) *out_pages = pages;
  if (out_samples) *out_samples = samples;
  if (out_end) *out_end = addr;
  if (out_anchors) *out_anchors = anchors;
}

// How many samples fit in the flash, for the phone's "recordable time" gauge.
static uint32_t capacity_samples() {
  uint32_t size = flash.size();
  return (size / PAGE_SIZE) * SAMPLES_PER_PAGE;
}

// --- time anchors -----------------------------------------------------------
// The device has no clock across a power cycle, so the phone (or the USB host)
// tells us the epoch and we record "sample K happened at epoch E". The host
// then recovers absolute time for every sample as E + (i - K) * 1000 / ODR.
// Appending it as its own page keeps the sample stream byte-identical to what
// the Phase 0 pipeline already reads.
static bool append_anchor(uint64_t epoch_ms) {
  uint32_t pages, samples, addr;
  scan_log(&pages, &samples, &addr, NULL, NULL);
  if (addr + PAGE_SIZE > flash.size()) return false;

  uint8_t buf[PAGE_SIZE];
  memset(buf, 0, PAGE_SIZE);
  uint16_t magic = ANCHOR_MAGIC, count = 0, seq = (uint16_t)pages;
  uint32_t ms = millis();
  memcpy(buf, &magic, 2);
  memcpy(buf + 2, &count, 2);
  memcpy(buf + 4, &seq, 2);
  memcpy(buf + 8, &epoch_ms, 8);
  memcpy(buf + 16, &samples, 4);
  memcpy(buf + 20, &ms, 4);
  flash.writeBuffer(addr, buf, PAGE_SIZE);
  return true;
}

static void print_times() {
  uint32_t addr = 0, size = flash.size();
  uint8_t hdr[24];
  uint32_t n = 0;
  while (addr + PAGE_SIZE <= size) {
    flash.readBuffer(addr, hdr, sizeof(hdr));
    uint16_t magic, count;
    memcpy(&magic, hdr, 2);
    memcpy(&count, hdr + 2, 2);
    if (magic == ANCHOR_MAGIC) {
      uint64_t epoch;
      uint32_t idx, ms;
      memcpy(&epoch, hdr + 8, 8);
      memcpy(&idx, hdr + 16, 4);
      memcpy(&ms, hdr + 20, 4);
      // Serial.print can't do uint64 -- split into two decimal halves.
      Serial.print("TIME epoch_ms=");
      Serial.print((uint32_t)(epoch / 1000));      // seconds
      uint32_t frac = (uint32_t)(epoch % 1000);
      Serial.print(frac < 10 ? "00" : (frac < 100 ? "0" : ""));
      Serial.print(frac);
      Serial.print(" sample_index="); Serial.print(idx);
      Serial.print(" millis="); Serial.println(ms);
      n++;
    } else if (magic != PAGE_MAGIC || count == 0 || count > SAMPLES_PER_PAGE) {
      break;
    }
    addr += PAGE_SIZE;
  }
  Serial.print("# anchors="); Serial.println(n);
  Serial.println("OK");
}

static void print_info() {
  uint32_t pages, samples, anchors;
  scan_log(&pages, &samples, NULL, NULL, &anchors);
  float secs = (float)samples / (float)ODR_HZ;
  Serial.println("# mokkori flash logger v2");
  Serial.print("# odr_hz="); Serial.print(ODR_HZ);
  Serial.print(" accel_fs_g="); Serial.print(ACCEL_FS_G);
  Serial.print(" gyro_fs_dps="); Serial.println(GYRO_FS_DPS);
  Serial.print("# flash_ok="); Serial.print(g_flash_ok);
  Serial.print(" jedec=0x"); Serial.println(g_jedec, HEX);
  Serial.print("# flash_size="); Serial.print(flash.size());
  Serial.print(" pages="); Serial.print(pages);
  Serial.print(" samples="); Serial.print(samples);
  Serial.print(" capacity="); Serial.print(capacity_samples());
  Serial.print(" anchors="); Serial.print(anchors);
  Serial.print(" seconds="); Serial.println(secs, 1);
  uint16_t mv = read_vbat_mv();
  Serial.print("# vbat_mv="); Serial.print(mv);
  Serial.print(" pct="); Serial.print(vbat_pct(mv));
  Serial.print(" charging="); Serial.println(battery_charging(mv) ? 1 : 0);
  Serial.println("OK");
}

// --- stream the recorded samples as raw bytes ------------------------------
// Protocol:  "DUMP_BEGIN <nsamples> 12\n" then nsamples*12 raw bytes then
//            "\nDUMP_END\n".  Each sample = ax,ay,az,gx,gy,gz int16 LE.
// Anchor pages carry no samples, so they simply contribute nothing here and
// the byte stream stays exactly what the existing host tools expect.
static void dump_log() {
  uint32_t pages, samples;
  scan_log(&pages, &samples, NULL, NULL, NULL);
  Serial.print("DUMP_BEGIN ");
  Serial.print(samples);
  Serial.println(" 12");
  Serial.flush();

  uint8_t page[PAGE_SIZE];
  uint32_t addr = 0;
  for (uint32_t p = 0; p < pages; p++) {
    flash.readBuffer(addr, page, PAGE_SIZE);
    uint16_t magic, count;
    memcpy(&magic, page, 2);
    memcpy(&count, page + 2, 2);
    if (magic != PAGE_MAGIC) { addr += PAGE_SIZE; continue; }   // anchor page
    if (count > SAMPLES_PER_PAGE) count = SAMPLES_PER_PAGE;
    Serial.write(page + 8, (size_t)count * 12);
    Serial.flush();
    addr += PAGE_SIZE;
  }
  Serial.println();
  Serial.println("DUMP_END");
}

// ===========================================================================
// BLE
// ===========================================================================
// The phone is the point of the whole thing (pull the log poolside, set the
// clock, erase), so we advertise whenever we're powered -- including while
// logging. SoftDevice advertising is cheap next to the IMU + flash, and the
// alternative (wake on a tap pattern) needs thresholds tuned against real
// swimming data before it can be trusted not to miss the wake.
//
// A connected central pauses logging: the phone only ever talks to us out of
// the water, and pausing keeps flash writes away from the dump we're serving.
//
// UUID base 6D6B6F69-A55A-4000-8000-0000000000NN ("mkoi" + the flash magic).
// Bluefruit takes 128-bit UUIDs as little-endian byte arrays, i.e. reversed.
#define MKOI_UUID(nn) { 0x##nn, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, \
                        0x00, 0x40, 0x5A, 0xA5, 0x69, 0x6F, 0x6B, 0x6D }

static const uint8_t UUID_SVC[16]     = MKOI_UUID(01);
static const uint8_t UUID_TIME[16]    = MKOI_UUID(02);
static const uint8_t UUID_STATUS[16]  = MKOI_UUID(03);
static const uint8_t UUID_DATA[16]    = MKOI_UUID(04);
static const uint8_t UUID_CONTROL[16] = MKOI_UUID(05);

BLEService        svcLogger(UUID_SVC);
BLECharacteristic chrTime(UUID_TIME);        // write: 8B epoch_ms LE
BLECharacteristic chrStatus(UUID_STATUS);    // read/notify: STATUS_LEN blob
BLECharacteristic chrData(UUID_DATA);        // notify: dump frames
BLECharacteristic chrControl(UUID_CONTROL);  // write: 1B opcode + args

// Status blob. Little-endian, additive-only: the phone checks byte 0 and
// ignores anything past what it knows, so new fields don't need a lockstep
// firmware/app update.
static const uint8_t  STATUS_VERSION = 1;
static const uint16_t STATUS_LEN     = 36;
//  [0]  version           [1]  flags
//  [2]  odr_hz u16        [4]  samples u32        [8]  capacity u32
//  [12] vbat_mv u16       [14] vbat_pct u8        [15] haptic strength u8
//  [16] last anchor epoch_ms u64                  [24] last anchor index u32
//  [28] uptime_ms u32     [32] dump progress (samples sent) u32
static const uint8_t F_LOGGING  = 1 << 0;
static const uint8_t F_VBUS     = 1 << 1;
static const uint8_t F_CHARGING = 1 << 2;
static const uint8_t F_FULL     = 1 << 3;
static const uint8_t F_ERASING  = 1 << 4;
static const uint8_t F_DUMPING  = 1 << 5;
static const uint8_t F_IMU_OK   = 1 << 6;
static const uint8_t F_FLASH_OK = 1 << 7;

// Work the BLE callbacks hand to loop(): erase and vibrate block for a long
// time and the flash isn't reentrant, so nothing touches it from a callback.
static volatile bool     g_req_erase = false;
// A requested buzz is a pulse train (on, off, on, ...) so the app's three
// patterns -- which differ by count and length, not strength, because that's
// what's tellable through a swimsuit underwater -- arrive as one packet and
// get played with firmware timing instead of BLE round-trip jitter.
static const uint8_t     VIB_MAX_PULSES = 6;
static volatile bool     g_req_vib = false;
static volatile uint8_t  g_req_vib_n = 0;
static volatile uint8_t  g_req_vib_pct = 0;
static volatile uint16_t g_req_vib_ms[VIB_MAX_PULSES];
static volatile bool     g_req_anchor = false;
static volatile uint64_t g_req_anchor_epoch = 0;
static bool g_erasing = false;

// Dump-over-BLE state machine (driven from loop(), one page at a time).
static bool     g_dump_active = false;
static uint32_t g_dump_page = 0;       // page cursor
static uint32_t g_dump_pages = 0;      // pages in the log when the dump started
static uint32_t g_dump_abs = 0;        // absolute index of the next sample
static uint16_t g_dump_off = 0;        // sample offset inside the cached page
static uint16_t g_dump_have = 0;       // samples cached from the current page
static uint32_t g_dump_skip_to = 0;    // resume point (absolute sample index)
static uint8_t  g_dump_page_buf[PAGE_SIZE];
static bool     g_dump_page_valid = false;
static uint8_t  g_frame_samples = 15;  // recomputed from the negotiated MTU

static uint16_t g_conn = BLE_CONN_HANDLE_INVALID;

static uint32_t recorded_samples() {
  uint32_t samples;
  scan_log(NULL, &samples, NULL, NULL, NULL);
  return samples;
}

static void build_status(uint8_t *b) {
  uint32_t pages, samples;
  Anchor last = {0, 0, 0};
  scan_log(&pages, &samples, NULL, &last, NULL);
  uint16_t mv = vbat_cached();

  memset(b, 0, STATUS_LEN);
  b[0] = STATUS_VERSION;
  b[1] = (g_mode == M_LOGGING ? F_LOGGING : 0)
       | (vbus_present() ? F_VBUS : 0)
       | (battery_charging(mv) ? F_CHARGING : 0)
       | (g_mode == M_FULL ? F_FULL : 0)
       | (g_erasing ? F_ERASING : 0)
       | (g_dump_active ? F_DUMPING : 0)
       | (g_imu_ok ? F_IMU_OK : 0)
       | (g_flash_ok ? F_FLASH_OK : 0);
  uint16_t odr = ODR_HZ;
  uint32_t cap = capacity_samples(), up = millis();
  uint8_t pct = vbat_pct(mv);
  memcpy(b + 2, &odr, 2);
  memcpy(b + 4, &samples, 4);
  memcpy(b + 8, &cap, 4);
  memcpy(b + 12, &mv, 2);
  b[14] = pct;
  b[15] = g_haptic_strength;
  memcpy(b + 16, &last.epoch_ms, 8);
  memcpy(b + 24, &last.sample_index, 4);
  memcpy(b + 28, &up, 4);
  memcpy(b + 32, &g_dump_abs, 4);
}

// Refresh the readable value and push a notification if the phone subscribed.
static void publish_status() {
  uint8_t b[STATUS_LEN];
  build_status(b);
  chrStatus.write(b, STATUS_LEN);
  if (g_conn != BLE_CONN_HANDLE_INVALID && chrStatus.notifyEnabled(g_conn)) {
    chrStatus.notify(b, STATUS_LEN);
  }
}

static void ble_connect_cb(uint16_t conn_handle) {
  g_conn = conn_handle;
  BLEConnection *c = Bluefruit.Connection(conn_handle);
  if (c) {
    c->requestPHY();                          // 2M PHY if the phone agrees
    uint16_t mtu = c->getMtu();
    // frame = 4 B absolute index + N samples * 12 B, capped by one flash page
    uint16_t payload = (mtu > 7) ? (mtu - 3 - 4) : 12;
    uint16_t n = payload / 12;
    if (n < 1) n = 1;
    if (n > SAMPLES_PER_PAGE) n = SAMPLES_PER_PAGE;
    g_frame_samples = (uint8_t)n;
  }
  g_dump_active = false;
  publish_status();
}

static void ble_disconnect_cb(uint16_t conn_handle, uint8_t reason) {
  (void)conn_handle; (void)reason;
  g_conn = BLE_CONN_HANDLE_INVALID;
  g_dump_active = false;                       // resume on the next request
}

static void time_write_cb(uint16_t conn_hdl, BLECharacteristic *chr,
                          uint8_t *data, uint16_t len) {
  (void)conn_hdl; (void)chr;
  if (len < 8) return;
  uint64_t epoch;
  memcpy(&epoch, data, 8);
  g_req_anchor_epoch = epoch;
  g_req_anchor = true;                         // loop() writes the flash
}

// Control opcodes. Kept as a tiny binary protocol so the app's writes are one
// packet each and there's no parser to get wrong on either side.
static const uint8_t OP_ERASE      = 0x01;
static const uint8_t OP_VIB        = 0x02;   // u8 pct, u8 n, n x u16 ms (on/off/on...)
static const uint8_t OP_SET_HAPTIC = 0x03;   // u8 pct, 3 x u16 meters
static const uint8_t OP_DUMP_START = 0x10;   // u32 start sample index
static const uint8_t OP_DUMP_STOP  = 0x11;

static void control_write_cb(uint16_t conn_hdl, BLECharacteristic *chr,
                             uint8_t *data, uint16_t len) {
  (void)conn_hdl; (void)chr;
  if (len < 1) return;
  switch (data[0]) {
    case OP_ERASE:
      g_dump_active = false;
      g_req_erase = true;
      break;
    case OP_VIB:
      if (len >= 3) {
        uint8_t n = data[2];
        if (n > VIB_MAX_PULSES) n = VIB_MAX_PULSES;
        if (len < 3 + (uint16_t)n * 2) break;
        g_req_vib_pct = data[1];
        for (uint8_t i = 0; i < n; i++) {
          uint16_t ms;
          memcpy(&ms, data + 3 + i * 2, 2);
          g_req_vib_ms[i] = ms;
        }
        g_req_vib_n = n;
        g_req_vib = true;
      }
      break;
    case OP_SET_HAPTIC:
      if (len >= 8) {
        g_haptic_strength = data[1];
        for (int i = 0; i < 3; i++) memcpy(&g_haptic_meters[i], data + 2 + i * 2, 2);
      }
      break;
    case OP_DUMP_START: {
      uint32_t from = 0;
      if (len >= 5) memcpy(&from, data + 1, 4);
      scan_log(&g_dump_pages, NULL, NULL, NULL, NULL);
      g_dump_page = 0;
      g_dump_abs = 0;
      g_dump_off = 0;
      g_dump_have = 0;
      g_dump_page_valid = false;
      g_dump_skip_to = from;
      g_dump_active = true;
      break;
    }
    case OP_DUMP_STOP:
      g_dump_active = false;
      break;
  }
}

// Send the end-of-dump marker: a frame whose index is 0xFFFFFFFF and no
// samples. A sentinel rather than a separate characteristic keeps the phone's
// reassembly a single ordered stream.
static bool notify_dump_end() {
  uint32_t end = 0xFFFFFFFFUL;
  return chrData.notify((uint8_t *)&end, 4);
}

// Push a few frames per loop() pass. notify() returns false when the
// SoftDevice's queue is full, which is our flow control: stop and come back.
static void dump_step() {
  if (!g_dump_active) return;
  if (g_conn == BLE_CONN_HANDLE_INVALID || !chrData.notifyEnabled(g_conn)) {
    g_dump_active = false;
    return;
  }

  uint8_t frame[4 + SAMPLES_PER_PAGE * 12];
  for (int budget = 0; budget < 12; budget++) {
    if (g_dump_off >= g_dump_have) {            // need the next sample page
      if (g_dump_page >= g_dump_pages) {
        if (notify_dump_end()) g_dump_active = false;
        return;
      }
      flash.readBuffer(g_dump_page * PAGE_SIZE, g_dump_page_buf, PAGE_SIZE);
      g_dump_page++;
      uint16_t magic, count;
      memcpy(&magic, g_dump_page_buf, 2);
      memcpy(&count, g_dump_page_buf + 2, 2);
      if (magic != PAGE_MAGIC) { g_dump_have = 0; g_dump_off = 0; continue; }
      if (count > SAMPLES_PER_PAGE) count = SAMPLES_PER_PAGE;
      g_dump_have = count;
      g_dump_off = 0;
      g_dump_page_valid = true;
      continue;
    }

    uint16_t n = g_dump_have - g_dump_off;
    if (n > g_frame_samples) n = g_frame_samples;

    if (g_dump_abs + n <= g_dump_skip_to) {     // resuming: fast-forward
      g_dump_off += n;
      g_dump_abs += n;
      continue;
    }
    if (g_dump_abs < g_dump_skip_to) {          // partial skip inside a page
      uint16_t drop = (uint16_t)(g_dump_skip_to - g_dump_abs);
      g_dump_off += drop;
      g_dump_abs += drop;
      continue;
    }

    memcpy(frame, &g_dump_abs, 4);
    memcpy(frame + 4, g_dump_page_buf + 8 + (uint32_t)g_dump_off * 12,
           (size_t)n * 12);
    if (!chrData.notify(frame, 4 + (uint16_t)n * 12)) return;   // queue full
    g_dump_off += n;
    g_dump_abs += n;
  }
}

static void ble_begin() {
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);   // MTU 247 -> 20 samples/frame
  Bluefruit.begin(1, 0);
  Bluefruit.setTxPower(4);
  Bluefruit.setName("Mokkori IQ");
  Bluefruit.Periph.setConnectCallback(ble_connect_cb);
  Bluefruit.Periph.setDisconnectCallback(ble_disconnect_cb);

  svcLogger.begin();                              // service before its chars

  chrTime.setProperties(CHR_PROPS_WRITE);
  chrTime.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  chrTime.setFixedLen(8);
  chrTime.setWriteCallback(time_write_cb);
  chrTime.begin();

  chrStatus.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  chrStatus.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  chrStatus.setFixedLen(STATUS_LEN);
  chrStatus.begin();

  chrData.setProperties(CHR_PROPS_NOTIFY);
  chrData.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  chrData.setMaxLen(4 + SAMPLES_PER_PAGE * 12);
  chrData.begin();

  chrControl.setProperties(CHR_PROPS_WRITE);
  chrControl.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  chrControl.setMaxLen(16);
  chrControl.setWriteCallback(control_write_cb);
  chrControl.begin();

  publish_status();

  // The 128-bit service UUID fills the advertising packet, so the name goes in
  // the scan response. Advertising the service lets the app scan filtered.
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addService(svcLogger);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);     // fast 20 ms, then 152.5 ms
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);                 // 0 = advertise forever
}

// --- append samples to the flash (never erases) ----------------------------
// Returns true if the flash filled up. Stops when: time limit hit, flash full,
// (stop_on_vbus) USB is plugged in, or a phone connects over BLE.
static bool log_session(uint32_t max_ms, bool stop_on_vbus) {
  uint32_t pages, samples, addr;
  scan_log(&pages, &samples, &addr, NULL, NULL);   // append after existing data
  uint32_t size = flash.size();
  uint16_t seq = (uint16_t)pages;

  uint8_t buf[PAGE_SIZE];
  uint16_t n = 0;
  uint16_t magic = PAGE_MAGIC;
  memset(buf, 0, PAGE_SIZE);
  memcpy(buf, &magic, 2);
  memcpy(buf + 4, &seq, 2);

  const uint32_t period_us = 1000000UL / ODR_HZ;
  uint32_t t0 = millis();
  uint32_t next_us = micros();
  bool full = false;
  bool buzzing = false;

  for (;;) {
    if (addr + PAGE_SIZE > size) { full = true; break; }
    if (max_ms && (millis() - t0) >= max_ms) break;
    if (stop_on_vbus && vbus_present()) break;
    if (g_conn != BLE_CONN_HANDLE_INVALID) break;  // phone is talking to us

    // Periodic feel-test double pulse, non-blocking so sample pacing holds.
    if (BUZZ_PERIOD_S) {
      uint32_t ph = (millis() - t0) % (BUZZ_PERIOD_S * 1000UL);
      bool on = (ph < BUZZ_ON_MS) ||
                (ph >= BUZZ_ON_MS + BUZZ_GAP_MS &&
                 ph < 2 * BUZZ_ON_MS + BUZZ_GAP_MS);
      if (on != buzzing) { buzzing = on; motor_set(on ? 100 : 0); }
    }

    uint32_t now = micros();
    if ((int32_t)(now - next_us) < 0) { yield(); continue; }  // let BLE run
    next_us += period_us;

    int16_t *s = (int16_t *)(buf + 8 + (uint32_t)n * 12);
    s[0] = imu.readRawAccelX();
    s[1] = imu.readRawAccelY();
    s[2] = imu.readRawAccelZ();
    s[3] = imu.readRawGyroX();
    s[4] = imu.readRawGyroY();
    s[5] = imu.readRawGyroZ();
    n++;

    if (n >= SAMPLES_PER_PAGE) {
      memcpy(buf + 2, &n, 2);
      flash.writeBuffer(addr, buf, PAGE_SIZE);
      addr += PAGE_SIZE;
      seq++;
      n = 0;
      memset(buf, 0, PAGE_SIZE);
      memcpy(buf, &magic, 2);
      memcpy(buf + 4, &seq, 2);
      led(0, (seq & 1), 0);                      // blink green while logging
    }
  }

  motor_set(0);                                  // never leave the motor on
  if (n > 0) {                                   // flush partial final page
    memcpy(buf + 2, &n, 2);
    flash.writeBuffer(addr, buf, PAGE_SIZE);
  }
  return full;
}

static void print_help() {
  Serial.println("# commands: INFO | DUMP | TIMES | TIME <epoch_ms> | ERASE | "
                 "TESTLOG <sec> | VIB [ms] [pct] | HELP");
}

static void do_erase() {
  led(0, 0, 1);                                  // blue: erasing
  g_erasing = true;
  publish_status();
  flash.eraseChip();
  flash.waitUntilReady();
  g_erasing = false;
  publish_status();
  led(1, 0, 0);
}

static void handle_command(char *line) {
  if (strncmp(line, "INFO", 4) == 0) {
    print_info();
  } else if (strncmp(line, "DUMP", 4) == 0) {
    dump_log();
  } else if (strncmp(line, "TIMES", 5) == 0) {
    print_times();
  } else if (strncmp(line, "TIME ", 5) == 0) {
    // epoch_ms doesn't fit a long, so take seconds[.ms] and rebuild it.
    char *p = line + 5;
    uint64_t secs = 0;
    while (*p >= '0' && *p <= '9') { secs = secs * 10 + (uint64_t)(*p - '0'); p++; }
    uint64_t epoch_ms = secs * 1000ULL;
    if (*p == '.') {
      uint32_t frac = 0, digits = 0;
      p++;
      while (*p >= '0' && *p <= '9' && digits < 3) { frac = frac * 10 + (*p - '0'); p++; digits++; }
      while (digits < 3) { frac *= 10; digits++; }
      epoch_ms += frac;
    }
    if (secs == 0) { Serial.println("# TIME <unix_seconds[.ms]>"); return; }
    Serial.println(append_anchor(epoch_ms) ? "OK" : "# flash full");
  } else if (strncmp(line, "ERASE", 5) == 0) {
    do_erase();
    Serial.println("ERASED");
  } else if (strncmp(line, "VIB", 3) == 0) {
    int ms = 0, pct = 0;
    sscanf(line + 3, "%d %d", &ms, &pct);
    if (ms <= 0 || ms > 10000) ms = 500;
    if (pct <= 0 || pct > 100) pct = 100;
    Serial.print("# vib "); Serial.print(ms);
    Serial.print("ms "); Serial.print(pct); Serial.println("%");
    motor_set((uint8_t)pct);
    delay((uint32_t)ms);
    motor_set(0);
    Serial.println("OK");
  } else if (strncmp(line, "TESTLOG", 7) == 0) {
    int sec = atoi(line + 7);
    if (sec <= 0) sec = 5;
    Serial.print("# logging "); Serial.print(sec); Serial.println("s ...");
    log_session((uint32_t)sec * 1000UL, false);
    led(1, 0, 0);
    print_info();
  } else if (strncmp(line, "HELP", 4) == 0) {
    print_help();
  } else if (line[0] != '\0') {
    Serial.println("# ? (HELP)");
  }
}

static char cmd[32];
static uint8_t cmd_len = 0;

static void enter_console() {
  g_mode = M_CONSOLE;
  led(1, 0, 0);                                  // red: console / idle
  cmd_len = 0;
  Serial.println("# mokkori flash logger v2 (CONSOLE -- on USB)");
  if (!g_imu_ok) Serial.println("# WARN: IMU init failed");
  if (!g_flash_ok) Serial.println("# WARN: flash init failed");
  print_help();
  print_info();
}

void setup() {
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  led(0, 0, 0);
  pinMode(PIN_MOTOR, OUTPUT);
  digitalWrite(PIN_MOTOR, LOW);                  // motor off until asked

  Serial.begin(115200);

  // Enable the Sense IMU/mic power rail, then configure the sensor.
#ifdef PIN_LSM6DS3TR_C_POWER
  pinMode(PIN_LSM6DS3TR_C_POWER, OUTPUT);
  digitalWrite(PIN_LSM6DS3TR_C_POWER, HIGH);
  delay(10);
#endif
  imu.settings.accelEnabled = 1;
  imu.settings.accelRange = ACCEL_FS_G;
  imu.settings.accelSampleRate = 104;            // internal ODR >= output rate
  imu.settings.gyroEnabled = 1;
  imu.settings.gyroRange = GYRO_FS_DPS;
  imu.settings.gyroSampleRate = 104;
  g_imu_ok = (imu.begin() == 0);

  g_flash_ok = flash.begin();
  if (!g_flash_ok) {                             // QSPI autodetect misses the
    static const SPIFlash_Device_t dev = P25Q16H;  // XIAO's P25Q16H -> explicit
    g_flash_ok = flash.begin(&dev, 1);
  }
  g_jedec = flash.getJEDECID();

  ble_begin();

  // Mode is decided live in loop() from VBUS, so plug/unplug just works.
}

// Work requested over BLE, run here where blocking is safe.
static void service_requests() {
  if (g_req_anchor) {
    g_req_anchor = false;
    append_anchor(g_req_anchor_epoch);
    publish_status();
  }
  if (g_req_erase) {
    g_req_erase = false;
    do_erase();
    if (g_mode == M_FULL) g_mode = M_CONSOLE;    // room again
    publish_status();
  }
  if (g_req_vib) {
    g_req_vib = false;
    uint8_t pct = g_req_vib_pct ? g_req_vib_pct : 100;
    uint8_t n = g_req_vib_n ? g_req_vib_n : 1;
    for (uint8_t i = 0; i < n; i++) {
      uint16_t ms = g_req_vib_ms[i] ? g_req_vib_ms[i] : 200;
      if (ms > 3000) ms = 3000;
      motor_set((i % 2 == 0) ? pct : 0);       // even = on, odd = the gap
      delay(ms);
    }
    motor_set(0);
  }
}

void loop() {
  service_requests();

  // A connected phone owns the device: pause logging, serve BLE, keep the
  // status fresh so the app's gauges move while it watches.
  if (g_conn != BLE_CONN_HANDLE_INVALID) {
    if (g_mode == M_LOGGING) g_mode = M_CONSOLE;
    led(0, 0, 1);                                // blue: talking to the phone
    dump_step();
    static uint32_t last_status = 0;
    uint32_t now = millis();
    // While dumping the progress field moves fast; otherwise once a second is
    // plenty and keeps the battery ADC out of the radio's way.
    if (now - last_status >= (uint32_t)(g_dump_active ? 500 : 1000)) {
      last_status = now;
      publish_status();
    }
    if (!g_dump_active) delay(5);
    return;
  }

  if (vbus_present()) {
    if (g_mode != M_CONSOLE) enter_console();
    while (Serial.available()) {
      char c = (char)Serial.read();
      if (c == '\r') continue;
      if (c == '\n') {
        cmd[cmd_len] = '\0';
        handle_command(cmd);
        cmd_len = 0;
      } else if (cmd_len < sizeof(cmd) - 1) {
        cmd[cmd_len++] = c;
      }
    }
  } else if (g_mode == M_FULL) {
    led(1, 0, 0); delay(200); led(0, 0, 0); delay(200);   // blink: flash full
  } else {
    g_mode = M_LOGGING;
    led(0, 1, 0);
    bool full = log_session(0, true);            // until USB/BLE or full
    if (full) g_mode = M_FULL;
  }
}
