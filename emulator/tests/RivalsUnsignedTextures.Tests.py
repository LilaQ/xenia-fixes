from pathlib import Path
import os,subprocess,sys,tempfile
if len(sys.argv)!=2:raise SystemExit('Usage: RivalsUnsignedTextures.Tests.py <Xenia source root>')
r=Path(sys.argv[1])/'src/xenia/gpu'
s=(r/'d3d12/pipeline_cache.cc').read_text();a=s.index('uint64_t PipelineCache::GetCurrentSpirvPixelShaderModification(');b=s.index('\nbool PipelineCache::precise_interpolation_supported()',a);method=s[a:b]
s=(r/'texture_util.cc').read_text();a=s.index('uint8_t SwizzleSigns(');b=s.index('\nvoid GetClampModesForDimension',a);swizzle=s[a:b]
pre=r'''
#include <array>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>
namespace xenos {enum class TextureSign:uint32_t{kUnsigned,kSigned,kUnsignedBiased,kGamma};enum class FetchConstantType:uint32_t{kInvalidTexture,kInvalidVertex,kTexture,kVertex};struct xe_gpu_texture_fetch_t{FetchConstantType type=FetchConstantType::kTexture;uint32_t dword_0=0,swizzle=0x688;};}
namespace texture_util {
'''
mid=r'''
}
namespace cvars {bool d3d12_static_unsigned_texture_signs=true;}
namespace reg {struct RB_DEPTHCONTROL{};}
struct Shader {bool dynamic=false;struct Binding{uint32_t fetch_constant;};std::vector<Binding> bindings{{0},{7},{0}};bool uses_register_dynamic_addressing()const{return dynamic;}const auto& texture_bindings()const{return bindings;}};
struct SpirvShaderTranslator {union Modification{uint64_t value;struct{uint32_t lower;uint32_t dynamic_addressable_register_count:7;uint32_t remaining:25;}pixel;explicit Modification(uint64_t x):value(x){}};};
static_assert(sizeof(SpirvShaderTranslator::Modification)==8);
struct RegisterFile{std::array<xenos::xe_gpu_texture_fetch_t,32> fetches{};mutable std::array<unsigned,32> reads{};auto GetTextureFetch(uint32_t i)const{assert(i<32);++reads[i];return fetches[i];}};
struct Cache{uint64_t value=0x0C21000000000001ull;uint64_t GetPixelShaderModification(const Shader&,uint32_t,uint32_t,reg::RB_DEPTHCONTROL,uint32_t,bool)const{return value;}};
struct PipelineCache{RegisterFile register_file_;Cache guest_shader_cache_;uint64_t GetCurrentSpirvPixelShaderModification(const Shader&,uint32_t,uint32_t,reg::RB_DEPTHCONTROL,uint32_t,bool)const;};
'''
post=r'''
int main(){
 PipelineCache p;Shader shader;auto key=[&]{return p.GetCurrentSpirvPixelShaderModification(shader,1,16,{},15,false);};auto base=p.guest_shader_cache_.value;const uint64_t specialized=base|(uint64_t(1)<<32);
 assert(key()==specialized);assert(p.register_file_.reads[0]==1&&p.register_file_.reads[7]==1);
 // Each draw must re-evaluate signs, even when the shader stays unchanged.
 for(uint32_t sign:{1u,2u,3u}){p.register_file_.fetches[7].dword_0=(sign*0x55)<<2;assert(key()==base);p.register_file_.fetches[7].dword_0=0;assert(key()==specialized);}
 auto& f=p.register_file_.fetches[7];f.type=xenos::FetchConstantType::kInvalidTexture;assert(key()==base);f.type=xenos::FetchConstantType::kTexture;
 // Swizzled-away signed channels and constant-only views must match TextureCache.
 f.dword_0=1u<<2;f.swizzle=0x249;assert(key()==specialized);f.swizzle=0;assert(key()==base);
 f.dword_0=0x55u<<2;f.swizzle=0x924;assert(key()==base);f.dword_0=1u<<2;assert(key()==specialized);
 f={};shader.dynamic=true;p.guest_shader_cache_.value=base|(uint64_t(64)<<32);p.register_file_.reads.fill(0);assert(key()==p.guest_shader_cache_.value);assert(p.register_file_.reads[0]==0);
 shader.dynamic=false;p.guest_shader_cache_.value=base;cvars::d3d12_static_unsigned_texture_signs=false;assert(key()==base);cvars::d3d12_static_unsigned_texture_signs=true;shader.bindings.clear();assert(key()==base);
 std::cout<<"PASS: actual per-draw pipeline selector and TextureCache sign swizzler: unsigned, signed/biased/gamma transitions, duplicate bindings, constant swizzles, invalid texture, indexed-register fallback, disabled and empty paths.\n";
}
'''
with tempfile.TemporaryDirectory(prefix='rivals-signs-',dir=Path.cwd()) as t:
 p=Path(t)/'test.cpp';p.write_text(pre+swizzle+mid+method+post)
 subprocess.run([os.environ.get('CXX','clang++'),'-std=c++17','-Wall','-Wextra','-Wno-unused-parameter','-fsanitize=undefined',str(p),'-o',str(p.with_suffix(''))],check=True,timeout=60)
 subprocess.run([str(p.with_suffix(''))],check=True,timeout=15)
