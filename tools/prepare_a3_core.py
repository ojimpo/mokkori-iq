#!/usr/bin/env python3
"""Patch only the exact official Seeeduino:nrf52@1.1.13 core, in a private install.
No download, flashing or other external action. Refuses unknown source revisions.
"""
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
 'cores/nRF5/wiring.c': '9f34333d2f7bd98542e3e74bdc94c247e4633c54c52fa2f0dc93c335c8db0791',
 'variants/Seeed_XIAO_nRF52840_Sense/variant.cpp': '808b26ec190cd802861bb0fbfa048623248c4c864c766b83ca8972bdfdade2ac',
 'variants/Seeed_XIAO_nRF52840_Sense/variant.h': '099cdf030482f2037ea92a1b79c87df87a0f7b3fea54abafba4ada923d4d8264',
}
marker = 'MOKKORI_A3_SAFE_CORE_20261005'
source = {}
for name, digest in expected.items():
    p = root / name
    data = p.read_bytes()
    if marker in data.decode():
        backup = p.with_suffix(p.suffix + '.a3-original')
        data = backup.read_bytes()  # regenerate exact patch; do not trust marker alone
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit('Refusing unexpected core source: ' + str(p))
    source[name] = data.decode()

w = source['cores/nRF5/wiring.c']
early = '''
#if defined(ARDUINO_Seeed_XIAO_nRF52840_Sense)
  // MOKKORI_A3_SAFE_CORE_20261005: first application-core action.
  // Remove peripheral drive before GPIO, including a retained/bootloader PWM.
  // Preload LOW before releasing any peripheral's ownership of these pads.
  NRF_P0->OUTCLR = (1UL << 2) | (1UL << 14); // D0 MOTOR_EN, READ_BAT_ENABLE
  NRF_P1->OUTCLR = (1UL << 15); // D10 MOTOR_PWM
  NRF_PWM_Type *pwm[] = { NRF_PWM0, NRF_PWM1, NRF_PWM2, NRF_PWM3 };
  for (unsigned i = 0; i < 4; ++i) {
    pwm[i]->ENABLE = 0;
    for (unsigned ch = 0; ch < 4; ++ch) pwm[i]->PSEL.OUT[ch] = 0xFFFFFFFFUL;
  }
  NRF_P1->PIN_CNF[15] = 3; // GPIO output, input disconnected, no pull
  NRF_P0->PIN_CNF[2] = 3;
  NRF_P0->PIN_CNF[14] = 3; // always sink the battery-divider low leg
  NRF_P0->PIN_CNF[13] = 2; // HICHG input/high-Z, buffer off, no pulls (~50mA)
#endif
'''
w = w.replace('void init( void )\n{', 'void init( void )\n{' + early, 1)
w = w.replace('NRF_P0->OUTSET = UINT32_MAX;', '''#if defined(ARDUINO_Seeed_XIAO_nRF52840_Sense)
  NRF_P0->OUTSET = UINT32_MAX & ~((1UL << 2) | (1UL << 14));
#else
  NRF_P0->OUTSET = UINT32_MAX;
#endif''', 1)
w = w.replace('NRF_P1->OUTSET = UINT32_MAX;', '''#if defined(ARDUINO_Seeed_XIAO_nRF52840_Sense)
  NRF_P1->OUTSET = UINT32_MAX & ~(1UL << 15);
#else
  NRF_P1->OUTSET = UINT32_MAX;
#endif''', 1)
w += '\n// MOKKORI_A3_SAFE_CORE_20261005: link guard for the patched init path.\nvoid mokkori_a3_core_guard_20261005(void) {}\n'
source['cores/nRF5/wiring.c'] = w
vpath = 'variants/Seeed_XIAO_nRF52840_Sense/variant.cpp'
v = source[vpath]
v = v.replace('    // Disable reading of the BAT voltage.', '    // MOKKORI_A3_SAFE_CORE_20261005: keep the divider low leg grounded.')
v = v.replace('    pinMode(VBAT_ENABLE, OUTPUT);\n    digitalWrite(VBAT_ENABLE, HIGH);', '    digitalWrite(VBAT_ENABLE, LOW);\n    pinMode(VBAT_ENABLE, OUTPUT);')
v += '\nextern "C" void mokkori_a3_variant_guard_20261005(void) {}\n'
source[vpath] = v
hpath = 'variants/Seeed_XIAO_nRF52840_Sense/variant.h'
source[hpath] += '\n// Private A3 build marker; matching link guards are required too.\n#define MOKKORI_A3_SAFE_CORE_20261005 1\n'
for name, content in source.items():
    p = root / name
    backup = p.with_suffix(p.suffix + '.a3-original')
    if not backup.exists():
        backup.write_bytes(p.read_bytes())
    p.write_text(content)
    print(hashlib.sha256(p.read_bytes()).hexdigest(), name)
