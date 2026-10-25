from pathlib import Path
import argparse, hashlib, struct, pefile
from unicorn import Uc,UC_ARCH_X86,UC_MODE_64,UC_HOOK_CODE
from unicorn import x86_const as R
parser = argparse.ArgumentParser(description="Execute the host fence continuation and original fence dispatch in x64 Unicorn.")
parser.add_argument('--original', type=Path, required=True)
parser.add_argument('--fixed', type=Path, required=True)
args = parser.parse_args()
p=pefile.PE(str(args.fixed));s=p.sections[-1];assert s.Name.rstrip(b'\0')==b'.fence';assert s.Characteristics==0x60000020;assert p.OPTIONAL_HEADER.CheckSum==p.generate_checksum()
d=p.OPTIONAL_HEADER.DATA_DIRECTORY[3];entries=list(struct.iter_unpack('<III',p.get_data(d.VirtualAddress,d.Size)));assert entries==sorted(entries);assert entries[-1][:2]==(s.VirtualAddress,s.VirtualAddress+256);assert p.get_data(entries[-1][2],16)==bytes.fromhex('21000000')+struct.pack('<III',0x718a80,0x71b70c,0x214c428)
original=pefile.PE(str(args.original))
assert hashlib.sha256(args.original.read_bytes()).hexdigest()=='03bf500faf92d58a0a6ca801b0f5dbe8a9fa98ca7870ebd6d91e610241a94c92'
assert len(p.sections)==len(original.sections)+1
for a,b in zip(original.sections,p.sections):
 old=bytearray(a.get_data());new=bytearray(b.get_data())
 if a.VirtualAddress<=0x71a7a1<a.VirtualAddress+a.SizeOfRawData:
  at=0x71a7a1-a.VirtualAddress;new[at:at+9]=old[at:at+9]
 assert old==new
count=0
for base in [p.OPTIONAL_HEADER.ImageBase,0x7ff620000000]:
 for host in [0,1]:
  for producer in [0,1]:
   for submission in [None,0,1,123456789012]:
    for pending in [0,1]:
     m=Uc(UC_ARCH_X86,UC_MODE_64);m.mem_map(base+0x718000,0x4000);m.mem_write(base+0x718000,bytes(p.get_data(0x718000,0x4000)));m.mem_map(base+s.VirtualAddress,(s.Misc_VirtualSize+4095)&-4096);m.mem_write(base+s.VirtualAddress,bytes(s.get_data()))
     h=0x10000000;m.mem_map(h,0x20000);frame=h+0x1000;cp=h+0x3000;obj=h+0xa000;sp=h+0x18000
     m.mem_write(frame+2,bytes([host]));m.mem_write(cp+0x17f8,struct.pack('<Q',0 if submission is None else obj));m.mem_write(cp+0x5b41,bytes([pending]));m.mem_write(cp+0x5b50,struct.pack('<Q',77));m.mem_write(obj+8,struct.pack('<Q',submission or 0))
     values={k:0x5555000000000000+i for i,k in enumerate(['RAX','RCX','RDX','RBX','RSI','RDI','R8','R9','R10','R11','R12','R13'])};values.update({'RSP':sp,'RBP':frame,'R14':producer,'R15':cp})
     for k,v in values.items():m.reg_write(getattr(R,'UC_X86_REG_'+k),v)
     dest=0x71a7aa if producer else 0x718b23
     def stop(uc,address,size,data):
      if address==base+dest:uc.emu_stop()
     m.hook_add(UC_HOOK_CODE,stop);m.emu_start(base+0x71a7a1,base+dest,count=100);assert m.reg_read(R.UC_X86_REG_RIP)==base+dest
     for k,v in values.items():assert m.reg_read(getattr(R,'UC_X86_REG_'+k))==v,k
     active=host and submission is not None
     assert bytes(m.mem_read(cp+0x5b41,1))==bytes([1 if active else pending]);assert struct.unpack('<Q',m.mem_read(cp+0x5b50,8))[0]==(submission if active else 77)
     assert bool(m.reg_read(R.UC_X86_REG_EFLAGS)&64)==(not producer)
     m.mem_map(base+0x726000,4096);m.mem_write(base+0x726000,bytes(p.get_data(0x726000,4096)))
     m.mem_map(base+0x71e000,4096)
     waited=[]
     def fence_hook(uc,address,size,data):
      if address in [base+0x71e2e0,base+0x71b710]:
       if address==base+0x71e2e0:waited.append((uc.reg_read(R.UC_X86_REG_RCX),uc.reg_read(R.UC_X86_REG_RDX)))
       rsp=uc.reg_read(R.UC_X86_REG_RSP);ret=struct.unpack('<Q',uc.mem_read(rsp,8))[0];uc.reg_write(R.UC_X86_REG_RSP,rsp+8);uc.reg_write(R.UC_X86_REG_RIP,ret)
      elif address==base+0x726c78:uc.emu_stop()
     m.hook_add(UC_HOOK_CODE,fence_hook);m.reg_write(R.UC_X86_REG_RSI,cp);m.emu_start(base+0x726c51,base+0x726c78,count=50)
     assert waited==([(cp,submission if active else 77)] if active or pending else [])
     assert bytes(m.mem_read(cp+0x5b41,1))==b'\0'
     assert m.reg_read(R.UC_X86_REG_RSP)==sp
     count+=1
print('PASS',count,'actual x64 executions: host reads/writes, device exclusion, existing waits, null submission, 64-bit IDs, ASLR, all GPRs, stack and original branch flags')
print('PASS unchanged original sections except one hook; exact chained unwind, PE checksum and sorted exception table')
