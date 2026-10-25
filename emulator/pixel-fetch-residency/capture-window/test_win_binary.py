import struct,pefile
from unicorn import Uc,UC_ARCH_X86,UC_MODE_64,UC_HOOK_CODE
from unicorn.x86_const import *
import sys
from pathlib import Path
p=pefile.PE(sys.argv[1] if len(sys.argv)>1 else str(Path(__file__).parent/'build/RiseCaptureWindow.dll'))
entry=next(e.address for e in p.DIRECTORY_ENTRY_EXPORT.symbols if e.name==b'CaptureWindow')
assert not hasattr(p,'DIRECTORY_ENTRY_IMPORT') and p.DIRECTORY_ENTRY_EXCEPTION
count=0
for slide in (0x10000000,0x180000000):
 for setup,api_ok,end_ok,pre_active,expected in [(0,1,1,0,5),(7500000,1,1,0,5),(10000001,1,1,0,8),(0,0,1,0,2),(0,1,0,0,6),(0,1,1,1,7)]:
  u=Uc(UC_ARCH_X86,UC_MODE_64)
  for a,n in [(slide,0x10000),(0x500000,0x1000),(0x600000,0x1000),(0x800000,0x2000),(0x900000,0x10000),(0xa00000,0x1000)]:u.mem_map(a,n)
  u.mem_write(slide,bytes(p.get_memory_mapped_image()))
  functions=[0x500000+i*0x100 for i in range(9)]
  for a in functions:u.mem_write(a,b'\xc3')
  table=bytearray(27*8)
  for i,fn in [(13,6),(14,7),(19,3),(20,4),(21,5),(24,8)]:struct.pack_into('<Q',table,i*8,functions[fn])
  u.mem_write(0x600000,bytes(table));context=bytearray(4184)
  for off,val in [(0,functions[0]),(8,functions[1]),(32,functions[2]),(56,10000000)]:struct.pack_into('<Q',context,off,val)
  u.mem_write(0x800000,bytes(context));rsp=0x90fff8;u.mem_write(rsp,struct.pack('<Q',0xa00000));u.reg_write(UC_X86_REG_RSP,rsp);u.reg_write(UC_X86_REG_RCX,0x800000)
  preserved=[UC_X86_REG_RBX,UC_X86_REG_RBP,UC_X86_REG_RDI,UC_X86_REG_RSI,UC_X86_REG_R12,UC_X86_REG_R13,UC_X86_REG_R14,UC_X86_REG_R15]
  for i,reg in enumerate(preserved):u.reg_write(reg,0x1110+i)
  state={'ticks':0,'active':pre_active,'captures':0,'saves':0,'discard':0}
  def hook(uc,address,size,user):
   if address not in functions:return
   fn=functions.index(address);rcx=uc.reg_read(UC_X86_REG_RCX);rdx=uc.reg_read(UC_X86_REG_RDX)
   assert (uc.reg_read(UC_X86_REG_RSP)&15)==8,'Windows call alignment'
   if fn==0:
    assert rcx==10400;uc.mem_write(rdx,struct.pack('<Q',0x600000));uc.reg_write(UC_X86_REG_RAX,api_ok)
   elif fn==1:
    assert state['active'] and not state['saves'];state['ticks']+=rcx*10000
   elif fn==2:uc.mem_write(rcx,struct.pack('<Q',state['ticks']));uc.reg_write(UC_X86_REG_RAX,1)
   elif fn==3:assert rcx==rdx==0;state['ticks']+=setup;state['active']=1
   elif fn==4:uc.reg_write(UC_X86_REG_RAX,state['active'])
   elif fn==5:
    assert struct.unpack('<I',uc.mem_read(0x800010,4))[0]==4
    state['saves']+=1;state['ticks']+=50000000;state['active']=0;state['captures']+=end_ok;uc.reg_write(UC_X86_REG_RAX,end_ok)
   elif fn==6:uc.reg_write(UC_X86_REG_RAX,state['captures'])
   elif fn==7:
    assert rcx==0;uc.mem_write(rdx,b'D:\\capture.rdc\0');uc.mem_write(uc.reg_read(UC_X86_REG_R8),struct.pack('<I',15))
    assert uc.reg_read(UC_X86_REG_R9)==0;uc.reg_write(UC_X86_REG_RAX,1)
   elif fn==8:state['discard']+=1;state['active']=0;uc.reg_write(UC_X86_REG_RAX,1)
  u.hook_add(UC_HOOK_CODE,hook);u.emu_start(slide+entry,0xa00000,count=2000)
  assert u.reg_read(UC_X86_REG_RAX)==expected
  assert struct.unpack('<I',u.mem_read(0x800010,4))[0]==expected
  for i,reg in enumerate(preserved):assert u.reg_read(reg)==0x1110+i
  assert u.reg_read(UC_X86_REG_RSP)==rsp+8
  if expected==5:
   b=bytes(u.mem_read(0x800000,4184));assert struct.unpack_from('<Q',b,48)[0]-struct.unpack_from('<Q',b,40)[0]==10000000
   assert state['saves']==1
  count+=1
print('PASS:',count,'real Windows-x64 DLL cases; API argument layout; ASLR; ABI; one-second window; single save; abort paths.')
