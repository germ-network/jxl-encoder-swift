// Prints the static entropy tables exactly as the compiler resolves them, so
// the Swift port carries the same data rather than a regex's guess at it.
#include <stdio.h>
#include "encoder/static_entropy_codes.h"
using namespace jxl;
int main() {
  printf("DC_MAP %zu\n", sizeof(kDCContextMap) / sizeof(kDCContextMap[0]));
  for (size_t i = 0; i < sizeof(kDCContextMap)/sizeof(kDCContextMap[0]); ++i)
    printf("%d ", kDCContextMap[i]);
  printf("\nAC_MAP %zu\n", sizeof(kACContextMap) / sizeof(kACContextMap[0]));
  for (size_t i = 0; i < sizeof(kACContextMap)/sizeof(kACContextMap[0]); ++i)
    printf("%d ", kACContextMap[i]);
  printf("\nDC_CODES %zu\n", kNumDCPrefixCodes);
  for (size_t c = 0; c < kNumDCPrefixCodes; ++c) {
    for (size_t i = 0; i < kAlphabetSize; ++i) printf("%d ", kDCPrefixCodes[c].depths[i]);
    printf("|");
    for (size_t i = 0; i < kAlphabetSize; ++i) printf("%d ", kDCPrefixCodes[c].bits[i]);
    printf("\n");
  }
  printf("AC_CODES %zu\n", kNumACPrefixCodes);
  for (size_t c = 0; c < kNumACPrefixCodes; ++c) {
    for (size_t i = 0; i < kAlphabetSize; ++i) printf("%d ", kACPrefixCodes[c].depths[i]);
    printf("|");
    for (size_t i = 0; i < kAlphabetSize; ++i) printf("%d ", kACPrefixCodes[c].bits[i]);
    printf("\n");
  }
  return 0;
}
