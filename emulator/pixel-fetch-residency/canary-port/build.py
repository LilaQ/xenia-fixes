from pathlib import Path
import argparse,shutil,struct,hashlib,subprocess,pefile
parser=argparse.ArgumentParser(description='Build a version-pinned Canary pixel-vfetch residency continuation.')
parser.add_argument('--exe',type=Path,required=True)
parser.add_argument('--out',type=Path,required=True)
parser.add_argument('--nasm',default=shutil.which('nasm'))
args=parser.parse_args()
if args.exe.resolve()==args.out.resolve():parser.error('Input and output must be separate.')
if not args.nasm:parser.error('NASM is required.')
args.out.parent.mkdir(parents=True,exist_ok=True)
w=args.out.parent
base=args.exe.read_bytes()
assert hashlib.sha256(base).hexdigest()=='4350d19679e9278e333baf67911223b26639ce4ff937a484dbe92ec45adf62f4'
p=pefile.PE(data=base)
def align(v,a):return(v+a-1)&-a
last=p.sections[-1];rva=align(last.VirtualAddress+max(last.Misc_VirtualSize,last.SizeOfRawData),p.OPTIONAL_HEADER.SectionAlignment)
hook=0x49be05;old=bytes.fromhex('428bbca7cc000000');assert bytes(p.get_data(hook,8))==old
asm=f"""bits 64
org {rva}
mov [rsp],rax
mov edi,[rdi+r12*4+0xcc]
mov rax,[rbp+0xa0]
test rax,rax
jz done
or edi,[rax+r12*4+0xcc]
done:
mov rax,[rsp]
jmp 0x49be0d
times 0x100-($-$$) db 0
"""
(w/'fetch.asm').write_text(asm);subprocess.run([args.nasm,'-f','bin',str(w/'fetch.asm'),'-o',str(w/'fetch.bin')],check=True)
a=bytearray((w/'fetch.bin').read_bytes());uw=len(a);a+=bytes.fromhex('21000000')+struct.pack('<III',0x499800,0x49ce44,0xfb646c)
table=len(a);d=p.OPTIONAL_HEADER.DATA_DIRECTORY[3];oldtable=bytes(p.get_data(d.VirtualAddress,d.Size));a+=oldtable+struct.pack('<III',rva,rva+0x100,rva+uw)
vs=len(a);rs=align(vs,p.OPTIONAL_HEADER.FileAlignment);a+=bytes(rs-vs);raw=align(len(base),p.OPTIONAL_HEADER.FileAlignment);out=bytearray(base)+bytes(raw-len(base))+a
header=last.get_file_offset()+40;assert header+40<=min(s.PointerToRawData for s in p.sections);struct.pack_into('<8sIIIIIIHHI',out,header,b'.pfetch\0',vs,rva,rs,raw,0,0,0,0,0x60000020)
struct.pack_into('<H',out,p.FILE_HEADER.get_field_absolute_offset('NumberOfSections'),p.FILE_HEADER.NumberOfSections+1)
for k,v in [('SizeOfImage',align(rva+vs,p.OPTIONAL_HEADER.SectionAlignment)),('SizeOfCode',p.OPTIONAL_HEADER.SizeOfCode+rs),('CheckSum',0)]:struct.pack_into('<I',out,p.OPTIONAL_HEADER.get_field_absolute_offset(k),v)
struct.pack_into('<I',out,d.get_field_absolute_offset('VirtualAddress'),rva+table);struct.pack_into('<I',out,d.get_field_absolute_offset('Size'),len(oldtable)+12)
at=p.get_offset_from_rva(hook);out[at:at+8]=b'\xe9'+struct.pack('<i',rva-hook-5)+b'\x90'*3
q=pefile.PE(data=bytes(out));struct.pack_into('<I',out,p.OPTIONAL_HEADER.get_field_absolute_offset('CheckSum'),q.generate_checksum());args.out.write_bytes(out);print(hashlib.sha256(out).hexdigest())
