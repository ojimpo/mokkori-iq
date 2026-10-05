#ifndef MOKKORI_A3_STORAGE_H
#define MOKKORI_A3_STORAGE_H
#include <stdint.h>
#include <string.h>
namespace a3 {
// Never treat a torn/non-erased tail as free space. Verify each completed
// write before the caller advances its cursor or releases the RAM samples.
template<class Flash> bool append_checked(Flash& flash, uint32_t address,
                                         const uint8_t* bytes, uint32_t len) {
  if (len < 2) return false;
  if (address > flash.size() || len > flash.size() - address) return false;
  uint8_t check[32];
  for (uint32_t pos=0; pos<len; pos+=sizeof(check)) {
    const uint32_t n = len-pos < sizeof(check) ? len-pos : sizeof(check);
    if (flash.readBuffer(address+pos,check,n) != n) return false;
    for (uint32_t i=0;i<n;++i) if (check[i] != 0xFF) return false;
  }
  // Commit existing two-byte magic LAST, after body verification. An
  // interrupted new write cannot advertise a complete record prematurely.
  if (flash.writeBuffer(address+2,bytes+2,len-2) != len-2) return false;
  flash.waitUntilReady();
  for (uint32_t pos=2; pos<len; pos+=sizeof(check)) {
    const uint32_t n = len-pos < sizeof(check) ? len-pos : sizeof(check);
    if (flash.readBuffer(address+pos,check,n) != n || memcmp(check,bytes+pos,n)) return false;
  }
  if (flash.writeBuffer(address,bytes,2) != 2) return false;
  flash.waitUntilReady();
  return flash.readBuffer(address,check,2) == 2 && memcmp(check,bytes,2) == 0;
}
}
#endif
