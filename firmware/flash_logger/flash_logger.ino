/*
 * mokkori-iq -- QSPI flash data-logger for the Seeed XIAO nRF52840 Sense.
 *
 * Records the onboard LSM6DS3TR-C 6-axis IMU to the 2 MB QSPI flash so we can
 * collect real crotch-mounted swimming data (no host needed in the pool), then
 * retrieve it over USB at the desk / changing room.
 *
 * The mode follows USB VBUS *live* (no reset needed), which matches the
 * "swim a little -> plug into the laptop -> pull & clear -> swim again" loop:
 *   - USB unplugged (battery) -> LOG: append IMU samples to the flash.
 *   - USB plugged            -> CONSOLE: never logs, accepts commands, so
 *                               plugging in is always safe and ready to dump.
 *
 * Storage is append-only; the flash is cleared ONLY by an explicit ERASE, so
 * unplugging to swim again never destroys data. Samples are raw int16 sensor
 * counts packed into 256-byte pages:
 *     [0:2] magic 0xA55A   [2:4] sample count (1..20)   [4:6] page seq
 *     [6:8] reserved       [8:248] 20 samples x (ax,ay,az,gx,gy,gz) int16 LE
 * The log ends at the first page whose magic isn't 0xA55A (erased = 0xFFFF).
 * Host-side tools/flash_dump.py pulls the stream and converts the raw counts
 * to g / deg-per-second.
 *
 * Console commands (newline-terminated, CONSOLE mode):
 *   INFO            print header + recorded sample/page count + duration
 *   DUMP            stream the recorded samples as raw bytes (see protocol)
 *   ERASE           erase the whole flash (the only way data is cleared)
 *   TESTLOG <sec>   append <sec> seconds now (even on USB) -- bench round-trip
 *   HELP            list commands
 */
#include "LSM6DS3.h"
#include "Wire.h"
#include <SPI.h>
#include <Adafruit_SPIFlash.h>

// ---- sensor configuration (kept in sync with the on-flash data) -----------
static const uint16_t ODR_HZ      = 52;      // sample rate
static const uint16_t ACCEL_FS_G  = 8;       // +/- g
static const uint16_t GYRO_FS_DPS = 2000;    // +/- deg/s

// ---- flash page format ----------------------------------------------------
static const uint32_t PAGE_SIZE        = 256;
static const uint16_t SAMPLES_PER_PAGE = 20;     // 20 * 12 B = 240 B payload
static const uint16_t PAGE_MAGIC       = 0xA55A;

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

static uint16_t read_vbat_mv() {
  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, LOW);               // connect the divider
  pinMode(PIN_VBAT, INPUT);
  analogReference(AR_INTERNAL_3_0);
  analogReadResolution(12);
  delay(3);                                      // let the divider settle
  (void)analogRead(PIN_VBAT);                    // discard first conversion
  uint32_t acc = 0;
  for (int i = 0; i < 16; i++) acc += analogRead(PIN_VBAT);
  digitalWrite(VBAT_ENABLE, HIGH);              // disconnect (stop the leak)
  float raw = acc / 16.0f;
  return (uint16_t)(raw * ADC_REF_MV / ADC_FULL * VBAT_DIVIDER + 0.5f);
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

// --- RGB status LED (common-anode on XIAO: drive LOW to light) --------------
static void led(bool r, bool g, bool b) {
  digitalWrite(LED_RED,   r ? LOW : HIGH);
  digitalWrite(LED_GREEN, g ? LOW : HIGH);
  digitalWrite(LED_BLUE,  b ? LOW : HIGH);
}

// --- scan the log: count valid pages / samples and the next free address ----
// End of log = first page whose magic isn't ours (erased flash reads 0xFFFF).
// Partial pages (count < 20) are allowed mid-log so sessions can be appended.
static void scan_log(uint32_t *out_pages, uint32_t *out_samples,
                     uint32_t *out_end) {
  uint32_t addr = 0, pages = 0, samples = 0, size = flash.size();
  uint8_t hdr[8];
  while (addr + PAGE_SIZE <= size) {
    flash.readBuffer(addr, hdr, 8);
    uint16_t magic;
    memcpy(&magic, hdr, 2);
    if (magic != PAGE_MAGIC) break;             // erased / end of log
    uint16_t count;
    memcpy(&count, hdr + 2, 2);
    if (count == 0 || count > SAMPLES_PER_PAGE) break;   // corrupt -> stop
    pages++;
    samples += count;
    addr += PAGE_SIZE;
  }
  if (out_pages) *out_pages = pages;
  if (out_samples) *out_samples = samples;
  if (out_end) *out_end = addr;
}

static void print_info() {
  uint32_t pages, samples;
  scan_log(&pages, &samples, NULL);
  float secs = (float)samples / (float)ODR_HZ;
  Serial.println("# mokkori flash logger v1");
  Serial.print("# odr_hz="); Serial.print(ODR_HZ);
  Serial.print(" accel_fs_g="); Serial.print(ACCEL_FS_G);
  Serial.print(" gyro_fs_dps="); Serial.println(GYRO_FS_DPS);
  Serial.print("# flash_ok="); Serial.print(g_flash_ok);
  Serial.print(" jedec=0x"); Serial.println(g_jedec, HEX);
  Serial.print("# flash_size="); Serial.print(flash.size());
  Serial.print(" pages="); Serial.print(pages);
  Serial.print(" samples="); Serial.print(samples);
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
static void dump_log() {
  uint32_t pages, samples;
  scan_log(&pages, &samples, NULL);
  Serial.print("DUMP_BEGIN ");
  Serial.print(samples);
  Serial.println(" 12");
  Serial.flush();

  uint8_t page[PAGE_SIZE];
  uint32_t addr = 0;
  for (uint32_t p = 0; p < pages; p++) {
    flash.readBuffer(addr, page, PAGE_SIZE);
    uint16_t count;
    memcpy(&count, page + 2, 2);
    if (count > SAMPLES_PER_PAGE) count = SAMPLES_PER_PAGE;
    Serial.write(page + 8, (size_t)count * 12);
    Serial.flush();
    addr += PAGE_SIZE;
  }
  Serial.println();
  Serial.println("DUMP_END");
}

// --- append samples to the flash (never erases) ----------------------------
// Returns true if the flash filled up. Stops when: time limit hit, flash full,
// or (stop_on_vbus) USB is plugged in.
static bool log_session(uint32_t max_ms, bool stop_on_vbus) {
  uint32_t pages, samples, addr;
  scan_log(&pages, &samples, &addr);            // append after existing data
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

  for (;;) {
    if (addr + PAGE_SIZE > size) { full = true; break; }
    if (max_ms && (millis() - t0) >= max_ms) break;
    if (stop_on_vbus && vbus_present()) break;

    uint32_t now = micros();
    if ((int32_t)(now - next_us) < 0) continue;
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

  if (n > 0) {                                   // flush partial final page
    memcpy(buf + 2, &n, 2);
    flash.writeBuffer(addr, buf, PAGE_SIZE);
  }
  return full;
}

static void print_help() {
  Serial.println("# commands: INFO | DUMP | ERASE | TESTLOG <sec> | HELP");
}

static void do_erase() {
  led(0, 0, 1);                                  // blue: erasing
  flash.eraseChip();
  flash.waitUntilReady();
  led(1, 0, 0);
}

static void handle_command(char *line) {
  if (strncmp(line, "INFO", 4) == 0) {
    print_info();
  } else if (strncmp(line, "DUMP", 4) == 0) {
    dump_log();
  } else if (strncmp(line, "ERASE", 5) == 0) {
    do_erase();
    Serial.println("ERASED");
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
  Serial.println("# mokkori flash logger v1 (CONSOLE -- on USB)");
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

  // Mode is decided live in loop() from VBUS, so plug/unplug just works.
}

void loop() {
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
    bool full = log_session(0, true);            // until USB appears or full
    if (full) g_mode = M_FULL;
  }
}
