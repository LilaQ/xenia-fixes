import argparse,hashlib,subprocess,re
from pathlib import Path
import pefile
p=argparse.ArgumentParser();p.add_argument('--clang',default='clang');p.add_argument('--linker',default='lld-link');args=p.parse_args()
root=Path(__file__).resolve().parent;out=root/'build';out.mkdir(exist_ok=True)
subprocess.run([args.clang,'--target=x86_64-pc-windows-msvc','-O2','-ffreestanding','-funwind-tables','-fno-stack-protector','-c',str(root/'capture.c'),'-o',str(out/'capture.obj')],check=True)
subprocess.run([args.linker,'/dll','/entry:DllMain','/nodefaultlib','/Brepro','/out:'+str(out/'RiseCaptureWindow.dll'),str(out/'capture.obj')],check=True)
b=(out/'RiseCaptureWindow.dll').read_bytes();pe=pefile.PE(data=b)
assert pe.FILE_HEADER.Machine==0x8664 and not hasattr(pe,'DIRECTORY_ENTRY_IMPORT')
assert pe.DIRECTORY_ENTRY_EXCEPTION
entry=next(e.address for e in pe.DIRECTORY_ENTRY_EXPORT.symbols if e.name==b'CaptureWindow')
sha=hashlib.sha256(b).hexdigest().upper()
s=(root/'Rise-Capture-Window.ps1').read_text()
s=re.sub(r"(Get-FileHash -LiteralPath \$dll -Algorithm SHA256\).Hash -ne ')[A-F0-9]{64}",r'\g<1>'+sha,s)
s=re.sub(r'0x1F84D0,0x[0-9A-Fa-f]+,\$progress','0x1F84D0,0x'+format(entry,'X')+',$progress',s)
(out/'Rise-Capture-Window.ps1').write_text(s)
(out/'CaptureWindow.cs').write_text((root/'CaptureWindow.cs').read_text())
print('CaptureWindow RVA',hex(entry),'SHA256',sha)
