#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "../../firmware/flash_logger/a3_policy.h"
using a3::Policy;
static void settle(Policy& p, uint32_t base, bool vbus=false, bool det=false) {
  p.sample(base+10,vbus,det,true); p.sample(base+20,vbus,det,true);
  p.sample(base+600,vbus,det,true); p.sample(base+1600,vbus,det,true);
}
int main() {
  Policy p;
  assert(!p.motor_allowed() && !p.normal_log_allowed() && !p.can_sleep());
  p.begin(0); p.sample(0,false,false,true);
  assert(p.vbus.stable==a3::Level::Unknown && !p.motor_allowed());
  p.sample(9,false,false,true); assert(!p.power_absent());
  p.sample(10,false,false,true); assert(!p.power_absent());
  p.sample(19,false,false,true); assert(!p.power_absent());
  p.sample(20,false,false,true); assert(p.power_absent() && !p.motor_allowed());
  p.sample(600,false,false,true); p.sample(1599,false,false,true); assert(!p.motor_allowed());
  p.sample(1600,false,false,true); assert(p.motor_allowed() && !p.normal_log_allowed());
  p.run_requested=true; assert(p.normal_log_allowed() && !p.can_sleep());
  p.sample(1700,false,true,true); assert(!p.motor_allowed() && p.normal_log_allowed());
  p.sample(1800,false,false,true); assert(!p.motor_allowed() && p.normal_log_allowed());
  p.sample(2799,false,false,true); assert(!p.motor_allowed());
  p.sample(2800,false,false,true); assert(p.motor_allowed());
  p.sample(3000,false,true,true); p.sample(4000,false,true,true);
  assert(!p.motor_allowed() && p.normal_log_allowed()); // sustained wet/dock
  p.sample(4100,true,true,true); assert(!p.motor_allowed() && !p.normal_log_allowed());
  p.sample(4110,true,true,true); assert(!p.power_absent());
  p.sample(4200,false,true,true); p.sample(4209,false,true,true); assert(!p.power_absent());
  p.sample(4210,false,true,true); assert(p.normal_log_allowed());
  p.run_requested=false; assert(p.can_sleep() && !p.wake_high()); // remove wake
  p.sample(4300,false,false,true); assert(!p.can_sleep());
  p.sample(5300,false,false,true); assert(p.can_sleep() && p.wake_high()); // attach wake
  p.sample(5400,false,false,false); assert(!p.motor_allowed() && !p.can_sleep());
  p.sample(5500,false,false,true); assert(!p.motor_allowed()); // requalification
  p.sample(6500,false,false,true); assert(p.motor_allowed());
  p.begin(6600); settle(p,6600); assert(!p.run_requested && !p.normal_log_allowed());
  Policy wrap; const uint32_t b=UINT32_MAX-500;
  wrap.begin(b); settle(wrap,b); assert(wrap.motor_allowed()); // millis wrap
  Policy powered; powered.begin(0); settle(powered,0,true,false);
  powered.run_requested=true; assert(!powered.motor_allowed() && !powered.normal_log_allowed());
  assert(!a3::detached_after_dock(false,a3::Level::Low)); // undocked manual OFF
  assert(!a3::detached_after_dock(true,a3::Level::Unknown)); // bounce waits
  assert(!a3::detached_after_dock(true,a3::Level::High)); // still docked
  assert(a3::detached_after_dock(true,a3::Level::Low)); // powered removal stays awake
  puts("PASS: startup/settling, wet bounce/sustained DET, VBUS, no autostart, wake levels, IO fault, wraparound");
}
