#include <bit>
#include <cstdint>
#include <cstdio>
#include <initializer_list>

// Independent arithmetic check for the proposed SPIR-V decoder reduction.
// Actual shader emission and GPU output still require replay validation.
static uint32_t Reference(uint32_t value, bool remap) {
  uint32_t exponent = value >> 20;
  uint32_t mantissa = value & 0xFFFFF;
  if (!exponent) {
    if (!mantissa) return 0;
    uint32_t msb = 31 - std::countl_zero(mantissa);
    exponent = msb + 93 - uint32_t(remap);
    mantissa = (mantissa << (20 - msb)) & 0xFFFFF;
  } else {
    exponent += 112 - uint32_t(remap);
  }
  return (exponent << 23) | (mantissa << 3);
}

static uint32_t Reduced(uint32_t value, bool remap) {
  uint32_t normal = (value << 3) + ((112 - uint32_t(remap)) << 23);
  // Every 20-bit integer converts exactly to float32. Both scales are powers
  // of two, and even the smallest nonzero result is a normal float32.
  float denormal = float(value & 0xFFFFF) *
                   (remap ? 0x1p-35f : 0x1p-34f);
  return (value >> 20) ? normal : std::bit_cast<uint32_t>(denormal);
}

int main() {
  for (bool remap : {false, true}) {
    for (uint32_t value = 0; value < (1u << 24); ++value) {
      uint32_t reference = Reference(value, remap);
      uint32_t reduced = Reduced(value, remap);
      if (reference != reduced) {
        std::printf("Mismatch: input=%06X remap=%u ref=%08X got=%08X\n",
                    value, unsigned(remap), reference, reduced);
        return 1;
      }
    }
  }
  std::puts("PASS: all 33,554,432 float24 decodes match the existing bit reconstruction.");
}
