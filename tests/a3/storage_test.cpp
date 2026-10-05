#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <vector>
#include "../../firmware/flash_logger/a3_storage.h"
#include "../../firmware/flash_logger/log_codec.h"
struct Flash {
  uint8_t mem[2048];
  int writes=0, fail_write=0;
  bool fail_read=false, corrupt=false;
  std::vector<uint32_t> addresses;
  Flash() { memset(mem,0xFF,sizeof(mem)); }
  uint32_t size() { return sizeof(mem); }
  uint32_t readBuffer(uint32_t a,uint8_t* b,uint32_t n) {
    if (fail_read) return 0;
    assert(a+n<=size()); memcpy(b,mem+a,n); return n;
  }
  uint32_t writeBuffer(uint32_t a,const uint8_t* b,uint32_t n) {
    assert(a+n<=size()); addresses.push_back(a); ++writes;
    uint32_t count = writes==fail_write ? n/2 : n;
    for(uint32_t i=0;i<count;++i) mem[a+i]&=b[i];
    if(corrupt && count) mem[a+count-1]^=1;
    return count;
  }
  void waitUntilReady() {}
};
int main() {
  uint8_t rec[MK_REC_BYTES]; memset(rec,0,sizeof(rec)); rec[0]=0x5C;rec[1]=0xA5;
  Flash good; assert(a3::append_checked(good,0,rec,sizeof(rec)));
  assert(good.addresses.size()==2 && good.addresses[0]==2 && good.addresses[1]==0);
  assert(!memcmp(good.mem,rec,sizeof(rec)));
  int writes=good.writes; assert(!a3::append_checked(good,0,rec,sizeof(rec)) && good.writes==writes);
  Flash full; assert(!a3::append_checked(full,2040,rec,sizeof(rec)) && full.writes==0);
  Flash short_write; short_write.fail_write=1;
  assert(!a3::append_checked(short_write,0,rec,sizeof(rec)));
  assert(short_write.mem[0]==0xFF && short_write.mem[1]==0xFF); // uncommitted
  Flash failed_commit; failed_commit.fail_write=2;
  assert(!a3::append_checked(failed_commit,0,rec,sizeof(rec)));
  assert(failed_commit.mem[0]==0x5C && failed_commit.mem[1]==0xFF); // invalid magic
  Flash corrupt; corrupt.corrupt=true;
  assert(!a3::append_checked(corrupt,0,rec,sizeof(rec)) && corrupt.mem[0]==0xFF);
  Flash read_fail; read_fail.fail_read=true;
  assert(!a3::append_checked(read_fail,0,rec,sizeof(rec)) && read_fail.writes==0);
  int16_t out[MK_MAX_SAMPLES*MK_AXES];
  memset(rec,0xFF,sizeof(rec)); rec[0]=0x5C; rec[1]=0xA5; rec[2]=0x80;rec[3]=1;
  rec[6]=0;rec[7]=255;assert(mk_decode_record(rec,out,MK_MAX_SAMPLES)==0);
  rec[7]=0;assert(mk_decode_record(rec,out,MK_MAX_SAMPLES)==0);
  rec[7]=4;rec[6]=32;assert(mk_decode_record(rec,out,MK_MAX_SAMPLES)==0);
  rec[6]=0;assert(mk_decode_record(rec,out,MK_MAX_SAMPLES)==0); // exhausted bitstream
  int16_t in[MK_MAX_SAMPLES*MK_AXES];
  for(unsigned i=0;i<sizeof(in)/sizeof(in[0]);++i) in[i]=int16_t(i*71-23000);
  const auto n=mk_encode_record(rec,in,MK_MAX_SAMPLES,0,2);
  assert(n && mk_decode_record(rec,out,MK_MAX_SAMPLES)==n);
  for(unsigned i=0;i<unsigned(n)*MK_AXES;++i) assert(out[i]==int16_t((in[i]>>2)*4));
  puts("PASS: erased-only append, payload-before-magic, short writes/readback/commit failures, bounds, malformed decoder headers, codec sample round-trip");
}
