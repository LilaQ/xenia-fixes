#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>
#include "third_party/snappy/snappy.h"
#include "xenia/base/memory.h"
#include "xenia/gpu/shared_memory.h"
#include "xenia/gpu/trace_protocol.h"
#include "xenia/gpu/trace_writer.h"
#include "xenia/memory.h"

static void Check(bool value, const char* message) {
  if (!value) { std::fprintf(stderr, "%s\n", message); std::exit(1); }
}
class TestMemory final : public xe::gpu::SharedMemory {
 public:
  explicit TestMemory(xe::Memory& memory) : SharedMemory(memory) {}
  bool Initialize() { return InitializeCommon(); }
  void CpuOwns(uint32_t start, uint32_t length) {
    MakeRangeValid(start, length, false);
  }
 protected:
  bool UploadRanges(const std::pair<uint32_t, uint32_t>*, uint32_t) override {
    return false;
  }
};
struct Range { uint32_t address, length; };
int main(int argc, char** argv) {
  Check(argc == 2, "Supply one temporary trace output path");
  xe::Memory memory;
  Check(memory.Initialize(), "Memory initialization failed");
  auto* heap = memory.LookupHeapByType(true, 64 * 1024);
  Check(heap->AllocFixed(heap->heap_base(), 2 * 1024 * 1024,
                        heap->page_size(),
                        xe::kMemoryAllocationReserve | xe::kMemoryAllocationCommit,
                        xe::kMemoryProtectRead | xe::kMemoryProtectWrite),
        "Physical test allocation failed");
  auto* ram = memory.physical_membase();
  for (size_t i = 0; i < 2 * 1024 * 1024; ++i) ram[i] = uint8_t(i * 17 + 3);
  TestMemory shared(memory);
  Check(shared.Initialize(), "Shared memory initialization failed");
  const uint32_t page = uint32_t(xe::memory::page_size());
  const uint32_t begin = 62 * page + 17;
  const uint32_t end = 66 * page - 23;
  auto record = [&](const std::vector<Range>& expected) {
    xe::gpu::TraceWriter writer(ram);
    Check(writer.Open(argv[1], 0x54455354), "Trace open failed");
    shared.RecordCpuMemoryReadInTrace(writer, begin, end - begin);
    shared.RecordCpuMemoryReadInTrace(writer, begin, 0);
    writer.Close();
    std::ifstream file(argv[1], std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), {});
    size_t offset = sizeof(xe::gpu::TraceHeader), count = 0;
    while (offset < bytes.size()) {
      Check(bytes.size() - offset >= sizeof(xe::gpu::MemoryCommand), "Truncated command");
      xe::gpu::MemoryCommand cmd;
      std::memcpy(&cmd, bytes.data() + offset, sizeof(cmd));
      offset += sizeof(cmd);
      Check(cmd.type == xe::gpu::TraceCommandType::kMemoryRead, "Unexpected command");
      Check(count < expected.size(), "GPU-authoritative bytes leaked into trace");
      Check(cmd.base_ptr == expected[count].address &&
            cmd.decoded_length == expected[count].length, "Incorrect CPU range");
      Check(cmd.encoded_length <= bytes.size() - offset, "Truncated data");
      std::vector<uint8_t> decoded(cmd.decoded_length);
      if (cmd.encoding_format == xe::gpu::MemoryEncodingFormat::kSnappy) {
        Check(snappy::RawUncompress(reinterpret_cast<const char*>(bytes.data() + offset),
                                   cmd.encoded_length,
                                   reinterpret_cast<char*>(decoded.data())), "Decode failed");
      } else {
        Check(cmd.encoded_length == cmd.decoded_length, "Invalid raw size");
        std::memcpy(decoded.data(), bytes.data() + offset, decoded.size());
      }
      Check(!std::memcmp(decoded.data(), ram + cmd.base_ptr, decoded.size()),
            "CPU texture payload changed");
      offset += cmd.encoded_length;
      ++count;
    }
    Check(count == expected.size(), "CPU texture bytes missing");
  };
  record({{begin, end - begin}});
  shared.RangeWrittenByGpu(63 * page, 2 * page);
  record({{begin, 63 * page - begin}, {65 * page, end - 65 * page}});
  shared.CpuOwns(63 * page, 2 * page);
  record({{begin, end - begin}});
  shared.RangeWrittenByGpu(62 * page, 4 * page);
  record({});
  std::remove(argv[1]);
  std::puts("PASS: CPU bytes preserved, GPU bytes excluded across bitmap boundary; CPU reuse restored; empty/all-GPU ranges omitted");
}
