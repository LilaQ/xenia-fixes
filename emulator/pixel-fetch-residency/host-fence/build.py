from pathlib import Path
import argparse, shutil, struct, hashlib, subprocess, pefile
parser = argparse.ArgumentParser(description="Add host-read fences to the pinned pixel-vfetch-fixed Edge binary.")
parser.add_argument('--exe', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--nasm', default=shutil.which('nasm'))
args = parser.parse_args()
if args.exe.resolve() == args.out.resolve():
    parser.error('Input and output must be separate executables.')
if not args.nasm:
    parser.error('NASM is required; use --nasm to specify its path.')
args.out.parent.mkdir(parents=True, exist_ok=True)
w = args.out.parent
base = args.exe.read_bytes()
assert hashlib.sha256(base).hexdigest()=='03bf500faf92d58a0a6ca801b0f5dbe8a9fa98ca7870ebd6d91e610241a94c92'
p=pefile.PE(data=base)
def align(v,a):return(v+a-1)&-a
last=p.sections[-1];rva=align(last.VirtualAddress+max(last.Misc_VirtualSize,last.SizeOfRawData),p.OPTIONAL_HEADER.SectionAlignment)
hook=0x71a7a1;old=bytes.fromhex('4584f60f8479e3ffff');assert bytes(p.get_data(hook,9))==old
asm=f"""bits 64
org {rva}
mov [rsp],rax
mov [rsp+8],rcx
cmp byte [rbp+2],0
je done
mov rax,[r15+0x17f8]
test rax,rax
je done
mov rcx,[rax+8]
mov [r15+0x5b50],rcx
mov byte [r15+0x5b41],1
done:
mov rcx,[rsp+8]
mov rax,[rsp]
test r14b,r14b
jz 0x718b23
jmp 0x71a7aa
times 0x100-($-$$) db 0
"""
(w/'fence.asm').write_text(asm);subprocess.run([args.nasm,'-f','bin',str(w/'fence.asm'),'-o',str(w/'fence.bin')],check=True)
a=bytearray((w/'fence.bin').read_bytes());uw=len(a);a+=bytes.fromhex('21000000')+struct.pack('<III',0x718a80,0x71b70c,0x214c428)
table=len(a);d=p.OPTIONAL_HEADER.DATA_DIRECTORY[3];oldtable=bytes(p.get_data(d.VirtualAddress,d.Size));a+=oldtable+struct.pack('<III',rva,rva+0x100,rva+uw)
vs=len(a);rs=align(vs,p.OPTIONAL_HEADER.FileAlignment);a+=bytes(rs-vs);raw=align(len(base),p.OPTIONAL_HEADER.FileAlignment);out=bytearray(base)+bytes(raw-len(base))+a
header=last.get_file_offset()+40;assert header+40<=min(s.PointerToRawData for s in p.sections);struct.pack_into('<8sIIIIIIHHI',out,header,b'.fence\0\0',vs,rva,rs,raw,0,0,0,0,0x60000020)
struct.pack_into('<H',out,p.FILE_HEADER.get_field_absolute_offset('NumberOfSections'),p.FILE_HEADER.NumberOfSections+1)
for k,v in [('SizeOfImage',align(rva+vs,p.OPTIONAL_HEADER.SectionAlignment)),('SizeOfCode',p.OPTIONAL_HEADER.SizeOfCode+rs),('CheckSum',0)]:struct.pack_into('<I',out,p.OPTIONAL_HEADER.get_field_absolute_offset(k),v)
struct.pack_into('<I',out,d.get_field_absolute_offset('VirtualAddress'),rva+table);struct.pack_into('<I',out,d.get_field_absolute_offset('Size'),len(oldtable)+12)
at=p.get_offset_from_rva(hook);out[at:at+9]=b'\xe9'+struct.pack('<i',rva-hook-5)+b'\x90'*4
q=pefile.PE(data=bytes(out));struct.pack_into('<I',out,p.OPTIONAL_HEADER.get_field_absolute_offset('CheckSum'),q.generate_checksum());args.out.write_bytes(out);print(hashlib.sha256(out).hexdigest())
