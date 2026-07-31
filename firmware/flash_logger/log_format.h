// On-flash log format shared with the host tools (tools/flash_dump.py).
//
// This lives in a header rather than the .ino because the Arduino build
// generates function prototypes right after the includes: a struct declared in
// the sketch body isn't visible yet, and any function taking one gets a bogus
// prototype (which then collides with the real definition).
#pragma once
#include <stdint.h>

static const uint32_t PAGE_SIZE        = 256;
static const uint16_t SAMPLES_PER_PAGE = 20;     // 20 * 12 B = 240 B payload
static const uint16_t PAGE_MAGIC       = 0xA55A; // sample page
static const uint16_t ANCHOR_MAGIC     = 0xA55B; // time anchor, carries 0 samples

// A time anchor says "sample K was taken at epoch E". The nRF52 has no clock
// across a power cycle, so the phone hands us one and the host reconstructs
// absolute time for every sample as E + (i - K) * 1000 / ODR.
struct Anchor {
  uint64_t epoch_ms;
  uint32_t sample_index;
  uint32_t millis_at_sync;
};
