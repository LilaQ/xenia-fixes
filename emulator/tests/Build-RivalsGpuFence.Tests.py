from pathlib import Path
import argparse,subprocess
ap=argparse.ArgumentParser();ap.add_argument('--source',type=Path,required=True);ap.add_argument('--cxx',required=True);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
def function(path,sig):
 s=path.read_text();start=s.index(sig);o=s.index('{',start);d=1;i=o+1
 while d:d+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[start:i]
root=a.source/'src/xenia/gpu'
method=function(root/'d3d12/d3d12_command_processor.cc','void D3D12CommandProcessor::PumpRivalsEventFences(')+'\n'+function(root/'d3d12/d3d12_command_processor.cc','bool D3D12CommandProcessor::TryWriteMemexportGpuFence(')
prepare=function(root/'command_processor.cc','void CommandProcessor::PrepareForWait(').replace('CommandProcessor::','D3D12CommandProcessor::')
packet=function(root/'pm4_command_processor_implement.h','bool COMMAND_PROCESSOR::ExecutePacketType3_EVENT_WRITE_SHD(').replace(' XE_RESTRICT','').replace('COMMAND_PROCESSOR','D3D12CommandProcessor')
prefix=r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <deque>
#define XELOGI(...) do {} while(false)
namespace cvars{bool d3d12_rivals_gpu_event_fences=true;bool d3d12_submission_timing=true;}
namespace kernel{struct KernelState{uint32_t title=0x454109C6;static KernelState* shared(){static KernelState k;return &k;}uint32_t title_id(){return title;}};}
namespace xenos{enum class Endian{None=0,Swap8in16=1,Swap8in32=2,Swap16in32=3};}
uint32_t GpuSwap(uint32_t v,xenos::Endian e){switch(e){case xenos::Endian::None:return v;case xenos::Endian::Swap8in16:return ((v&0xFF00FF)<<8)|((v>>8)&0xFF00FF);case xenos::Endian::Swap8in32:return __builtin_bswap32(v);default:return(v<<16)|(v>>16);}}
namespace xe{template<class T>void store(void* p,T v){std::memcpy(p,&v,sizeof(v));}}
struct Memory{uint32_t fence=0;uint8_t* TranslatePhysical(uint32_t){return reinterpret_cast<uint8_t*>(&fence);}uint8_t* TranslateVirtual(uint32_t){return TranslatePhysical(0);}};
struct Registers{uint32_t values[2]={};};constexpr unsigned XE_GPU_REG_WRITEBACK_START=0,XE_GPU_REG_WRITEBACK_SIZE=1;
struct HostMemory{static constexpr uint32_t kBufferSize=0x20000000;void* host=(void*)1;void* GetHostBuffer(){return host;}};
using SharedMemory=HostMemory;
struct Writer{void Flush(){}bool open=false;unsigned writes=0;bool is_open(){return open;}void WriteMemoryWrite(uint32_t,unsigned){writes++;}};
struct Reader{uint32_t words[3]={0,0x1002,0x11223344};unsigned pos=0;template<class T>T ReadAndSwap(){return words[pos++];}};
enum class ZPDMode{kFast,kStrict};
struct D3D12CommandProcessor{
 std::vector<int> order;HostMemory mem;HostMemory* shared_memory_=&mem;Writer trace_writer_;bool memexport_await_pending_=true;std::vector<int> memexport_staged_;uint64_t memexport_awaited_submission_=42,current=42,last_wait=0;uint32_t committed=4,trace_title=0;bool begin=true,resolve_closes=false;unsigned waits=0;Memory memory;Memory* memory_=&memory;Registers regs;Registers* register_file_=&regs;Reader reader_;uint32_t counter_=0x55667788;

 uint32_t WritableGuestRangeLength(uint32_t,uint32_t){return committed;}
 uint32_t trace_playback_title_id(){return trace_title;}
 void SubmitResolvesForGuestSync(){order.push_back(1);if(resolve_closes){if(submission_open){current++;submission_open=false;submits++;}resolve_closes=false;}}
 uint64_t GetCurrentSubmission(){return current;}
 bool EndSubmission(bool){if(!begin)return false;order.push_back(5);if(submission_open){current++;submission_open=false;submits++;}return true;}
 void CompleteGpu(){completed=current-1;PumpRivalsEventFences();}
 uint64_t GetCompletedSubmission(){return completed;}
 void AwaitMemexportForFence(){if(memexport_await_pending_){waits++;last_wait=memexport_awaited_submission_;memexport_await_pending_=false;CompleteGpu();}}
 static bool debug_markers_enabled(){return false;}
 template<class...T>static void InsertDebugMarker(T...){}
 static const char* GetEventName(uint32_t){return "test";}
 void WriteEventInitiator(uint32_t){}
 uint32_t CpuToGpu(uint32_t x){return x;}
 struct RivalsEventFence{uint64_t submission;uint32_t address,value;};std::deque<RivalsEventFence> rivals_event_fences_;bool rivals_pumping_event_fences_=false;uint64_t completed=0;bool submission_open=true;unsigned submits=0;void PumpRivalsEventFences();
 uint64_t driver_completed=0;ZPDMode zpd_mode_=ZPDMode::kFast;unsigned zpd_awaited_report_count_=0;bool viz_pending_resolves_=false;bool HasPendingCpuFenceWrites(){return !rivals_event_fences_.empty();}void PrepareZPDForWait(){}void PollCompletedSubmission(){completed=driver_completed;PumpRivalsEventFences();}void PrepareForWait();
 bool TryWriteMemexportGpuFence(uint32_t,uint32_t);
 bool ExecutePacketType3_EVENT_WRITE_SHD(uint32_t,uint32_t);
};
'''
suffix=r'''
int main(){
 {D3D12CommandProcessor p;assert(p.ExecutePacketType3_EVENT_WRITE_SHD(0,3));assert(p.memory.fence==0&&p.waits==0&&p.memexport_await_pending_);assert(p.rivals_event_fences_.size()==1&&p.rivals_event_fences_.front().address==0x1000&&p.rivals_event_fences_.front().value==0x44332211);assert((p.order==std::vector<int>{1,5}));assert(p.memexport_awaited_submission_==42);p.AwaitMemexportForFence();assert(p.waits==1&&p.last_wait==42&&p.memory.fence==0x44332211&&!p.memexport_await_pending_);}
 {D3D12CommandProcessor p;for(uint32_t v=1;v<=60;v++)assert(p.TryWriteMemexportGpuFence(0x1000,v));assert(p.submits==1&&p.rivals_event_fences_.size()==60&&p.memory.fence==0);p.CompleteGpu();assert(p.rivals_event_fences_.empty()&&p.memory.fence==60);}
 {D3D12CommandProcessor p;p.rivals_event_fences_.push_back({41,0x1000,123});p.rivals_event_fences_.push_back({42,0x1000,456});p.completed=41;p.PumpRivalsEventFences();assert(p.memory.fence==123&&p.rivals_event_fences_.size()==1);p.rivals_pumping_event_fences_=true;p.completed=42;p.PumpRivalsEventFences();assert(p.memory.fence==123);p.rivals_pumping_event_fences_=false;p.PumpRivalsEventFences();assert(p.memory.fence==456&&p.rivals_event_fences_.empty());}
 {D3D12CommandProcessor p;p.resolve_closes=true;assert(p.ExecutePacketType3_EVENT_WRITE_SHD(0,3));assert(p.memexport_awaited_submission_==42);p.AwaitMemexportForFence();assert(p.last_wait==42&&p.memory.fence==0x44332211);}
 {D3D12CommandProcessor p;p.reader_.words[0]=0x80000000;assert(p.ExecutePacketType3_EVENT_WRITE_SHD(0,3));assert(p.waits==1&&p.memory.fence==0x88776655&&p.rivals_event_fences_.empty());}
 {D3D12CommandProcessor p;assert(p.TryWriteMemexportGpuFence(0x1000,123));p.PrepareForWait();assert(p.memory.fence==0);p.driver_completed=42;p.PrepareForWait();assert(p.memory.fence==123&&p.rivals_event_fences_.empty());}
 {D3D12CommandProcessor p;p.memexport_awaited_submission_=17;assert(p.TryWriteMemexportGpuFence(0x1000,123));assert(p.submits==0&&p.current==42&&p.memexport_awaited_submission_==17&&p.rivals_event_fences_.front().submission==17);p.completed=16;p.PumpRivalsEventFences();assert(p.memory.fence==0&&p.memexport_await_pending_);p.completed=17;p.PumpRivalsEventFences();assert(p.memory.fence==123&&!p.memexport_await_pending_);}
 {D3D12CommandProcessor p;assert(p.TryWriteMemexportGpuFence(0x1000,1));p.submission_open=true;assert(p.TryWriteMemexportGpuFence(0x1000,2));assert(p.submits==1&&p.current==43&&p.memexport_awaited_submission_==42);p.memexport_awaited_submission_=43;assert(p.TryWriteMemexportGpuFence(0x1000,3));assert(p.submits==2&&p.rivals_event_fences_.back().submission==43);p.completed=42;p.PumpRivalsEventFences();assert(p.memory.fence==2&&p.memexport_await_pending_);p.completed=43;p.PumpRivalsEventFences();assert(p.memory.fence==3&&!p.memexport_await_pending_);}
 {D3D12CommandProcessor p;p.completed=42;p.PumpRivalsEventFences();assert(p.memexport_await_pending_);}
 {D3D12CommandProcessor p;for(uint32_t i=1;i<=60;++i){p.submission_open=true;assert(p.TryWriteMemexportGpuFence(0x1000,i));}assert(p.submits==1&&p.current==43&&p.memory.fence==0);p.completed=42;p.PumpRivalsEventFences();assert(p.memory.fence==60&&p.rivals_event_fences_.empty()&&!p.memexport_await_pending_);}

 for(unsigned rejected=0;rejected<8;rejected++){
  D3D12CommandProcessor p;
  if(rejected==0)cvars::d3d12_rivals_gpu_event_fences=false;
  if(rejected==1)p.memexport_staged_.push_back(1);
  if(rejected==2)p.mem.host=nullptr;
  if(rejected==3)p.trace_writer_.open=true;
  if(rejected==4)p.committed=0;
  if(rejected==5)kernel::KernelState::shared()->title=0x12345678;
  if(rejected==6)p.begin=false;
  if(rejected==7)p.reader_.words[1]=0x20000102;
  assert(p.ExecutePacketType3_EVENT_WRITE_SHD(0,3));assert(p.waits==1&&!p.memexport_await_pending_&&p.memory.fence==0x44332211&&p.rivals_event_fences_.empty()&&p.trace_writer_.writes==1);
  cvars::d3d12_rivals_gpu_event_fences=true;kernel::KernelState::shared()->title=0x454109C6;
 }
 {D3D12CommandProcessor p;p.rivals_event_fences_.resize(4096,{42,0x1000,1});assert(!p.TryWriteMemexportGpuFence(0x1000,123));assert(p.submits==0);}
 {D3D12CommandProcessor p;assert(!p.TryWriteMemexportGpuFence(0x1001,123));assert(!p.TryWriteMemexportGpuFence(0x20000000,123));assert(p.order.empty());}
 {D3D12CommandProcessor p;p.memexport_await_pending_=false;assert(p.ExecutePacketType3_EVENT_WRITE_SHD(0,3));assert(p.waits==0&&p.memory.fence==0x44332211&&p.rivals_event_fences_.empty());}
 {D3D12CommandProcessor p;kernel::KernelState::shared()->title=0;p.trace_title=0x454109C6;assert(p.TryWriteMemexportGpuFence(0x1000,123));assert(p.memory.fence==0);p.CompleteGpu();assert(p.memory.fence==123);kernel::KernelState::shared()->title=0x454109C6;}
 std::puts("PASS: actual PM4/deferred-fence methods preserve actual export-owner CPU visibility, unrelated-work independence, batching, bounded queues, endian/counter semantics and synchronous fallbacks.");
}
'''
cpp=a.output.with_suffix('.cpp');cpp.write_text(prefix+method+'\n'+prepare+'\n'+packet+'\n'+suffix)
subprocess.run([a.cxx,'-O2','-static','-std=c++17',str(cpp),'-o',str(a.output)],check=True)
