"""Version-pinned D3D12 vfetch-residency correction for the supplied Edge build.

The continuation unions the analyzed VS and PS fetch bitmaps before the existing
validation/residency loop. It doesn't replace shaders or modify game data.
"""
import argparse, hashlib, struct, subprocess, tempfile
from pathlib import Path
import pefile

EDGE_SHA256='41313fdc1c22b08a19a3bd2334332de2ba597e1f7fb27010a757e2ac573662a5'
HOOK_RVA=0x719F83
RESUME_RVA=0x719F8B
HOOK_BYTES=bytes.fromhex('448b8487cc000000')
PARENT=(0x718A80,0x71B70C,0x214C428)
CODE_SIZE=0x80

def align(value,alignment):return (value+alignment-1)&-alignment

def assembly(rva):
 return f'''bits 64
org {rva}
; RDI = analyzed vertex shader, [RBP+18h] = active pixel shader or null.
; EAX and R10D both contain the current bitmap word index (0..2).
; Restore RAX to its exact entry value. No stack/call/other register changes.
    mov r8d, [rdi + rax*4 + 0xcc]
    mov rax, [rbp + 0x18]
    test rax, rax
    jz done
    or r8d, [rax + r10*4 + 0xcc]
done:
    mov eax, r10d
    jmp {RESUME_RVA}
    times {CODE_SIZE} - ($ - $$) db 0
'''

def build(exe,nasm='nasm'):
 original=Path(exe).read_bytes()
 if hashlib.sha256(original).hexdigest()!=EDGE_SHA256:raise ValueError('Unsupported Edge build')
 pe=pefile.PE(data=original)
 if pe.get_overlay_data_start_offset() is not None or pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].Size:raise ValueError('Unsupported PE overlay or Authenticode signature')
 if pe.get_data(HOOK_RVA,len(HOOK_BYTES))!=HOOK_BYTES:raise ValueError('Fetch loop changed')
 parent=next(e.struct for e in pe.DIRECTORY_ENTRY_EXCEPTION if e.struct.BeginAddress<=HOOK_RVA<e.struct.EndAddress)
 if (parent.BeginAddress,parent.EndAddress,parent.UnwindData)!=PARENT:raise ValueError('Unexpected parent unwind entry')
 if pe.get_data(parent.UnwindData,4)!=bytes.fromhex('11300d00'):raise ValueError('Unexpected parent unwind format')
 last=pe.sections[-1];rva=align(last.VirtualAddress+max(last.Misc_VirtualSize,last.SizeOfRawData),pe.OPTIONAL_HEADER.SectionAlignment)
 with tempfile.TemporaryDirectory(prefix='edge-pfetch-') as temp:
  temp=Path(temp);(temp/'code.asm').write_text(assembly(rva));subprocess.run([nasm,'-f','bin',str(temp/'code.asm'),'-o',str(temp/'code.bin')],check=True);payload=bytearray((temp/'code.bin').read_bytes())
 if len(payload)!=CODE_SIZE:raise ValueError('Unexpected continuation size')
 unwind_offset=len(payload);payload.extend(bytes.fromhex('21000000'));payload.extend(struct.pack('<III',*PARENT))
 table_offset=align(len(payload),4);payload.extend(b'\0'*(table_offset-len(payload)))
 exception=pe.OPTIONAL_HEADER.DATA_DIRECTORY[3];old_table=pe.get_data(exception.VirtualAddress,exception.Size)
 if len(old_table)!=exception.Size or exception.Size%12:raise ValueError('Malformed exception table')
 payload.extend(old_table);payload.extend(struct.pack('<III',rva,rva+CODE_SIZE,rva+unwind_offset))
 virtual_size=len(payload);raw_size=align(virtual_size,pe.OPTIONAL_HEADER.FileAlignment);payload.extend(b'\0'*(raw_size-len(payload)))
 raw_offset=align(len(original),pe.OPTIONAL_HEADER.FileAlignment);header=last.get_file_offset()+40
 if header+40>min(s.PointerToRawData for s in pe.sections):raise ValueError('No spare section header')
 result=bytearray(original);result.extend(b'\0'*(raw_offset-len(result)));result.extend(payload)
 struct.pack_into('<8sIIIIIIHHI',result,header,b'.pfetch\0',virtual_size,rva,raw_size,raw_offset,0,0,0,0,0x60000020)
 struct.pack_into('<H',result,pe.FILE_HEADER.get_field_absolute_offset('NumberOfSections'),pe.FILE_HEADER.NumberOfSections+1)
 for name,value in [('SizeOfImage',align(rva+virtual_size,pe.OPTIONAL_HEADER.SectionAlignment)),('SizeOfCode',pe.OPTIONAL_HEADER.SizeOfCode+raw_size),('CheckSum',0)]:struct.pack_into('<I',result,pe.OPTIONAL_HEADER.get_field_absolute_offset(name),value)
 struct.pack_into('<I',result,exception.get_field_absolute_offset('VirtualAddress'),rva+table_offset);struct.pack_into('<I',result,exception.get_field_absolute_offset('Size'),len(old_table)+12)
 offset=pe.get_offset_from_rva(HOOK_RVA);result[offset:offset+len(HOOK_BYTES)]=b'\xE9'+struct.pack('<i',rva-HOOK_RVA-5)+b'\x90'*3
 fixed=pefile.PE(data=bytes(result));struct.pack_into('<I',result,pe.OPTIONAL_HEADER.get_field_absolute_offset('CheckSum'),fixed.generate_checksum())
 return bytes(result)

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();data=build(a.exe);a.out.write_bytes(data);print('SHA256',hashlib.sha256(data).hexdigest())
