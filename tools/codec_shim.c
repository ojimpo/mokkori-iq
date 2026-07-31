/* ctypes shim so tools/codec_check.py can exercise the *actual* firmware
 * codec on the host before we flash it. Build:
 *     cc -O2 -shared -fPIC -o libmkcodec.dylib tools/codec_shim.c
 * (codec_check.py does this for you, once per record-size variant it tries.) */
#include "../firmware/flash_logger/log_codec.h"

int mk_rec_bytes(void)   { return MK_REC_BYTES; }
int mk_max_samples(void) { return MK_MAX_SAMPLES; }
int mk_drop_bits(void)   { return MK_DROP_BITS; }

int mk_enc(unsigned char *rec, const short *s, unsigned short n_in,
           unsigned short seq, unsigned char drop) {
  return mk_encode_record(rec, (const int16_t *)s, n_in, seq, drop);
}

int mk_dec(const unsigned char *rec, short *out, unsigned short max_out) {
  return mk_decode_record(rec, (int16_t *)out, max_out);
}
