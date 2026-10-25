from pathlib import Path
import argparse, subprocess
ap=argparse.ArgumentParser();ap.add_argument('--source',type=Path,required=True);ap.add_argument('--cxx',required=True);ap.add_argument('--output',type=Path,required=True);args=ap.parse_args()
def function(path,signature):
 s=path.read_text();start=s.index(signature);opening=s.index('{',start);depth=1;i=opening+1
 while depth:
  depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[start:i]
inc=args.source/'src/xenia/gpu/command_processor_memexport.inc'
coher=function(inc,'void AwaitMemexportForCoherency(')
fence=function(inc,'void AwaitMemexportForFence(')
hook=function(args.source/'src/xenia/gpu/d3d12/d3d12_command_processor.cc','bool D3D12CommandProcessor::TryMemexportGpuCoherency(')
prefix=r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <vector>
#define XELOGI(...) do {} while(false)
namespace cvars {bool d3d12_rivals_gpu_atlas_coherency=true;bool d3d12_submission_timing=true;}
namespace kernel {struct KernelState {uint32_t title=0x454109C6;static KernelState* shared(){static KernelState k;return &k;}uint32_t title_id(){return title;}};}
constexpr unsigned XE_GPU_REG_COHER_STATUS_HOST=0xA31;
struct Registers {uint32_t values[0x5000]={};};
struct HostMemory {void* host=(void*)1;std::vector<int> ordered;void* GetHostBuffer(){return host;}void UseHostAsCopySource(){ordered.push_back(1);}};
struct D3D12CommandProcessor {
 HostMemory memory;HostMemory* shared_memory_=&memory;Registers regs;Registers* register_file_=&regs;std::vector<int> memexport_staged_;
 bool memexport_await_pending_=true,overlap=true;uint64_t memexport_awaited_submission_=17,last_waited=0;unsigned waits=0,flushes=0;uint32_t trace_title=0;
 D3D12CommandProcessor(){regs.values[XE_GPU_REG_COHER_STATUS_HOST]=0x83000200;}
 bool IsMemexportRange(uint32_t,uint32_t){return overlap;}
 void AwaitMemexportSubmission(uint64_t owner){++waits;last_waited=owner;}
 void FlushMemexportStagingReadback(){++flushes;}
 void SubmitBarriers(){memory.ordered.push_back(2);}
 uint32_t trace_playback_title_id(){return trace_title;}
 bool TryMemexportGpuCoherency(uint32_t,uint32_t);
'''
suffix=r'''
int main(){
 const uint32_t base=0x0CCA6000,size=0x800000;
 {D3D12CommandProcessor p;p.AwaitMemexportForCoherency(base,size);assert(p.waits==0&&p.flushes==0&&p.memexport_await_pending_);assert((p.memory.ordered==std::vector<int>{1,2}));p.AwaitMemexportForFence();assert(p.waits==1&&p.last_waited==17&&p.flushes==1&&!p.memexport_await_pending_);p.AwaitMemexportForFence();assert(p.waits==1);}
 {D3D12CommandProcessor p;p.AwaitMemexportForCoherency(0x0D4A6000,size);assert(p.waits==0&&p.memexport_await_pending_);}
 for(uint32_t b : {0x1C972000u,0x1C9A9000u,0x1C9E0000u,0x1FC27000u}){D3D12CommandProcessor p;p.AwaitMemexportForCoherency(b,0x37000);assert(p.waits==0&&p.memexport_await_pending_);assert((p.memory.ordered==std::vector<int>{1,2}));p.AwaitMemexportForFence();assert(p.waits==1&&p.last_waited==17&&p.flushes==1&&!p.memexport_await_pending_);}
 for(unsigned rejected=0;rejected<6;rejected++){
  D3D12CommandProcessor p;uint32_t b=base,n=size;
  if(rejected==0)cvars::d3d12_rivals_gpu_atlas_coherency=false;
  if(rejected==1)p.memory.host=nullptr;
  if(rejected==2)p.memexport_staged_.push_back(1);
  if(rejected==3)kernel::KernelState::shared()->title=0x12345678;
  if(rejected==4)p.regs.values[XE_GPU_REG_COHER_STATUS_HOST]=0x81000000;
  if(rejected==5){kernel::KernelState::shared()->title=0x12345678;p.trace_title=0x454109C6;}
  p.AwaitMemexportForCoherency(b,n);assert(p.waits==1&&p.last_waited==17&&p.flushes==1&&!p.memexport_await_pending_&&p.memory.ordered.empty());
  cvars::d3d12_rivals_gpu_atlas_coherency=true;kernel::KernelState::shared()->title=0x454109C6;
 }
 {D3D12CommandProcessor p;p.overlap=false;p.AwaitMemexportForCoherency(base,size);assert(p.waits==0&&p.memory.ordered.empty()&&p.memexport_await_pending_);}
 {D3D12CommandProcessor p;kernel::KernelState::shared()->title=0;p.trace_title=0x454109C6;p.AwaitMemexportForCoherency(base,size);assert(p.waits==0&&p.memexport_await_pending_);kernel::KernelState::shared()->title=0x454109C6;}
 {D3D12CommandProcessor p;p.AwaitMemexportForFence();assert(p.waits==1&&p.last_waited==17&&p.flushes==1&&!p.memexport_await_pending_&&p.memory.ordered.empty());}
 std::puts("PASS: actual GPU-consumer coherency methods retain CPU owner/fences, order GPU reads, and reject unsupported contexts.");
}
'''
cpp=args.output.with_suffix('.cpp');cpp.write_text(prefix+coher+'\n'+fence+'\n};\n'+hook+'\n'+suffix)
subprocess.run([args.cxx,'-O2','-static','-std=c++17',str(cpp),'-o',str(args.output)],check=True)
print('Built coherent-consumer regression executable:',args.output)
