from pathlib import Path
import subprocess

ROOT = Path(__file__).parent
LLVM = Path('/opt/homebrew/opt/llvm@16/bin')
BUILD = ROOT / 'build'
BUILD.mkdir(exist_ok=True)
flags = ['-target', 'powerpc-unknown-linux-gnu', '-ffreestanding', '-fno-builtin',
         '-fno-pic', '-fno-pie', '-fno-stack-protector', '-fno-unwind-tables',
         '-fno-asynchronous-unwind-tables', '-mno-altivec', '-mno-vsx', '-O2',
         '-DCBC=1', '-DECB=0', '-DCTR=0', '-I', str(ROOT / 'vendor')]
for name, source in [('hooks', ROOT / 'hooks.c'), ('aes', ROOT / 'vendor/aes.c')]:
    subprocess.run([str(LLVM / 'clang'), *flags, '-c', str(source), '-o', str(BUILD / (name + '.o'))], check=True)
subprocess.run([str(LLVM / 'ld.lld'), '-m', 'elf32ppc', '-T', str(ROOT / 'link.ld'),
                str(BUILD / 'hooks.o'), str(BUILD / 'aes.o'), '-o', str(BUILD / 'payload.elf')], check=True)
subprocess.run([str(LLVM / 'llvm-objcopy'), '-O', 'binary', str(BUILD / 'payload.elf'), str(BUILD / 'payload.bin')], check=True)
symbols = subprocess.check_output([str(LLVM / 'llvm-nm'), '-n', str(BUILD / 'payload.elf')], text=True)
(BUILD / 'symbols.txt').write_text(symbols)
print(symbols)
