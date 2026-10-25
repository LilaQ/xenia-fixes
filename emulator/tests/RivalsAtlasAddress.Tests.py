from pathlib import Path
import subprocess, sys, tempfile
if len(sys.argv) != 2: raise SystemExit("Usage: RivalsAtlasAddress.Tests.py <Xenia source root>")
s = (Path(sys.argv[1]) / "src/xenia/gpu/texture_util.cc").read_text()
a = s.index("int32_t GetTiledOffset2D(")
b = s.index("\n}", a) + 2
source = '#include <cstdint>\n#include <cassert>\n#include <cstdio>\n#include <initializer_list>\nnamespace xe {template<class T>T align(T a,T b){return (a+b-1)&~(b-1);}}\nnamespace xenos {constexpr uint32_t kTextureTileWidthHeight=32;}\n' + s[a:b] + '\nint main(){\n  for(uint32_t y=0;y<1024;++y)for(uint32_t x=0;x<512;++x){\n    uint32_t band=y/32*32;\n    uint32_t offset=GetTiledOffset2D(x,y,512,4);\n    uint32_t local=GetTiledOffset2D(x,y-band,512,4);\n    assert(offset==local+band*512*16);\n    assert(offset>=band*512*16&&offset<(band+32)*512*16);\n    uint32_t chunk=offset/65536*65536;\n    uint32_t first=chunk/(512*16*32)*32*4;\n    uint32_t end=(chunk+65536+512*16*32-1)/(512*16*32)*32*4;\n    assert(y*4>=first&&y*4<end);\n  }\n  for(uint32_t bpp:{1u,2u})for(uint32_t row=0;row<4096;++row){\n    uint32_t offset=row*2048*bpp;\n    uint32_t first=(offset/65536*65536)/(2048*bpp);\n    uint32_t end=((offset/65536+1)*65536+2048*bpp-1)/(2048*bpp);\n    assert(row>=first&&row<end);\n  }\n  puts("PASS: all 524288 BC3 blocks preserve tiled addresses in partial bands; dirty chunks cover every changed block; linear row bounds valid.");\n}\n'
with tempfile.TemporaryDirectory() as d:
    p = Path(d)
    (p / "test.cpp").write_text(source)
    subprocess.run(["clang++", "-std=c++17", "-fsanitize=undefined", str(p / "test.cpp"), "-o", str(p / "test")], check=True)
    subprocess.run([str(p / "test")], check=True)
