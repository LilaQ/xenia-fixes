from pathlib import Path
import argparse,struct,pefile
from unicorn import Uc,UC_ARCH_X86,UC_MODE_64,UC_HOOK_CODE
from unicorn import x86_const as R
parser=argparse.ArgumentParser()
parser.add_argument('--original',type=Path,required=True)
parser.add_argument('--fixed',type=Path,required=True)
args=parser.parse_args()
w=Path(__file__).parent;p=pefile.PE(str(args.fixed));original=pefile.PE(str(args.original));s=p.sections[-1]
assert len(p.sections)==len(original.sections)+1
assert s.Name.rstrip(b'\0')==b'.pfetch' and s.Characteristics==0x60000020
assert p.OPTIONAL_HEADER.CheckSum==p.generate_checksum()
d=p.OPTIONAL_HEADER.DATA_DIRECTORY[3];entries=list(struct.iter_unpack('<III',p.get_data(d.VirtualAddress,d.Size)))
assert entries==sorted(entries)
assert p.get_data(entries[-1][2],16)==bytes.fromhex('21000000')+struct.pack('<III',0x499800,0x49ce44,0xfb646c)
for a,b in zip(original.sections,p.sections):
 old=bytearray(a.get_data());new=bytearray(b.get_data())
 if a.VirtualAddress<=0x49be05<a.VirtualAddress+a.SizeOfRawData:
  at=0x49be05-a.VirtualAddress;new[at:at+8]=old[at:at+8]
 assert old==new
count=0
for base in [p.OPTIONAL_HEADER.ImageBase,0x7ff640000000]:
 for null in [False,True]:
  for index in range(3):
   for vs,ps in [(0,0),(0,1),(1,0),(1,1),(0x80000000,2),(0xAAAAAAAA,0x55555555)]:
    m=Uc(UC_ARCH_X86,UC_MODE_64);m.mem_map(base+0x49b000,0x2000);m.mem_write(base+0x49b000,bytes(p.get_data(0x49b000,0x2000)));m.mem_map(base+s.VirtualAddress,(s.Misc_VirtualSize+4095)&-4096);m.mem_write(base+s.VirtualAddress,bytes(s.get_data()))
    h=0x10000000;m.mem_map(h,0x10000);frame=h+0x1000;sp=h+0x8000;v=h+0x2000;pix=h+0x3000
    m.mem_write(frame+0xa0,struct.pack('<Q',0 if null else pix));m.mem_write(v+0xcc+index*4,struct.pack('<I',vs));m.mem_write(pix+0xcc+index*4,struct.pack('<I',ps))
    vals={k:0x5555000000000000+i for i,k in enumerate(['RAX','RCX','RDX','RBX','RSI','R8','R9','R10','R11','R13','R14','R15'])};vals.update({'RSP':sp,'RBP':frame,'RDI':v,'R12':index})
    for k,val in vals.items():m.reg_write(getattr(R,'UC_X86_REG_'+k),val)
    def stop(uc,address,size,data):
     if address==base+0x49be0d:uc.emu_stop()
    stop_handle=m.hook_add(UC_HOOK_CODE,stop);m.emu_start(base+0x49be05,base+0x49be0d,count=100)
    expected=vs|(0 if null else ps)
    assert m.reg_read(R.UC_X86_REG_RDI)==expected
    for k,val in vals.items():
     if k!='RDI':assert m.reg_read(getattr(R,'UC_X86_REG_'+k))==val,k
    m.hook_del(stop_handle)
    m.emu_start(base+0x49be0d,base+0x49be10,count=1)
    assert bool(m.reg_read(R.UC_X86_REG_EFLAGS)&64)==(expected==0)
    if expected:assert m.reg_read(R.UC_X86_REG_RAX)==(expected&-expected).bit_length()-1
    count+=1
print('PASS',count,'actual x64 executions: all bitmap words, PS-only fetches, shared slots, null PS, ASLR, preserved registers/stack and original bit scan')
print('PASS original sections preserved except one hook, sorted chained unwind and PE checksum')
