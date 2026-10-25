// Run against the patched Edge source:
// c++ -std=c++17 -I <edge>/src HdrFeedbackSnapshot.Tests.cc -o <temporary-test>
#include "xenia/gpu/d3d12/hdr_feedback_snapshot.h"
#include <cassert>
#include <fstream>
#include <string>
#include <vector>
using namespace xe::gpu::d3d12;
int main(int argc, char** argv) {
  assert(!GetSaintsHdrReaderLayout(0));
  assert(!GetSaintsHdrReaderLayout(0x4B4D07F7));
  // Optional owner-supplied decoded images validate the real instructions;
  // no game image is redistributed with this test.
  if (argc == 3 || argc == 4) {
    const uint32_t titles[]{0x4B4D0800, 0x4B4D07F6, 0x5451086D};
    for (size_t game = 0; game < size_t(argc - 1); ++game) {
      const auto* layout = GetSaintsHdrReaderLayout(titles[game]);
      std::ifstream image(argv[game + 1], std::ios::binary);
      assert(image);
      auto word = [&](uint32_t address) {
        uint8_t bytes[4];
        image.seekg(address - 0x82000000);
        image.read(reinterpret_cast<char*>(bytes), 4);
        assert(image);
        return uint32_t(bytes[0]) << 24 | uint32_t(bytes[1]) << 16 |
               uint32_t(bytes[2]) << 8 | bytes[3];
      };
      for (size_t i = 0; i < layout->reader_prefix.size(); ++i)
        assert(word(layout->reader + uint32_t(i) * 4) == layout->reader_prefix[i]);
      assert((word(layout->reader) & 0xFFFF) == layout->slot_offset);
      assert((word(layout->reader + 8) & 0xFFFF) * 4 == layout->texture_id_offsets[0]);
      assert((word(layout->reader + 0x70) & 0xFFFF) * 4 == layout->texture_id_offsets[1]);
      assert(word(layout->caller) == layout->caller_instruction);
      const uint32_t displacement = layout->caller_instruction & 0x03FFFFFC;
      assert(layout->caller + int32_t(displacement | 0xFC000000) == layout->reader);
      // The normal texture pool uses a per-ID flag and a descriptor stride;
      // the page pointer is the final load after the record base is selected.
      assert((word(layout->reader + 0x20) & 0xFFFF) == layout->pool_flag_offset);
      assert((word(layout->reader + 0x40) & 0xFFFF) == layout->descriptor_stride);
      assert((word(layout->reader + 0x6C) & 0xFFFF) +
                 (word(layout->reader + 0xD4) & 0xFFFF) == layout->page_pointer_offset);
      const uint32_t root_high = (word(layout->reader + 4) & 0xFFFF) << 16;
      assert(root_high + int16_t(word(layout->reader + 16)) == layout->texture_manager_root);
    }
  } else {
    assert(argc == 1);
  }
  const std::array<uint32_t,2> addresses{0x1000,0x2000};
  std::vector<HdrFeedbackSnapshotKey> keys{
    {0x1000,7,10,true},{0x2000,7,11,true},
    {0x1000,8,12,true},{0x2000,8,13,true},
    {0x1000,9,14,true},{0x2000,9,15,true}};
  auto pick=[&](uint64_t owner,uint64_t done){return SelectHdrFeedbackPair(keys.data(),keys.size(),addresses,owner,done);};
  assert((pick(9,15)==std::array<size_t,2>{4,5}));
  assert((pick(9,14)==std::array<size_t,2>{2,3}));
  assert((pick(9,11)==std::array<size_t,2>{0,1}));
  assert((pick(10,11)==std::array<size_t,2>{6,6}));
  assert((pick(8,15)==std::array<size_t,2>{2,3}));
  assert((pick(6,15)==std::array<size_t,2>{6,6}));
  assert((pick(9,UINT64_MAX)==std::array<size_t,2>{6,6}));
  keys.push_back({0x1000,9,16,true});
  assert((pick(9,15)==std::array<size_t,2>{2,3}));
  assert((pick(9,16)==std::array<size_t,2>{6,5}));
  keys[5].available=false;
  assert((pick(9,16)==std::array<size_t,2>{2,3}));
  keys[3].address=0x3000;
  assert((pick(9,16)==std::array<size_t,2>{0,1}));
  keys={{0x1000,0,1,true},{0x2000,0,2,true}};
  assert((pick(0,2)==std::array<size_t,2>{0,1}));
  assert((pick(UINT64_MAX,2)==std::array<size_t,2>{2,2}));
  // Exhaust all ready-page masks for three successive paired frames.
  for(unsigned mask=0;mask<64;++mask){
    keys.clear();
    for(unsigned frame=0;frame<3;++frame)for(unsigned part=0;part<2;++part)
      keys.push_back({addresses[part],frame,frame*2+part+1,bool(mask&(1U<<(frame*2+part)))});
    for(unsigned done=0;done<=6;++done){
      auto result=pick(2,done);int expected=-1;
      for(unsigned frame=0;frame<3;++frame)
        if((mask&(3U<<(2*frame)))==(3U<<(2*frame))&&2*frame+2<=done)expected=frame;
      if(expected<0)assert(result[0]==keys.size()&&result[1]==keys.size());
      else assert(result[0]==size_t(expected*2)&&result[1]==size_t(expected*2+1));
    }
  }
}
