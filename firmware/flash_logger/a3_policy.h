#ifndef MOKKORI_A3_POLICY_H
#define MOKKORI_A3_POLICY_H
#include <stdint.h>

// Pure policy, shared by target firmware and host tests. Values are initial
// dry-bench candidates, not validated contact thresholds or water detection.
namespace a3 {
enum class Level : uint8_t { Unknown, Low, High };
struct StableInput {
  Level stable = Level::Unknown;
  bool raw = false, seen = false;
  uint32_t changed = 0;
  void sample(bool value, uint32_t now, uint32_t debounce_ms) {
    if (!seen || value != raw) {
      raw = value; changed = now; seen = true;
      stable = Level::Unknown; // never retain stale 'safe' through a transition
    }
    if (uint32_t(now - changed) >= debounce_ms)
      stable = raw ? Level::High : Level::Low;
  }
};
// A standby request made while a powered dock keeps us awake must not put
// the device to sleep just after the user removes it from that dock.
inline bool detached_after_dock(bool seen_dock, Level det) {
  return seen_dock && det == Level::Low;
}
struct Policy {
  static constexpr uint32_t VBUS_SETTLE_MS = 10;
  static constexpr uint32_t VBUS_DEBOUNCE_MS = 10;
  static constexpr uint32_t DET_SETTLE_MS = 600;
  static constexpr uint32_t DET_DEBOUNCE_MS = 1000;
  StableInput vbus, det;
  bool configured = false, run_requested = false, io_ok = false;
  bool raw_vbus = true, raw_det = true;
  uint32_t initialized = 0;
  void begin(uint32_t now) {
    *this = Policy(); initialized = now; configured = true;
  }
  void sample(uint32_t now, bool vbus_present, bool det_high, bool pins_ok) {
    raw_vbus = vbus_present; raw_det = det_high; io_ok = pins_ok;
    if (!configured || !pins_ok) {
      vbus = StableInput(); det = StableInput();
      return;
    }
    if (uint32_t(now - initialized) >= VBUS_SETTLE_MS)
      vbus.sample(vbus_present, now, VBUS_DEBOUNCE_MS);
    if (uint32_t(now - initialized) >= DET_SETTLE_MS)
      det.sample(det_high, now, DET_DEBOUNCE_MS);
  }
  bool power_absent() const {
    return configured && io_ok && !raw_vbus && vbus.stable == Level::Low;
  }
  bool motor_allowed() const {
    return power_absent() && !raw_det && det.stable == Level::Low;
  }
  bool normal_log_allowed() const {
    // Deliberate prototype policy: DET alone never ends a recording. A wet
    // bridge and unpowered dock cannot be distinguished by these contacts.
    return run_requested && power_absent();
  }
  bool can_sleep() const {
    return !run_requested && power_absent() && det.stable != Level::Unknown;
  }
  bool wake_high() const { return det.stable == Level::Low; }
};
}
#endif
