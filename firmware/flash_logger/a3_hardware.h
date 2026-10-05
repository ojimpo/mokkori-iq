#ifndef MOKKORI_A3_HARDWARE_H
#define MOKKORI_A3_HARDWARE_H
#include <Arduino.h>
#include <nrf_gpio.h>
#include <HardwarePWM.h>
#include "a3_policy.h"

#if !defined(ARDUINO_Seeed_XIAO_nRF52840_Sense) || !defined(MOKKORI_A3_SAFE_CORE_20261005)
#error "A3 requires the patched Seeeduino:nrf52@1.1.13 Sense core; see docs/a3/BRINGUP.md"
#endif
// This deliverable is a dry-bench image. No motor-enabled image is supplied.
// Enabling requires the separate physical electrical/current acceptance gates.
#ifndef A3_ENABLE_MOTOR
#define A3_ENABLE_MOTOR 0
#endif
extern "C" void mokkori_a3_core_guard_20261005(void);
extern "C" void mokkori_a3_variant_guard_20261005(void);
static a3::Policy g_a3;
static bool g_a3_io_fault = false;
static volatile bool g_a3_motor_stop_requested = false;
static uint32_t g_a3_reset_reason = 0;
static const uint32_t A3_EN = NRF_GPIO_PIN_MAP(0,2);
static const uint32_t A3_PWM = NRF_GPIO_PIN_MAP(1,15);
static const uint32_t A3_DET = NRF_GPIO_PIN_MAP(0,28);
static const uint32_t A3_VBUS_N = NRF_GPIO_PIN_MAP(1,12);
static const uint8_t A3_PWM_ARDUINO = 10;

static void a3_motor_off() {
  // Cut the rail first; analogWrite(0) alone does not detach peripheral drive.
  nrf_gpio_pin_clear(A3_EN);
  nrf_gpio_pin_clear(A3_PWM);
  for (unsigned i = 0; i < HWPWM_MODULE_NUM; ++i) {
    if (HwPWMx[i]->checkPin(A3_PWM_ARDUINO)) {
      HwPWMx[i]->removePin(A3_PWM_ARDUINO);
      if (HwPWMx[i]->usedChannelCount() == 0) HwPWMx[i]->stop();
    }
  }
  nrf_gpio_cfg_output(A3_PWM);
  nrf_gpio_cfg_output(A3_EN);
  nrf_gpio_pin_clear(A3_PWM);
  nrf_gpio_pin_clear(A3_EN);
}
static bool a3_raw_vbus() {
  // POWER is SoftDevice-owned after Bluefruit.begin(). Fail inhibited.
  uint8_t enabled = 0;
  uint32_t usb = 0;
  if (sd_softdevice_is_enabled(&enabled) != NRF_SUCCESS) return true;
  if (enabled) {
    if (sd_power_usbregstatus_get(&usb) != NRF_SUCCESS) return true;
  } else usb = NRF_POWER->USBREGSTATUS;
  return !nrf_gpio_pin_read(A3_VBUS_N) || (usb & POWER_USBREGSTATUS_VBUSDETECT_Msk);
}
static bool a3_pins_ok() {
  const uint32_t mask = GPIO_PIN_CNF_DIR_Msk | GPIO_PIN_CNF_INPUT_Msk | GPIO_PIN_CNF_PULL_Msk;
  const uint32_t pullup_input = (GPIO_PIN_CNF_PULL_Pullup << GPIO_PIN_CNF_PULL_Pos);
  bool ok = ((NRF_P1->PIN_CNF[12] & mask) == pullup_input) &&
    ((NRF_P0->PIN_CNF[28] & mask) == 0) &&
    ((NRF_P0->PIN_CNF[13] & (GPIO_PIN_CNF_DIR_Msk | GPIO_PIN_CNF_PULL_Msk)) == 0) &&
    ((NRF_P0->PIN_CNF[14] & GPIO_PIN_CNF_DIR_Msk) != 0) &&
    ((NRF_P0->OUT & (1UL << 14)) == 0);
  if ((NRF_UARTE0->ENABLE && NRF_UARTE0->PSEL.RXD == A3_VBUS_N) ||
      (NRF_UARTE1->ENABLE && NRF_UARTE1->PSEL.RXD == A3_VBUS_N)) ok = false;
  return ok;
}
static void a3_poll() {
  if (!a3_pins_ok()) g_a3_io_fault = true; // reset required after pin theft
  g_a3.sample(millis(), a3_raw_vbus(), nrf_gpio_pin_read(A3_DET), !g_a3_io_fault);
  if (!g_a3.motor_allowed() || g_a3_motor_stop_requested) a3_motor_off();
}
static void a3_begin() {
  a3_motor_off(); // first sketch action, before LEDs, Serial, IMU or BLE
  mokkori_a3_core_guard_20261005();
  mokkori_a3_variant_guard_20261005();
  g_a3_reset_reason = readResetReason(); // core has already cleared RESETREAS
  nrf_gpio_cfg_input(NRF_GPIO_PIN_MAP(0,13), NRF_GPIO_PIN_NOPULL);
  nrf_gpio_pin_clear(NRF_GPIO_PIN_MAP(0,14));
  nrf_gpio_cfg_output(NRF_GPIO_PIN_MAP(0,14)); // never drive HIGH, even OFF
  nrf_gpio_cfg_input(A3_VBUS_N, NRF_GPIO_PIN_PULLUP); // R8 is absent
  nrf_gpio_cfg_input(A3_DET, NRF_GPIO_PIN_NOPULL); // R5 is external
  nrf_gpio_cfg_input(NRF_GPIO_PIN_MAP(0,3), NRF_GPIO_PIN_NOPULL); // unused D1
  nrf_gpio_cfg_input(NRF_GPIO_PIN_MAP(0,29), NRF_GPIO_PIN_NOPULL); // unused D3
  nrf_gpio_cfg_input(NRF_GPIO_PIN_MAP(0,4), NRF_GPIO_PIN_NOPULL); // unused D4
  g_a3_io_fault = g_ADigitalPinMap[0] != A3_EN || g_ADigitalPinMap[2] != A3_DET ||
    g_ADigitalPinMap[7] != A3_VBUS_N || g_ADigitalPinMap[10] != A3_PWM ||
    g_ADigitalPinMap[VBAT_ENABLE] != 14 || g_ADigitalPinMap[PIN_VBAT] != 31 ||
    g_ADigitalPinMap[PIN_CHARGING_CURRENT] != 13;
  g_a3.begin(millis()); // VBUS/DET remain UNKNOWN until polling qualifies them
  a3_poll();
}
static bool a3_motor_set(uint8_t pct) {
  a3_poll();
  if (!pct || !A3_ENABLE_MOTOR || !g_a3.motor_allowed() || g_a3_motor_stop_requested) {
    a3_motor_off(); return pct == 0;
  }
  if (pct > 100) pct = 100;
  // Start with PWM low; raise the separate 3.0V LDO enable only after checks.
  nrf_gpio_pin_set(A3_EN);
  analogWrite(A3_PWM_ARDUINO, (uint16_t)pct * 255 / 100);
  return true;
}
static void a3_checked_delay(uint32_t duration) {
  const uint32_t start = millis();
  do { a3_poll(); delay(1); } while (uint32_t(millis() - start) < duration);
}
static bool a3_motor_delay(uint32_t duration) {
  const uint32_t start = millis();
  do {
    a3_poll();
    if (g_a3_motor_stop_requested || !g_a3.motor_allowed()) return false;
    delay(1);
  } while (uint32_t(millis() - start) < duration);
  return true;
}
#endif
