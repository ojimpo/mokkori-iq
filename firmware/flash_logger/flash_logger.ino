/*
 * mokkori-iq -- QSPI flash data-logger for the Seeed XIAO nRF52840 Sense.
 *
 * Records the onboard LSM6DS3TR-C 6-axis IMU to the 2 MB QSPI flash so we can
 * collect real crotch-mounted swimming data (no host needed in the pool), then
 * retrieve it over USB at the desk.
 *
 * Mode is chosen automatically at boot from USB VBUS:
 *   - on battery (no VBUS) -> LOG mode: erase flash, then stream IMU to flash
 *     until full or power-off. Slide switch on the LiPo is the on/off control.
 *   - on USB  (VBUS present) -> CONSOLE mode: never logs; accepts commands so
 *     plugging in is always safe.
 *
 * Storage: raw int16 sensor counts, packed into 256-byte pages:
 *     [0:2] magic 0xA55A   [2:4] sample count (1..20)   [4:6] page seq
 *     [6:8] reserved       [8:248] 20 samples x (ax,ay,az,gx,gy,gz) int16 LE
 * The flash is fully erased before a session, so the log ends at the first page
 * whose magic isn't 0xA55A. Host-side tools/flash_dump.py pulls the stream and
 * converts the raw counts to g / deg-per-second.
 *
 * Console commands (newline-terminated, CONSOLE mode):
 *   INFO            print header + recorded sample/page count + duration
 *   DUMP            stream the recorded samples as raw bytes (see protocol)
 *   ERASE           erase the whole flash
 *   TESTLOG <sec>   record <sec> seconds now (even on USB) -- bench round-trip
 *   HELP            list commands
 */
#include "LSM6DS3.h"
#include "Wire.h"
#include <SPI.h>
#include <Adafruit_SPIFlash.h>

// ---- sensor configuration (kept in sync with the on-flash data) -----------
static const uint16_t ODR_HZ       = 52;     // sample rate
static const uint16_t ACCEL_FS_G   = 8;      // +/- g
static const uint16_t GYRO_FS_DPS  = 2000;   // +/- deg/s

// ---- flash page format ----------------------------------------------------
static const uint32_t PAGE_SIZE        = 256;
static const uint16_t SAMPLES_PER_PAGE = 20;     // 20 * 12 B = 240 B payload
static const uint16_t PAGE_MAGIC       = 0xA55A;

LSM6DS3 imu(I2C_MODE, 0x6A);
Adafruit_FlashTransport_QSPI flashTransport;     // uses the variant's QSPI pins
Adafruit_SPIFlash flash(&flashTransport);

static bool console_mode = false;
static bool g_flash_ok = false;
static uint32_t g_jedec = 0;

// --- USB VBUS: present means we're plugged into a host / charger -----------
static bool vbus_present() {
  return (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0;
}

// --- RGB status LED (common-anode on XIAO: drive LOW to light) --------------
static void led(bool r, bool g, bool b) {
  digitalWrite(LED_RED,   r ? LOW : HIGH);
  digitalWrite(LED_GREEN, g ? LOW : HIGH);
  digitalWrite(LED_BLUE,  b ? LOW : HIGH);
}

// --- scan the log: count valid pages / samples, return bytes end address ----
static void scan_log(uint32_t *out_pages, uint32_t *out_samples) {
  uint32_t addr = 0, pages = 0, samples = 0;
  uint8_t hdr[8];
  uint32_t size = flash.size();
  while (addr + PAGE_SIZE <= size) {
    flash.readBuffer(addr, hdr, 8);
    uint16_t magic;
    memcpy(&magic, hdr, 2);
    if (magic != PAGE_MAGIC) break;            // erased / end of log
    uint16_t count;
    memcpy(&count, hdr + 2, 2);
    if (count == 0 || count > SAMPLES_PER_PAGE) break;
    pages++;
    samples += count;
    addr += PAGE_SIZE;
    if (count < SAMPLES_PER_PAGE) break;        // partial page = last page
  }
  *out_pages = pages;
  *out_samples = samples;
}

static void print_info() {
  uint32_t pages, samples;
  scan_log(&pages, &samples);
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
  Serial.println("OK");
}

// --- stream the recorded samples as raw bytes ------------------------------
// Protocol:  "DUMP_BEGIN <nsamples> 12\n" then nsamples*12 raw bytes then
//            "\nDUMP_END\n".  Each sample = ax,ay,az,gx,gy,gz int16 LE.
static void dump_log() {
  uint32_t pages, samples;
  scan_log(&pages, &samples);
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

// --- record to flash. max_ms==0 => until full (or VBUS lost on battery) -----
static void run_log(uint32_t max_ms, bool stop_on_vbus) {
  led(0, 0, 1);                       // blue: erasing
  flash.eraseChip();
  flash.waitUntilReady();

  uint32_t size = flash.size();
  uint32_t addr = 0;
  uint16_t seq = 0;
  uint8_t buf[PAGE_SIZE];
  uint16_t n = 0;

  memset(buf, 0, PAGE_SIZE);
  uint16_t magic = PAGE_MAGIC;
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
      led(0, (seq & 1), 0);            // blink green while logging
    }
  }

  if (n > 0) {                          // flush partial final page
    memcpy(buf + 2, &n, 2);
    flash.writeBuffer(addr, buf, PAGE_SIZE);
    seq++;
  }
  led(full ? 1 : 0, full ? 0 : 1, 0);  // red solid if full, else green
}

static void print_help() {
  Serial.println("# commands: INFO | DUMP | ERASE | TESTLOG <sec> | HELP");
}

// --- console command handling ----------------------------------------------
static char cmd[32];
static uint8_t cmd_len = 0;

static void handle_command(char *line) {
  if (strncmp(line, "INFO", 4) == 0) {
    print_info();
  } else if (strncmp(line, "DUMP", 4) == 0) {
    dump_log();
  } else if (strncmp(line, "ERASE", 5) == 0) {
    led(0, 0, 1);
    flash.eraseChip();
    flash.waitUntilReady();
    led(1, 0, 0);
    Serial.println("ERASED");
  } else if (strncmp(line, "TESTLOG", 7) == 0) {
    int sec = atoi(line + 7);
    if (sec <= 0) sec = 5;
    Serial.print("# logging "); Serial.print(sec); Serial.println("s ...");
    run_log((uint32_t)sec * 1000UL, false);
    led(1, 0, 0);                       // back to console (red)
    print_info();
  } else if (strncmp(line, "HELP", 4) == 0) {
    print_help();
  } else if (line[0] != '\0') {
    Serial.println("# ? (HELP)");
  }
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
  imu.settings.accelSampleRate = 104;       // internal ODR >= output rate
  imu.settings.gyroEnabled = 1;
  imu.settings.gyroRange = GYRO_FS_DPS;
  imu.settings.gyroSampleRate = 104;
  bool imu_ok = (imu.begin() == 0);

  g_flash_ok = flash.begin();
  if (!g_flash_ok) {                          // fall back to explicit device
    static const SPIFlash_Device_t dev = P25Q16H;
    g_flash_ok = flash.begin(&dev, 1);
  }
  g_jedec = flash.getJEDECID();

  console_mode = vbus_present();

  if (console_mode) {
    uint32_t t0 = millis();
    while (!Serial && (millis() - t0) < 3000) {
    }
    led(1, 0, 0);                            // red: console/idle
    Serial.println("# mokkori flash logger v1 (CONSOLE -- on USB)");
    if (!imu_ok) Serial.println("# WARN: IMU init failed");
    if (!g_flash_ok) Serial.println("# WARN: flash init failed");
    print_help();
    print_info();
  } else {
    // Battery: log until full or power-off. Stop if USB shows up (bench edge).
    run_log(0, true);
  }
}

void loop() {
  if (!console_mode) {
    delay(100);                              // logging finished -> idle
    return;
  }
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
}
