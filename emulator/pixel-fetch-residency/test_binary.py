"""Execute the installed-build correction against synthetic analyzed shaders."""
from pathlib import Path
import argparse
import struct
import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
from unicorn import x86_const as R
from build_fix import HOOK_RVA,RESUME_RVA,HOOK_BYTES,PARENT,CODE_SIZE
w=Path(__file__).parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--original',type=Path,default=w.parent/'edge-original.exe')
parser.add_argument('--fixed',type=Path,default=w/'xenia_edge_rise.exe')
args=parser.parse_args()
pe=pefile.PE(str(args.fixed))
section=pe.sections[-1]
assert section.Name.rstrip(b'\0')==b'.pfetch'
assert section.Characteristics==0x60000020
assert pe.OPTIONAL_HEADER.CheckSum==pe.generate_checksum()
d=pe.OPTIONAL_HEADER.DATA_DIRECTORY[3];entries=list(struct.iter_unpack('<III',pe.get_data(d.VirtualAddress,d.Size)))
assert entries==sorted(entries)
assert all(a[1]<=b[0] for a,b in zip(entries,entries[1:]))
assert entries[-1][:2]==(section.VirtualAddress,section.VirtualAddress+CODE_SIZE)
assert pe.get_data(entries[-1][2],16)==bytes.fromhex('21000000')+struct.pack('<III',*PARENT)
original=pefile.PE(str(args.original))
for old,new in zip(original.sections,pe.sections):
 before=bytearray(old.get_data());after=bytearray(new.get_data());assert len(before)==len(after)
 if old.VirtualAddress<=HOOK_RVA<old.VirtualAddress+old.SizeOfRawData:
  off=HOOK_RVA-old.VirtualAddress;after[off:off+len(HOOK_BYTES)]=HOOK_BYTES
 assert before==after,'An unrelated original section byte changed'
count=0
for base in [pe.OPTIONAL_HEADER.ImageBase,0x7FF620000000]:
 for index in range(3):
  for vs,ps in [(0,0xC0000000),(0x100,0),(0xFFFFFFFF,0x12345),(0xC0000000,0xC0000000),(0,None)]:
   m=Uc(UC_ARCH_X86,UC_MODE_64)
   page=HOOK_RVA&-4096;m.mem_map(base+page,4096);m.mem_write(base+page,bytes(pe.get_data(page,4096)))
   m.mem_map(base+section.VirtualAddress,(section.Misc_VirtualSize+4095)&-4096);m.mem_write(base+section.VirtualAddress,bytes(section.get_data()))
   h=0x10000000;m.mem_map(h,0x10000);vertex=h+0x1000;pixel=h+0x2000;frame=h+0x3000
   m.mem_write(vertex+0xCC+index*4,struct.pack('<I',vs))
   if ps is not None:m.mem_write(pixel+0xCC+index*4,struct.pack('<I',ps))
   m.mem_write(frame+0x18,struct.pack('<Q',0 if ps is None else pixel))
   values={'RAX':index,'R10':index,'RDI':vertex,'RBP':frame,'RSP':h+0x9000,'R8':0xDEADBEEFCAFEBABE}
   for num,name in enumerate(['RBX','RCX','RDX','RSI','R9','R11','R12','R13','R14','R15']):values[name]=0x5555000000000000+num
   for name,value in values.items():m.reg_write(getattr(R,'UC_X86_REG_'+name),value)
   def stop(uc,address,size,data):
    if address==base+RESUME_RVA:uc.emu_stop()
   m.hook_add(UC_HOOK_CODE,stop);m.emu_start(base+HOOK_RVA,base+RESUME_RVA,count=40)
   assert m.reg_read(R.UC_X86_REG_RIP)==base+RESUME_RVA
   for name,value in values.items():
    expected=(vs|(ps or 0)) if name=='R8' else value
    assert m.reg_read(getattr(R,'UC_X86_REG_'+name))==expected,(name,index,vs,ps)
   count+=1
print('PASS:',count,'x64 executions: all bitmap words, PS-only/overlap/null, ASLR and register/stack preservation')
print('PASS: original section bytes preserved except the verified hook; valid PE checksum and chained unwind')
