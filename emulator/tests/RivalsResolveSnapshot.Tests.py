from pathlib import Path
import os, subprocess, sys, tempfile
if len(sys.argv) != 2:
 raise SystemExit('Usage: RivalsResolveSnapshot.Tests.py <Xenia source root>')
source=(Path(sys.argv[1])/'src/xenia/gpu/d3d12/d3d12_command_processor.cc').read_text()
def method(name,next_name):
 a=source.index('void D3D12CommandProcessor::'+name) if name.startswith('Stage') else source.index('bool D3D12CommandProcessor::'+name)
 b=source.index(next_name,a)
 return source[a:b].replace('D3D12CommandProcessor::','Harness::')
methods=method('StageSmallResolveSnapshot','bool D3D12CommandProcessor::TryConsumeGatHdrSnapshot')+method('TryConsumeSmallResolveSnapshot','bool D3D12CommandProcessor::FaultCopyResolveToGuestRam')
pre=r'''
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <vector>
#include <iostream>
#define FAILED(x) ((x)<0)
#define XELOGI(...) ((void)0)
namespace cvars {bool d3d12_stage_small_readback=true;bool d3d12_submission_timing=false;}
namespace xe {struct Clock {static uint64_t QueryHostTickCount(){return 1;}static uint64_t QueryHostTickFrequency(){return 1;}};}
struct Resource {std::vector<uint8_t> bytes;};
struct Ptr {std::shared_ptr<Resource> p;Resource* Get(){return p.get();}explicit operator bool()const{return bool(p);}};
struct Buffer {Ptr resource;void* mapped=nullptr;};
struct Fence {uint64_t completed=0;bool fail=false;uint64_t waited=0;uint64_t GetCompletedValue(){return completed;}int SetEventOnCompletion(uint64_t n,void*){waited=n;completed=n;return fail?-1:0;}};
using ID3D12Fence=Fence;
struct Timeline {Fence fence;Fence* GetFence(){return &fence;}};
struct Shared {bool zero=false;bool is_zero_copy(){return zero;}void UseAsCopySource(){}void* GetBuffer(){return this;}};
struct Commands {std::map<uint32_t,std::vector<uint8_t>> gpu;int copies=0;void D3DCopyBufferRegion(Resource* dst,uint64_t offset,void*,uint64_t address,uint64_t length){assert(offset+length<=dst->bytes.size());assert(gpu.at(address).size()>=length);std::memcpy(dst->bytes.data()+offset,gpu.at(address).data(),length);++copies;}};
struct Owner {uint32_t address=0,length=0;uint64_t submission=0,generation=0;bool copyable=true;};
struct Snapshot {Buffer buffer;uint32_t address=0,length=0;uint64_t generation=0,submission=0,frame=0;};
struct Harness {
 Shared shared;Shared* shared_memory_=&shared;Timeline timeline;Timeline* completion_timeline_=&timeline;
 std::mutex resolve_read_mutex_;std::map<uint64_t,Owner> resolve_owners_;std::array<std::atomic<uint64_t>,128> resolve_page_owners_{};
 std::array<Snapshot,32> small_resolve_snapshots_{};uint32_t next_small_resolve_snapshot_=0,small_resolve_snapshot_hits_=0;uint64_t small_resolve_snapshot_wait_ticks_=0,small_resolve_snapshot_bytes_=0,resolve_frame_index_=0,current=7;
 Commands deferred_command_list_;bool recent=true,allocation=true;std::vector<uint8_t> guest;int reads=0;
 static uint64_t MakeReadbackResolveKey(uint32_t a,uint32_t n){return (uint64_t(a)<<32)|n;}
 bool ResolveReadRecently(uint64_t,bool){return recent;}void SubmitBarriers(){}uint64_t GetCurrentSubmission(){return current;}
 bool CreateReadbackStagingBuffer(Buffer& b,uint32_t n){if(!allocation)return false;b.resource.p=std::make_shared<Resource>();b.resource.p->bytes.resize(n);b.mapped=b.resource.p->bytes.data();return true;}
 bool TryConsumeGatHdrSnapshot(uint32_t){return false;}
 void CopyPackedRangesToGuestRam(void* p,const std::vector<std::pair<uint32_t,uint32_t>>& ranges){++reads;guest.assign((uint8_t*)p,(uint8_t*)p+ranges.front().second);}
 void owner(uint32_t a,uint32_t n,uint64_t gen=1){auto key=MakeReadbackResolveKey(a,n);resolve_owners_[key]={a,n,current,gen,true};for(uint32_t i=a>>12;i<(a+n)>>12;++i)resolve_page_owners_[i]=key;deferred_command_list_.gpu[a]=std::vector<uint8_t>(n,uint8_t(gen));}
 void StageSmallResolveSnapshot(uint32_t,uint32_t);
 bool TryConsumeSmallResolveSnapshot(const std::vector<std::pair<uint32_t,uint32_t>>&);
};
'''
post=r'''
int main(){
 for(uint32_t size:{4096u,8192u,16384u,65536u}){Harness h;h.owner(0x1000,size);h.StageSmallResolveSnapshot(0x1000,size);assert(h.guest.empty());assert(h.deferred_command_list_.copies==1);assert(h.TryConsumeSmallResolveSnapshot({{0x1000,size}}));assert(h.guest==std::vector<uint8_t>(size,1));assert(h.timeline.fence.waited==7);}
 for(uint32_t size:{0u,1u,4095u,8193u,69632u}){Harness h;h.owner(0x1000,size);h.StageSmallResolveSnapshot(0x1000,size);assert(h.deferred_command_list_.copies==0);assert(!h.TryConsumeSmallResolveSnapshot({{0x1000,size}}));}
 {Harness h;h.owner(0x1001,8192);h.StageSmallResolveSnapshot(0x1001,8192);assert(h.deferred_command_list_.copies==0);}
 {Harness h;h.owner(0x1000,8192);h.StageSmallResolveSnapshot(0x1000,8192);h.owner(0x1000,8192,2);assert(!h.TryConsumeSmallResolveSnapshot({{0x1000,8192}}));h.StageSmallResolveSnapshot(0x1000,8192);assert(h.TryConsumeSmallResolveSnapshot({{0x1000,8192}}));assert(h.guest==std::vector<uint8_t>(8192,2));}
 {Harness h;h.owner(0x1000,16384);h.StageSmallResolveSnapshot(0x1000,16384);h.resolve_page_owners_[3]=99;assert(!h.TryConsumeSmallResolveSnapshot({{0x1000,16384}}));assert(h.guest.empty());}
 {Harness h;h.owner(0x1000,8192);h.StageSmallResolveSnapshot(0x1000,8192);assert(!h.TryConsumeSmallResolveSnapshot({{0x1000,4096}}));assert(!h.TryConsumeSmallResolveSnapshot({{0x1000,4096},{0x2000,4096}}));}
 {Harness h;h.owner(0x1000,8192);for(auto& s:h.small_resolve_snapshots_)s.submission=9;h.StageSmallResolveSnapshot(0x1000,8192);assert(h.deferred_command_list_.copies==0);}
 {Harness h;h.owner(0x1000,8192);h.StageSmallResolveSnapshot(0x1000,8192);h.timeline.fence.fail=true;assert(!h.TryConsumeSmallResolveSnapshot({{0x1000,8192}}));assert(h.guest.empty());}
 {Harness h;h.owner(0x1000,8192);h.recent=false;h.StageSmallResolveSnapshot(0x1000,8192);assert(h.deferred_command_list_.copies==0);}
 {Harness h;h.owner(0x1000,8192);h.shared.zero=true;h.StageSmallResolveSnapshot(0x1000,8192);assert(h.deferred_command_list_.copies==0);}
 {Harness h;h.owner(0x1000,8192);h.allocation=false;h.StageSmallResolveSnapshot(0x1000,8192);assert(h.deferred_command_list_.copies==0);}
 std::cout<<"PASS: actual snapshot methods: 4-64KB exact copies, bounds, generation, partial/mixed owners, busy ring, fence failure, fallback.\n";
}
'''
with tempfile.TemporaryDirectory(prefix='rivals-snapshot-', dir=Path.cwd()) as output:
 p=Path(output)/'snapshot-tests.cpp';p.write_text(pre+methods+post)
 subprocess.run([os.environ.get('CXX','clang++'),'-std=c++17','-Wall','-Wextra','-fsanitize=undefined','-fno-omit-frame-pointer',str(p),'-o',str(p.with_suffix(''))],check=True,timeout=60)
 subprocess.run([str(p.with_suffix(''))],check=True,timeout=15)
