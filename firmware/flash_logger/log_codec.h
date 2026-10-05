// On-flash sample compression, shared by the firmware and the host test
// (tools/codec_shim.c -> tools/codec_check.py). Plain C, no Arduino headers,
// so the exact code that runs on the device can be exercised on the Mac.
//
// Why: the flash holds 163,840 raw samples = 53 minutes at 52 Hz, but a public
// pool session is a 2-hour slot. Dropping to 13 Hz would fit and was measured
// to give identical reports, but it throws the high-frequency content away for
// good, which fights the "keep the raw data so a better detector can reprocess
// old sessions" policy. Compression keeps the full bandwidth instead.
//
// The scheme (measured in analysis/compress_check.py against both real
// sessions): first-order delta -> zigzag -> Rice coding, with the low
// MK_DROP_BITS bits discarded first. Truncation is what gets us past the
// lossless floor (~95 min); 2 bits is below the sensor's own noise -- the
// accelerometer's noise RMS is ~0.46 mg against a 0.28 mg quantisation step --
// so it costs resolution we never had, not bandwidth.
//
// Records stay self-contained (each re-anchors with one absolute sample), which
// is what keeps a half-written flash readable -- the property the raw format
// has and must not lose. A record is MK_UNIT-sized (the flash's program page)
// or a small multiple of it: the 24-byte header costs 0.55 B/sample amortised
// over one 256-byte page but only 0.14 over four, and that difference is worth
// about ten minutes of recording time.
//
//   [0:2]   magic 0xA55C      [2:4] sample count   [4:6] record seq
//   [6]     drop_bits         [7]   record length in MK_UNIT units
//   [8:12]  reserved
//   [12:24] first sample, 6 x int16 LE (already shifted down by drop_bits)
//   [24:]   Rice bitstream, MSB first, sample-major (all 6 axes per sample),
//           restarted every MK_BLOCK samples with 6 x 4 bits of fresh Rice k
//
// The k values are re-picked per block rather than per record because a single
// k over a whole record is what stopped larger records from paying off: the
// header gets amortised but the code stops fitting the signal (measured -- 1 KB
// records with one k are no better than 512 B ones). 24 bits per 64 samples
// buys back the locality for 0.05 B/sample.
//
// Raw pages (0xA55A) are still decoded, so a firmware update doesn't require
// erasing whatever is already on the device.
#pragma once
#include <stdint.h>
#include <string.h>

#define MK_UNIT          256        /* flash program page = scan granularity */
#define MK_MAGIC_RAW     0xA55A     /* legacy uncompressed sample page */
#define MK_MAGIC_ANCHOR  0xA55B     /* time anchor, carries no samples */
#define MK_MAGIC_RICE    0xA55C     /* compressed record (this file) */
#define MK_AXES          6
#define MK_RAW_SAMPLES   20         /* samples in a legacy raw page */
#define MK_HDR           24
#define MK_DROP_BITS     2          /* discarded LSBs; see the note above */

#ifndef MK_UNITS                    /* record size, in MK_UNIT pages */
#define MK_UNITS         4          /* 1 KB */
#endif
#ifndef MK_MAX_SAMPLES              /* must exceed what a record can hold, or
                                       quiet stretches stop compressing -- this
                                       cap was the binding constraint at 256,
                                       costing five minutes of recording time */
#define MK_MAX_SAMPLES   384
#endif
#ifndef MK_BLOCK                    /* samples between fresh Rice k values */
#define MK_BLOCK         64
#endif
#define MK_REC_BYTES     (MK_UNIT * MK_UNITS)

// Rice escape: a delta far out in the tail would otherwise cost one bit per
// unit of quotient. After MK_ESC ones (and no terminating zero) the value
// follows raw, which bounds the worst case at 38 bits instead of thousands.
#define MK_ESC           20
#define MK_ESC_BITS      18
#define MK_KMAX          15

// ---- bit I/O ---------------------------------------------------------------
// The buffer must be zeroed by the caller; the writer only ever sets bits.
typedef struct { uint8_t *buf; uint32_t pos; uint32_t cap; } mk_bw;
typedef struct { const uint8_t *buf; uint32_t pos; uint32_t cap; } mk_br;

static int mk_put_bits(mk_bw *w, uint32_t v, uint8_t n) {
  if (w->pos + n > w->cap) return 0;
  for (int8_t i = (int8_t)n - 1; i >= 0; i--) {
    uint32_t p = w->pos++;
    if ((v >> i) & 1u) w->buf[p >> 3] |= (uint8_t)(0x80u >> (p & 7));
  }
  return 1;
}

static uint32_t mk_get_bits(mk_br *r, uint8_t n) {
  uint32_t v = 0;
  for (uint8_t i = 0; i < n; i++) {
    uint32_t p = r->pos++;
    uint32_t bit = (p < r->cap) ? ((r->buf[p >> 3] >> (7 - (p & 7))) & 1u) : 0u;
    v = (v << 1) | bit;
  }
  return v;
}

static uint32_t mk_rice_len(uint32_t u, uint8_t k) {
  uint32_t q = u >> k;
  return (q >= MK_ESC) ? (MK_ESC + MK_ESC_BITS) : (q + 1 + k);
}

static int mk_put_rice(mk_bw *w, uint32_t u, uint8_t k) {
  uint32_t q = u >> k;
  if (q >= MK_ESC) {
    for (uint32_t i = 0; i < MK_ESC; i++) if (!mk_put_bits(w, 1, 1)) return 0;
    return mk_put_bits(w, u, MK_ESC_BITS);
  }
  for (uint32_t i = 0; i < q; i++) if (!mk_put_bits(w, 1, 1)) return 0;
  if (!mk_put_bits(w, 0, 1)) return 0;
  return k ? mk_put_bits(w, u & ((1u << k) - 1u), k) : 1;
}

static uint32_t mk_zigzag(int32_t d) {
  return ((uint32_t)d << 1) ^ (uint32_t)(d >> 31);
}

static int32_t mk_unzigzag(uint32_t u) {
  return (int32_t)(u >> 1) ^ -(int32_t)(u & 1u);
}

// How many MK_UNIT pages a record occupies -- what a scanner needs to step
// over it without decoding. Anchors and raw pages are one unit each.
static uint16_t mk_record_units(const uint8_t *rec) {
  uint16_t magic;
  memcpy(&magic, rec, 2);
  if (magic != MK_MAGIC_RICE) return 1;
  uint8_t u = rec[7];
  return u ? u : 1;
}

// ---- encode ----------------------------------------------------------------
// Packs as many of the `n_in` samples as fit in one record and returns how many
// went in (>= 1). The caller keeps the remainder for the next record.
//
// Scratch for the k search. Static rather than stack: the logging loop runs
// with whatever the SoftDevice left us.
static uint32_t mk_zz_scratch[MK_BLOCK];

static uint16_t mk_encode_record(uint8_t *rec, const int16_t *s, uint16_t n_in,
                                 uint16_t seq, uint8_t drop) {
  if (n_in < 1) return 0;
  if (n_in > MK_MAX_SAMPLES) n_in = MK_MAX_SAMPLES;
  memset(rec, 0, MK_REC_BYTES);

  uint16_t magic = MK_MAGIC_RICE, count = 1;
  memcpy(rec, &magic, 2);
  memcpy(rec + 4, &seq, 2);
  rec[6] = drop;
  rec[7] = MK_UNITS;

  int32_t prev[MK_AXES];
  for (uint8_t a = 0; a < MK_AXES; a++) {
    int16_t v = (int16_t)(s[a] >> drop);
    memcpy(rec + 12 + a * 2, &v, 2);
    prev[a] = v;
  }

  mk_bw w;
  w.buf = rec + MK_HDR;
  w.pos = 0;
  w.cap = (MK_REC_BYTES - MK_HDR) * 8;

  uint8_t k[MK_AXES] = {0, 0, 0, 0, 0, 0};
  for (uint16_t i = 1; i < n_in; i++) {
    if ((i - 1) % MK_BLOCK == 0) {
      // Start of a block: pick k per axis by exact cost over the block's
      // deltas, then write them. 6 axes x 16 values of k over <=64 deltas is
      // ~6k cheap ops, a few times a second while logging.
      uint16_t end = i + MK_BLOCK;
      if (end > n_in) end = n_in;
      for (uint8_t a = 0; a < MK_AXES; a++) {
        int32_t p = prev[a];
        for (uint16_t j = i; j < end; j++) {
          int32_t cur = (int32_t)(s[(uint32_t)j * MK_AXES + a] >> drop);
          mk_zz_scratch[j - i] = mk_zigzag(cur - p);
          p = cur;
        }
        uint32_t best = 0xFFFFFFFFu;
        uint8_t bk = 0;
        for (uint8_t kk = 0; kk <= MK_KMAX; kk++) {
          uint32_t tot = 0;
          for (uint16_t j = 0; j < end - i; j++) tot += mk_rice_len(mk_zz_scratch[j], kk);
          if (tot < best) { best = tot; bk = kk; }
        }
        k[a] = bk;
      }
      // If the k header doesn't fit, or no sample of this block does, the
      // record simply ends on the block boundary and the decoder -- which only
      // reads a k when it still has samples to decode -- never looks at it.
      uint32_t hdr = 0;
      for (uint8_t a = 0; a < MK_AXES; a++) hdr = (hdr << 4) | k[a];
      if (!mk_put_bits(&w, (uint32_t)(hdr >> 12), 12) ||
          !mk_put_bits(&w, hdr & 0xFFFu, 12)) break;
    }

    uint32_t save = w.pos;                       // commit a whole sample or none
    int32_t cur[MK_AXES];
    int ok = 1;
    for (uint8_t a = 0; a < MK_AXES && ok; a++) {
      cur[a] = (int32_t)(s[(uint32_t)i * MK_AXES + a] >> drop);
      ok = mk_put_rice(&w, mk_zigzag(cur[a] - prev[a]), k[a]);
    }
    if (!ok) { w.pos = save; break; }            // record full: stop here
    for (uint8_t a = 0; a < MK_AXES; a++) prev[a] = cur[a];
    count++;
  }
  memcpy(rec + 2, &count, 2);
  return count;
}

// ---- decode ----------------------------------------------------------------
// Writes count * 6 int16 into `out` at the original sensor scale (the dropped
// bits come back as zeros). Handles legacy raw pages too. Returns 0 for anchor
// pages, erased flash, or anything that doesn't add up.
static uint16_t mk_decode_record(const uint8_t *rec, int16_t *out, uint16_t max_out) {
  uint16_t magic, count;
  memcpy(&magic, rec, 2);
  memcpy(&count, rec + 2, 2);

  if (magic == MK_MAGIC_RAW) {
    if (count < 1 || count > MK_RAW_SAMPLES || count > max_out) return 0;
    memcpy(out, rec + 8, (size_t)count * MK_AXES * 2);
    return count;
  }
  if (magic != MK_MAGIC_RICE) return 0;
  if (count < 1 || count > MK_MAX_SAMPLES || count > max_out) return 0;

  uint8_t drop = rec[6];
  // A corrupt/torn header must not set a reader capacity beyond its buffer.
  if (drop > 15 || rec[7] == 0 || rec[7] > MK_UNITS) return 0;
  uint32_t bytes = (uint32_t)mk_record_units(rec) * MK_UNIT;
  uint8_t k[MK_AXES] = {0, 0, 0, 0, 0, 0};

  int32_t prev[MK_AXES];
  for (uint8_t a = 0; a < MK_AXES; a++) {
    int16_t v;
    memcpy(&v, rec + 12 + a * 2, 2);
    prev[a] = v;
    out[a] = (int16_t)((uint32_t)(int32_t)v << drop);
  }

  mk_br r;
  r.buf = rec + MK_HDR;
  r.pos = 0;
  r.cap = (bytes - MK_HDR) * 8;

  for (uint16_t i = 1; i < count; i++) {
    if ((i - 1) % MK_BLOCK == 0) {               // fresh Rice k for this block
      for (uint8_t a = 0; a < MK_AXES; a++) k[a] = (uint8_t)mk_get_bits(&r, 4);
    }
    for (uint8_t a = 0; a < MK_AXES; a++) {
      uint32_t q = 0;
      while (q < MK_ESC && mk_get_bits(&r, 1)) q++;   // unary, or MK_ESC = escape
      uint32_t u = (q >= MK_ESC) ? mk_get_bits(&r, MK_ESC_BITS)
                                 : ((q << k[a]) | (k[a] ? mk_get_bits(&r, k[a]) : 0u));
      if (r.pos > r.cap) return 0; // incomplete/corrupt bitstream
      prev[a] += mk_unzigzag(u);
      out[(uint32_t)i * MK_AXES + a] = (int16_t)((uint32_t)prev[a] << drop);
    }
  }
  return count;
}
