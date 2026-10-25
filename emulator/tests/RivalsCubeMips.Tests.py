from pathlib import Path
import os, subprocess, sys, tempfile
if len(sys.argv)!=2:raise SystemExit('Usage: RivalsCubeMips.Tests.py <Xenia source root>')
s=(Path(sys.argv[1])/'src/xenia/gpu/texture_cache.cc').read_text()
a=s.index('bool TextureCache::Texture::MakeUpToDateAndWatch(');b=s.index('void TextureCache::Texture::MarkAsUsed()',a);methods=s[a:b]
a=s.index('void TextureCache::Texture::WatchCallback(');b=s.index('void TextureCache::DestroyAllTextures(',a);methods+=s[a:b]
pre=r'''
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <vector>
#define assert_true(x) assert(x)
#define assert_not_zero(x) assert(x)
namespace xe {template<typename T>T align(T x,T a){return (x+a-1)&~(a-1);}}
namespace xenos {constexpr uint32_t kTextureMaxMips=15;enum class DataDimension{kCube,k2DOrStacked};}
struct Lock {~Lock(){} bool owns_lock()const{return true;}};
using global_unique_lock_type=Lock;
struct Region {Lock Acquire(){return {};}};
struct SharedMemory {
 using Callback=void(*)(const Lock&,void*,void*,uint64_t,bool);using WatchHandle=void*;
 struct Watch {uint32_t a,n;Callback cb;void* ctx;uint64_t arg;bool active=true;};
 std::vector<std::unique_ptr<Watch>> watches;bool valid=true,callback=false;
 bool IsRangeValid(uint32_t,uint32_t){return valid;}
 WatchHandle WatchMemoryRange(uint32_t a,uint32_t n,Callback cb,void* ctx,void*,uint64_t arg){assert(!callback);watches.push_back(std::make_unique<Watch>(Watch{a,n,cb,ctx,arg}));return watches.back().get();}
 void UnwatchMemoryRange(WatchHandle h){assert(!callback);auto* w=static_cast<Watch*>(h);assert(w->active);w->active=false;}
 void Fire(uint32_t a,uint32_t n){uint32_t end=(a+n+4095u)&~4095u;a&=~4095u;n=end-a;for(auto& w:watches){if(w->active&&a<w->a+w->n&&a+n>w->a){w->active=false;callback=true;w->cb({},w->ctx,nullptr,w->arg,true);callback=false;}}}
 size_t active(){size_t n=0;for(auto& w:watches)n+=w->active;return n;}
};
struct Key {xenos::DataDimension dimension=xenos::DataDimension::kCube;uint32_t array_size=6;uint32_t GetDepthOrArraySize() const {return array_size;}bool tiled=false,scaled_resolve=false,packed_mips=false;uint32_t mip_max_level=6,base_page=1,mip_page=16;};
struct Layout {struct Level {uint32_t array_slice_stride_bytes=4096,level_data_extent_bytes=6*4096;};Level base;Level mips[15];uint32_t mip_offsets_bytes[15]{};uint32_t mips_total_extent_bytes=6*6*4096;};
struct TextureCache {
 Region global_critical_region_;SharedMemory mem;std::atomic<bool> texture_became_outdated_{false};SharedMemory& shared_memory(){return mem;}
 struct Texture {
  TextureCache& texture_cache_;Key key_;Layout guest_layout_;bool base_range_tracking_=false;uint32_t dirty_base_first_=UINT32_MAX,dirty_base_end_=0;std::vector<SharedMemory::WatchHandle> base_range_watch_handles_;bool base_outdated_=false,mips_outdated_=true,mip_level_tracking_=false;uint32_t mip_levels_outdated_=0;std::array<uint8_t,15> mip_slices_outdated_{};std::array<SharedMemory::WatchHandle,90> mip_level_watch_handles_{};SharedMemory::WatchHandle mips_watch_handle_=nullptr,base_watch_handle_=nullptr;
  explicit Texture(TextureCache& c):texture_cache_(c){for(uint32_t i=1;i<=6;++i)guest_layout_.mip_offsets_bytes[i]=(i-1)*6*4096;}
  ~Texture(){for(auto h:base_range_watch_handles_)if(h)texture_cache_.mem.UnwatchMemoryRange(h);for(auto h:mip_level_watch_handles_)if(h)texture_cache_.mem.UnwatchMemoryRange(h);if(mips_watch_handle_)texture_cache_.mem.UnwatchMemoryRange(mips_watch_handle_);if(base_watch_handle_)texture_cache_.mem.UnwatchMemoryRange(base_watch_handle_);}
  TextureCache& texture_cache(){return texture_cache_;}const Key& key(){return key_;}const Layout& guest_layout(){return guest_layout_;}
  uint32_t GetGuestBaseSize(){return guest_layout_.base.level_data_extent_bytes;}uint32_t GetGuestMipsSize(){return guest_layout_.mips_total_extent_bytes;}
  void EnableBaseRangeTracking();std::pair<uint32_t,uint32_t> GetDirtyBaseBytes();std::vector<std::pair<uint32_t,uint32_t>> GetDirtyBaseBands(uint32_t);void BaseRangeWatchCallback(const Lock&,uint32_t);bool MakeUpToDateAndWatch(const Lock&);bool EnableMipLevelTracking();uint32_t GetOutdatedMipLevels();uint32_t GetOutdatedMipSlices(uint32_t);void MipLevelWatchCallback(const Lock&,uint32_t,uint32_t);void WatchCallback(const Lock&,bool);
 };
 static void BaseRangeWatchCallback(const Lock&,void*,void*,uint64_t,bool);static void MipLevelWatchCallback(const Lock&,void*,void*,uint64_t,bool);static void WatchCallback(const Lock&,void*,void*,uint64_t,bool);
};
'''
post=r'''
int main(){
 TextureCache c;
 {TextureCache::Texture t(c);assert(t.GetOutdatedMipLevels()==UINT32_MAX);assert(t.EnableMipLevelTracking());assert(!t.EnableMipLevelTracking());assert(t.GetOutdatedMipLevels()==0x7e);assert(t.GetOutdatedMipSlices(3)==63);assert(t.MakeUpToDateAndWatch({}));assert(t.GetOutdatedMipLevels()==0);assert(c.mem.active()==36);
 auto base=t.key_.mip_page<<12;c.mem.Fire(base+t.guest_layout_.mip_offsets_bytes[3]+128,64);assert(t.GetOutdatedMipLevels()==8);assert(t.GetOutdatedMipSlices(3)==1);
 c.mem.Fire(base+t.guest_layout_.mip_offsets_bytes[3]+4*4096,64);assert(t.GetOutdatedMipSlices(3)==17);assert(t.mips_outdated_);assert(c.texture_became_outdated_);assert(t.MakeUpToDateAndWatch({}));assert(t.GetOutdatedMipLevels()==0);assert(c.mem.active()==36);
 c.mem.Fire(base+t.guest_layout_.mip_offsets_bytes[2]+5*4096,8192);assert(t.GetOutdatedMipLevels()==12);c.mem.valid=false;assert(!t.MakeUpToDateAndWatch({}));assert(t.GetOutdatedMipLevels()==12);c.mem.valid=true;assert(t.MakeUpToDateAndWatch({}));assert(t.GetOutdatedMipLevels()==0);
 c.mem.Fire(base,6*6*4096);assert(t.GetOutdatedMipLevels()==0x7e);assert(t.MakeUpToDateAndWatch({}));
 t.base_outdated_=true;assert(t.MakeUpToDateAndWatch({}));c.mem.Fire(t.key_.base_page<<12,1);assert(t.base_outdated_);assert(t.GetOutdatedMipLevels()==0);
 }
 assert(c.mem.active()==0);
 {TextureCache::Texture t(c);t.key_.packed_mips=true;assert(!t.EnableMipLevelTracking());assert(t.GetOutdatedMipLevels()==UINT32_MAX);}
 for(uint32_t count:{0u,15u}){TextureCache::Texture t(c);t.key_.mip_max_level=count;assert(!t.EnableMipLevelTracking());}
 {TextureCache::Texture t(c);assert(t.MakeUpToDateAndWatch({}));assert(!t.EnableMipLevelTracking());c.mem.Fire(t.key_.mip_page<<12,1);assert(t.EnableMipLevelTracking());assert(t.GetOutdatedMipLevels()==0x7e);}

 {TextureCache::Texture t(c);t.key_.dimension=xenos::DataDimension::k2DOrStacked;t.key_.array_size=1;t.key_.mip_max_level=0;t.guest_layout_.base.level_data_extent_bytes=8u<<20;t.base_outdated_=true;t.mips_outdated_=false;
 t.EnableBaseRangeTracking();auto d=t.GetDirtyBaseBytes();assert(d.first==0&&d.second==(8u<<20));assert(t.MakeUpToDateAndWatch({}));assert(c.mem.active()==128);
 uint32_t base=t.key_.base_page<<12;c.mem.Fire(base+262144+4096,16);d=t.GetDirtyBaseBytes();assert(d.first==262144&&d.second==327680);assert(t.base_outdated_);assert(t.MakeUpToDateAndWatch({}));assert(c.mem.active()==128);
 c.mem.Fire(base+65536-16,32);d=t.GetDirtyBaseBytes();assert(d.first==0&&d.second==131072);assert(t.MakeUpToDateAndWatch({}));
 c.mem.Fire(base+(8u<<20)-1,1);d=t.GetDirtyBaseBytes();assert(d.first==(8u<<20)-65536&&d.second==(8u<<20));assert(t.MakeUpToDateAndWatch({}));
 c.mem.Fire(base+65536,1);c.mem.Fire(base+5*65536,1);d=t.GetDirtyBaseBytes();assert(d.first==65536&&d.second==6*65536);auto bands=t.GetDirtyBaseBands(65536);assert(bands.size()==2&&bands[0].first==65536&&bands[0].second==2*65536&&bands[1].first==5*65536&&bands[1].second==6*65536);bands=t.GetDirtyBaseBands(262144);assert(bands.size()==1&&bands[0].first==0&&bands[0].second==524288);assert(t.MakeUpToDateAndWatch({}));
 c.mem.Fire(base,8u<<20);d=t.GetDirtyBaseBytes();assert(d.first==0&&d.second==(8u<<20));assert(t.MakeUpToDateAndWatch({}));
 }
 assert(c.mem.active()==0);
 std::cout<<"PASS: actual cube and atlas watch methods, full initial load, boundary writes, disjoint writes, cleanup.\n";
}
'''
with tempfile.TemporaryDirectory(prefix='rivals-mips-',dir=Path.cwd()) as tmp:
 p=Path(tmp)/'test.cpp';p.write_text(pre+post.split('int main(){')[0]+methods+'int main(){'+post.split('int main(){',1)[1])
 subprocess.run([os.environ.get('CXX','clang++'),'-std=c++17','-Wall','-Wextra','-Wno-unused-parameter','-fsanitize=undefined',str(p),'-o',str(p.with_suffix(''))],check=True,timeout=60)
 subprocess.run([str(p.with_suffix(''))],check=True,timeout=15)
