from pathlib import Path
import argparse,struct,pefile
from unicorn import Uc,UC_ARCH_X86,UC_MODE_64,UC_HOOK_CODE
from unicorn import x86_const as R
parser=argparse.ArgumentParser()
parser.add_argument('--original',type=Path,required=True)
parser.add_argument('--fixed',type=Path,required=True)
args=parser.parse_args()
w=Path(__file__).parent
cases=[({1,32,94},{31,32,63,95},False),(set(),{0,32,95},False),({0,31,63},{0,31,63},False),({1,32,94},{31,63,95},True)]
count=0
for fixed in [False,True]:
 p=pefile.PE(str(args.fixed if fixed else args.original))
 for base in [p.OPTIONAL_HEADER.ImageBase,0x7ff640000000]:
  for vs,ps,null in cases:
   m=Uc(UC_ARCH_X86,UC_MODE_64);m.mem_map(base,(p.OPTIONAL_HEADER.SizeOfImage+4095)&-4096);m.mem_write(base,bytes(p.get_memory_mapped_image()))
   h=0x10000000;m.mem_map(h,0x50000);frame=h+0x1000;stack=h+0xa000;v=h+0x4000;pixel=h+0x5000;regs=h+0x10000
   for obj,slots in [(v,vs),(pixel,ps)]:
    words=[sum(1<<(slot%32) for slot in slots if slot//32==i)for i in range(3)]
    m.mem_write(obj+0xcc,struct.pack('<III',*words))
   m.mem_write(frame+0x90,struct.pack('<Q',v));m.mem_write(frame+0xa0,struct.pack('<Q',0 if null else pixel));m.mem_write(frame+0x98,struct.pack('<Q',regs))
   for slot in range(96):
    address=0x100000+slot*4096;size=32+slot
    m.mem_write(regs+0x12000+slot*8,struct.pack('<II',address|3,size<<2))
   for key,val in {'RSP':stack,'RBP':frame,'RBX':regs,'RDI':v}.items():m.reg_write(getattr(R,'UC_X86_REG_'+key),val)
   def hook(uc,address,size,data):
    if address==base+0x49bfa3:uc.emu_stop()
   m.hook_add(UC_HOOK_CODE,hook);m.emu_start(base+0x49bdeb,base+0x49bfa3,count=5000)
   assert m.reg_read(R.UC_X86_REG_RIP)==base+0x49bfa3
   slots=sorted(vs|(ps if fixed and not null else set()));n=m.reg_read(R.UC_X86_REG_RSI)
   assert n==len(slots),(fixed,vs,ps,null,n)
   addresses=list(struct.unpack('<'+'I'*n,bytes(m.mem_read(frame+0x430,n*4)))) if n else []
   sizes=list(struct.unpack('<'+'I'*n,bytes(m.mem_read(frame+0x2b0,n*4)))) if n else []
   assert addresses==[(0x100000+slot*4096)>>2 for slot in slots],addresses
   assert sizes==[32+slot for slot in slots],sizes
   assert m.reg_read(R.UC_X86_REG_RSP)==stack
   count+=1
print('PASS',count,'original/full fixed loop executions: PS-only slots are missing before and queued after, duplicates once, all bitmap words, exact addresses/sizes, null PS and ASLR')
