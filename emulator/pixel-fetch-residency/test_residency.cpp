#include <array>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <utility>
#include <vector>
#define XELOGE(...) do {} while(0)
#define XELOGW(...) do {} while(0)
namespace xe {
template<typename T,size_t N> constexpr size_t countof(const T(&)[N]) {return N;}
bool bit_scan_forward(uint32_t x,uint32_t* bit) {if(!x)return false;*bit=__builtin_ctz(x);return true;}
uint32_t clear_lowest_bit(uint32_t x) {return x&(x-1);}
}
namespace cvars {bool gpu_allow_invalid_fetch_constants=false;}
namespace global_critical_region {struct Guard{};Guard Acquire(){return {};}}
namespace xenos {
enum class FetchConstantType {kInvalidVertex=1,kVertex=3};
struct xe_gpu_vertex_fetch_t {FetchConstantType type=FetchConstantType::kVertex;uint32_t address=0,size=0,dword_0=0,dword_1=0;};
uint32_t CpuToGpu(uint32_t x){return x&0x1fffffff;}
}
struct Shader {
 struct ConstantRegisterMap {uint32_t vertex_fetch_bitmap[3]={0,0,0};} map;
 const ConstantRegisterMap& constant_register_map() const{return map;}
};
struct RegisterFile {std::array<xenos::xe_gpu_vertex_fetch_t,96> fetches;auto GetVertexFetch(uint32_t i) const{return fetches.at(i);}};
struct Memory {std::vector<std::pair<uint32_t,uint32_t>> requests;bool RequestRange(uint32_t a,uint32_t s){requests.emplace_back(a,s);return true;}};
struct Processor {
 Memory memory;Memory* shared_memory_=&memory;
 bool draw(const Shader* vertex_shader,const Shader* pixel_shader,const RegisterFile& regs) {
#ifdef ORIGINAL
#include "fetch-block-before.inc"
#else
#include "fetch-block-after.inc"
#endif
  return true;
 }
};
void enable(Shader& s,uint32_t i){s.map.vertex_fetch_bitmap[i/32]|=1u<<(i%32);}
int main(){
 RegisterFile regs;for(uint32_t i=0;i<96;i++){regs.fetches[i].address=(0x10000+i*0x100)/4;regs.fetches[i].size=0x40/4;}
 // Rise's fullscreen VS fetches no buffers; its PS consumes slots 94 and 95.
 Shader vs,ps;enable(ps,94);enable(ps,95);Processor rise;assert(rise.draw(&vs,&ps,regs));
#ifdef ORIGINAL
 assert(rise.memory.requests.empty());std::cout<<"Confirmed original defect: pixel-only buffers are not uploaded\n";
#else
 assert(rise.memory.requests.size()==2);assert(rise.memory.requests[0]==std::make_pair(0x15e00u,0x40u));assert(rise.memory.requests[1]==std::make_pair(0x15f00u,0x40u));
 // Overlapping fetches are requested once and all three bitmap words are covered.
 enable(vs,0);enable(vs,32);enable(vs,94);enable(ps,32);Processor overlap;assert(overlap.draw(&vs,&ps,regs));assert(overlap.memory.requests.size()==4);
 Processor noPixel;assert(noPixel.draw(&vs,nullptr,regs));assert(noPixel.memory.requests.size()==3);
 Shader empty;Processor noFetch;assert(noFetch.draw(&empty,nullptr,regs));assert(noFetch.memory.requests.empty());
 // Preserve the original invalid-fetch rejection before scheduling any upload.
 regs.fetches[0].type=static_cast<xenos::FetchConstantType>(0);Processor invalid;assert(!invalid.draw(&vs,&ps,regs));assert(invalid.memory.requests.empty());
 std::cout<<"PASS: pixel-only residency, VS/PS overlap, all bitmap words, null PS, invalid-fetch guard\n";
#endif
}
