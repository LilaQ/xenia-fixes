#ifndef XENIA_GPU_D3D12_HDR_FEEDBACK_SNAPSHOT_H_
#define XENIA_GPU_D3D12_HDR_FEEDBACK_SNAPSHOT_H_

#include <array>
#include <cstddef>
#include <cstdint>

namespace xe::gpu::d3d12 {
struct SaintsHdrReaderLayout {
  uint64_t module_hash;
  uint32_t reader;
  uint32_t caller;
  uint32_t caller_instruction;
  uint32_t texture_manager_root;
  uint32_t slot_offset;
  std::array<uint32_t, 2> texture_id_offsets;
  std::array<uint32_t, 5> reader_prefix;
  uint32_t pool_flag_offset;
  uint32_t descriptor_stride;
  uint32_t page_pointer_offset;
};

inline const SaintsHdrReaderLayout* GetSaintsHdrReaderLayout(uint32_t title) {
  static constexpr SaintsHdrReaderLayout gat{
      0, 0x82F5C3F0, 0x82F5D340, 0x4BFFF0B1, 0x849331A8, 0x9B8, {0x9C4, 0x9BC},
      {0x810309B8, 0x3D608493, 0x39480271, 0x5549103A, 0x814B31A8},
      0x65, 0xD0, 0x190};
  static constexpr SaintsHdrReaderLayout sr4_tu1{
      0xC875658006E4639CULL, 0x82EE8390, 0x82EE92E0, 0x4BFFF0B1, 0x847B6B94, 0x9B4, {0x9C0, 0x9B8},
      {0x810309B4, 0x3D60847B, 0x39480270, 0x5549103A, 0x814B6B94},
      0x65, 0xD0, 0x190};
  static constexpr SaintsHdrReaderLayout sr3_0043{
      0xF514A8ECF18C0E5AULL, 0x82D3B0C0, 0x82D3BFB0, 0x4BFFF111,
      0x84579A20, 0x93C, {0x948, 0x940},
      {0x8103093C, 0x3D608458, 0x39480252, 0x5549103A, 0x814B9A20},
      0x5D, 0xC8, 0x178};
  switch (title) {
    case 0x4B4D0800: return &gat;
    case 0x4B4D07F6: return &sr4_tu1;
    case 0x5451086D: return &sr3_0043;
    default: return nullptr;
  }
}

struct HdrFeedbackSnapshotKey {
  uint32_t address = 0;
  uint64_t frame = 0;
  uint64_t submission = 0;
  bool available = false;
};

// Pick one complete frame for both feedback values. A newer unfinished copy
// of the same page/frame invalidates an earlier copy of that page/frame.
// Return count/count if there is no complete pair no more than two frames old.
inline std::array<size_t, 2> SelectHdrFeedbackPair(
    const HdrFeedbackSnapshotKey* keys, size_t count,
    const std::array<uint32_t, 2>& addresses, uint64_t owner_frame,
    uint64_t completed) {
  std::array<size_t, 2> best{count, count};
  uint64_t best_frame = 0;
  if (addresses[0] == addresses[1] || (addresses[0] & 4095) ||
      (addresses[1] & 4095) || completed == UINT64_MAX) {
    return best;
  }
  for (size_t candidate = 0; candidate < count; ++candidate) {
    const auto& key = keys[candidate];
    if (!key.available || key.frame > owner_frame ||
        owner_frame - key.frame > 2 ||
        (best[0] != count && key.frame <= best_frame)) {
      continue;
    }
    std::array<size_t, 2> pair{count, count};
    for (size_t i = 0; i < count; ++i) {
      const auto& other = keys[i];
      if (!other.available || other.frame != key.frame || !other.submission) {
        continue;
      }
      for (size_t part = 0; part < 2; ++part) {
        if (other.address == addresses[part] &&
            (pair[part] == count ||
             other.submission > keys[pair[part]].submission)) {
          pair[part] = i;
        }
      }
    }
    if (pair[0] != count && pair[1] != count &&
        keys[pair[0]].submission <= completed &&
        keys[pair[1]].submission <= completed) {
      best = pair;
      best_frame = key.frame;
    }
  }
  return best;
}
}  // namespace xe::gpu::d3d12
#endif  // XENIA_GPU_D3D12_HDR_FEEDBACK_SNAPSHOT_H_
