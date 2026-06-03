/*
 * mokkori-iq -- IMU bring-up firmware for the Seeed XIAO nRF52840 Sense.
 *
 * Streams the onboard LSM6DS3TR-C 6-axis IMU over the USB CDC serial port as
 * CSV, one line per sample:
 *
 *     millis,ax,ay,az,gx,gy,gz
 *
 * Accelerometer in g, gyroscope in deg/s. This is the "Hello IMU" step: use it
 * to confirm the sensor talks, to see which way the axes point when the board
 * is mounted in the swimsuit, and to sanity-check the real sample rate before
 * building the QSPI flash data-logger.
 *
 * Phase 0 (the Python detector) was tuned on WRIST data at 30 Hz; the real
 * device is crotch-mounted, so the numbers coming out of here are our first
 * look at what the signal actually looks like in the target position.
 */
#include "LSM6DS3.h"
#include "Wire.h"

// The Sense's onboard LSM6DS3TR-C sits on the internal I2C bus at address 0x6A.
LSM6DS3 imu(I2C_MODE, 0x6A);

// Output cadence. The sensor is configured to run faster internally; we just
// pace how often we read-and-print so the serial link isn't flooded.
static const uint32_t ODR_HZ = 104;
static const uint32_t PERIOD_US = 1000000UL / ODR_HZ;
static uint32_t next_us = 0;

void setup() {
  Serial.begin(115200);
  // Wait a little for the USB CDC host to attach, but don't hang forever -- we
  // want this to still run when powered from a battery with no host.
  uint32_t t0 = millis();
  while (!Serial && (millis() - t0) < 3000) {
  }

  // On the Sense variant the IMU (and mic) sit on a switchable power rail that
  // must be driven high before the sensor will answer. The macro is defined in
  // the board's variant.h; guard it so the sketch still builds elsewhere.
#ifdef PIN_LSM6DS3TR_C_POWER
  pinMode(PIN_LSM6DS3TR_C_POWER, OUTPUT);
  digitalWrite(PIN_LSM6DS3TR_C_POWER, HIGH);
  delay(10);
#endif

  // Configure ranges/rates explicitly so logged data is reproducible.
  imu.settings.accelEnabled = 1;
  imu.settings.accelRange = 8;          // +/- 8 g  (push-off / flip spikes)
  imu.settings.accelSampleRate = 104;   // Hz
  imu.settings.gyroEnabled = 1;
  imu.settings.gyroRange = 2000;        // +/- 2000 dps (fast body roll / flip)
  imu.settings.gyroSampleRate = 104;    // Hz

  if (imu.begin() != 0) {
    Serial.println("# ERROR: LSM6DS3 init failed");
  } else {
    Serial.println("# LSM6DS3 OK (accel +/-8g, gyro +/-2000dps, 104Hz)");
  }
  Serial.println("# millis,ax,ay,az,gx,gy,gz  (acc g, gyro dps)");
  next_us = micros();
}

void loop() {
  // Fixed-rate, rollover-safe scheduler.
  uint32_t now = micros();
  if ((int32_t)(now - next_us) < 0) {
    return;
  }
  next_us += PERIOD_US;

  float ax = imu.readFloatAccelX();
  float ay = imu.readFloatAccelY();
  float az = imu.readFloatAccelZ();
  float gx = imu.readFloatGyroX();
  float gy = imu.readFloatGyroY();
  float gz = imu.readFloatGyroZ();

  Serial.print(millis());
  Serial.print(',');
  Serial.print(ax, 4);
  Serial.print(',');
  Serial.print(ay, 4);
  Serial.print(',');
  Serial.print(az, 4);
  Serial.print(',');
  Serial.print(gx, 2);
  Serial.print(',');
  Serial.print(gy, 2);
  Serial.print(',');
  Serial.println(gz, 2);
}
