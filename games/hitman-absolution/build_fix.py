"""Build version-pinned Hitman depth corrections for Xenia Edge.

Requires owner-supplied Edge; shader-specific mode also needs validated shaders.
Private executable and shader inputs are not distributed.
The patch runs only at D3D12 pipeline creation, never on individual draws.
"""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile

import pefile

EDGE_SHA256 = '41313fdc1c22b08a19a3bd2334332de2ba597e1f7fb27010a757e2ac573662a5'
FIX_SHADER_SHA256 = 'e3a8b1e39b94555d40c0f5e89916328f1300bdde435bb75d2724d3d594dc8468'
FIX_SHADER_LENGTH = 40784
SEA_FIX_SHADER_SHA256 = 'fc172646b6504ff94b1edecf801184b386f0b0dc50bb4898e24fad5e591fb0dc'
SEA_FIX_SHADER_LENGTH = 34268
SEA_ORIGINAL_SHADER_LENGTH = 32152
SEA_ORIGINAL_SHADER_DIGEST = bytes.fromhex('4f16d76e2ccbec2118771808f68848fa')
ORIGINAL_SHADER_LENGTH = 38528
ORIGINAL_SHADER_DIGEST = bytes.fromhex('eb84674a448f6988bec569e2656a2750')
HOOK_RVA = 0x74DC74
RESUME_RVA = 0x74DC7E
HOOK_BYTES = bytes.fromhex('ff5050898424d0030000')
SHADER_OFFSET = 0x200
SEA_SHADER_OFFSET = (SHADER_OFFSET + FIX_SHADER_LENGTH + 15) & -16


def align(value, alignment):
    return (value + alignment - 1) & -alignment


def assembly(rva, shader, sea_shader, render_pass_bias=False):
    paths = [] if render_pass_bias else [path.resolve().as_posix() for path in (shader, sea_shader)]
    if any('"' in path or '\n' in path for path in paths):
        raise ValueError('Unsupported assembler input path')
    def comparisons(digest):
        words = struct.unpack('<4I', digest)
        return '\n'.join(
            f'    cmp dword [r10 + {4 + index * 4}], 0x{word:08x}\n    jne original_call'
            for index, word in enumerate(words)
        )
    if render_pass_bias:
        # The match is a pipeline-state class, never a shader fingerprint.
        # D3D12's bias is measured at the primitive's maximum depth, not each
        # pixel; bound its absolute effect to 2**-16 in normalized depth.
        return f'''bits 64
org {rva}
    cmp dword [rdx + 0x1f0], 1
    jne original_call
    cmp dword [rdx + 0x1f4], 1
    jne original_call
    cmp dword [rdx + 0x1f8], 7
    jne original_call
    cmp dword [rdx + 0x240], 1
    jne original_call
    cmp dword [rdx + 0x244], 10
    jne original_call
    cmp dword [rdx + 0x264], 20
    jne original_call
    cmp dword [rdx + 0x23c], 3
    jne original_call
    cmp dword [rdx + 0x268], 1
    jne original_call
    cmp dword [rdx + 0x1d0], 0
    jne original_call
    cmp dword [rdx + 0x1d4], 0
    jne original_call
    cmp dword [rdx + 0x1d8], 0
    jne original_call
    cmp qword [rdx + 0x18], 0
    je original_call
    cmp qword [rdx + 0x20], 0
    je original_call
    mov dword [rdx + 0x1d0], 512
    mov dword [rdx + 0x1d4], 0x37800000
original_call:
    call qword [rax + 0x50]
    mov dword [rsp + 0x3d0], eax
    jmp {RESUME_RVA}
    times {SHADER_OFFSET} - ($ - $$) db 0
'''
    return f'''bits 64
org {rva}
; Continuation of CreateD3D12Pipeline; no new stack frame or per-draw hook.
; RCX=device, RDX=local PSO description, R8=IID, R9=out, RAX=vtable.
; Only R10 (volatile) is used. Both matches require exact lengths/digests.
    cmp dword [rdx + 0x1f0], 1
    jne original_call
    cmp dword [rdx + 0x1f8], 7
    jne original_call
    mov r10, [rdx + 0x18]
    test r10, r10
    jz original_call
    cmp qword [rdx + 0x20], {ORIGINAL_SHADER_LENGTH}
    je check_puddle
    cmp qword [rdx + 0x20], {SEA_ORIGINAL_SHADER_LENGTH}
    je check_sea
    jmp original_call
check_puddle:
    cmp dword [r10], 0x43425844
    jne original_call
{comparisons(ORIGINAL_SHADER_DIGEST)}
    lea r10, [rel replacement_shader]
    mov [rdx + 0x18], r10
    mov qword [rdx + 0x20], {FIX_SHADER_LENGTH}
    jmp original_call
check_sea:
    cmp dword [r10], 0x43425844
    jne original_call
{comparisons(SEA_ORIGINAL_SHADER_DIGEST)}
    lea r10, [rel replacement_sea_shader]
    mov [rdx + 0x18], r10
    mov qword [rdx + 0x20], {SEA_FIX_SHADER_LENGTH}
original_call:
    call qword [rax + 0x50]
    mov dword [rsp + 0x3d0], eax
    jmp {RESUME_RVA}
    times {SHADER_OFFSET} - ($ - $$) db 0
replacement_shader:
    incbin "{paths[0]}"
    times {SEA_SHADER_OFFSET} - ($ - $$) db 0
replacement_sea_shader:
    incbin "{paths[1]}"
'''


def build(executable, shader=None, sea_shader=None, nasm='nasm', render_pass_bias=False):
    original = executable.read_bytes()
    if hashlib.sha256(original).hexdigest() != EDGE_SHA256:
        raise ValueError('Edge executable does not match the verified build; refusing to patch')
    if not render_pass_bias:
        replacement = shader.read_bytes()
        if hashlib.sha256(replacement).hexdigest() != FIX_SHADER_SHA256:
            raise ValueError('Shader does not match the validated original-shading +512 ULP variant')
        sea_replacement = sea_shader.read_bytes()
        if len(replacement) != FIX_SHADER_LENGTH or len(sea_replacement) != SEA_FIX_SHADER_LENGTH:
            raise ValueError('Unexpected validated shader length')
        if hashlib.sha256(sea_replacement).hexdigest() != SEA_FIX_SHADER_SHA256:
            raise ValueError('Sea shader does not match the replay-validated +512 ULP variant')
    pe = pefile.PE(data=original)
    if pe.get_overlay_data_start_offset() is not None:
        raise ValueError('Unexpected executable overlay')
    if pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].Size:
        raise ValueError('Refusing to invalidate an Authenticode signature')
    hook_offset = pe.get_offset_from_rva(HOOK_RVA)
    if original[hook_offset:hook_offset + len(HOOK_BYTES)] != HOOK_BYTES:
        raise ValueError('Pipeline call site changed')
    parent = next(entry.struct for entry in pe.DIRECTORY_ENTRY_EXCEPTION
                  if entry.struct.BeginAddress <= HOOK_RVA < entry.struct.EndAddress)
    if (parent.BeginAddress, parent.EndAddress, parent.UnwindData) != (0x74D220, 0x74E08C, 0x214E68C):
        raise ValueError('Unexpected parent unwind metadata')
    # A chained entry inherits the parent stack allocation and termination
    # handler. The trampoline never adjusts RSP or any nonvolatile register.
    # See Microsoft's x64 chained-unwind documentation.
    parent_header = pe.get_data(parent.UnwindData, 4)
    if parent_header[0] != 0x11 or parent_header[3] != 0:
        raise ValueError('Unexpected parent unwind format')
    last = pe.sections[-1]
    rva = align(last.VirtualAddress + max(last.Misc_VirtualSize, last.SizeOfRawData),
                pe.OPTIONAL_HEADER.SectionAlignment)
    with tempfile.TemporaryDirectory(prefix='hitman-water-build-') as temporary:
        temporary = Path(temporary)
        asm_path = temporary / 'trampoline.asm'
        asm_path.write_text(assembly(rva, shader, sea_shader, render_pass_bias), encoding='utf-8')
        bin_path = temporary / 'trampoline.bin'
        subprocess.run([nasm, '-f', 'bin', str(asm_path), '-o', str(bin_path)], check=True)
        payload = bytearray(bin_path.read_bytes())
    if render_pass_bias:
        if len(payload) != SHADER_OFFSET:
            raise ValueError('Unexpected render-pass continuation size')
    else:
        if (payload[SHADER_OFFSET:SHADER_OFFSET + FIX_SHADER_LENGTH] != replacement
                or payload[SEA_SHADER_OFFSET:] != sea_replacement
                or any(payload[SHADER_OFFSET + FIX_SHADER_LENGTH:SEA_SHADER_OFFSET])):
            raise ValueError('Assembler changed the shader payload')
    unwind_offset = align(len(payload), 4)
    payload.extend(b'\0' * (unwind_offset - len(payload)))
    payload.extend(bytes([0x21, 0, 0, parent_header[3]]))  # UNW_FLAG_CHAININFO, no new prologue
    payload.extend(struct.pack('<III', parent.BeginAddress, parent.EndAddress, parent.UnwindData))
    exception_directory = pe.OPTIONAL_HEADER.DATA_DIRECTORY[3]
    old_table = pe.get_data(exception_directory.VirtualAddress, exception_directory.Size)
    if len(old_table) % 12 or len(old_table) != exception_directory.Size:
        raise ValueError('Malformed exception directory')
    table_offset = align(len(payload), 4)
    payload.extend(b'\0' * (table_offset - len(payload)))
    payload.extend(old_table)
    payload.extend(struct.pack('<III', rva, rva + SHADER_OFFSET, rva + unwind_offset))
    virtual_size = len(payload)
    raw_size = align(virtual_size, pe.OPTIONAL_HEADER.FileAlignment)
    payload.extend(b'\0' * (raw_size - len(payload)))
    raw_offset = align(len(original), pe.OPTIONAL_HEADER.FileAlignment)
    section_header = last.get_file_offset() + 40
    if section_header + 40 > min(section.PointerToRawData for section in pe.sections):
        raise ValueError('No room for one additional PE section header')
    result = bytearray(original)
    result.extend(b'\0' * (raw_offset - len(result)))
    result.extend(payload)
    struct.pack_into('<8sIIIIIIHHI', result, section_header,
                     b'.hdepth\0' if render_pass_bias else b'.hwater\0', virtual_size, rva, raw_size, raw_offset, 0, 0, 0, 0,
                     0x60000020)  # readable executable code/data; never writable
    struct.pack_into('<H', result, pe.FILE_HEADER.get_field_absolute_offset('NumberOfSections'),
                     pe.FILE_HEADER.NumberOfSections + 1)
    for name, value in (
        ('SizeOfImage', align(rva + virtual_size, pe.OPTIONAL_HEADER.SectionAlignment)),
        ('SizeOfCode', pe.OPTIONAL_HEADER.SizeOfCode + raw_size),
        ('CheckSum', 0),
    ):
        struct.pack_into('<I', result, pe.OPTIONAL_HEADER.get_field_absolute_offset(name), value)
    struct.pack_into('<I', result, exception_directory.get_field_absolute_offset('VirtualAddress'),
                     rva + table_offset)
    struct.pack_into('<I', result, exception_directory.get_field_absolute_offset('Size'), len(old_table) + 12)
    # Replace whole original instructions with a relative jump and five NOPs.
    # The trampoline executes the original call and HRESULT store itself.
    result[hook_offset:hook_offset + len(HOOK_BYTES)] = (
        b'\xe9' + struct.pack('<i', rva - (HOOK_RVA + 5)) + b'\x90' * 5
    )
    checksum = pefile.PE(data=bytes(result)).generate_checksum()
    struct.pack_into('<I', result, pe.OPTIONAL_HEADER.get_field_absolute_offset('CheckSum'), checksum)
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--shader', type=Path)
    parser.add_argument('--sea-shader', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--nasm', default='nasm')
    parser.add_argument('--render-pass-bias', action='store_true',
                        help='Experimental pipeline-state depth bias; replaces shader-specific dispatch')
    args = parser.parse_args()
    if not args.render_pass_bias and (args.shader is None or args.sea_shader is None):
        parser.error('Shader-specific mode requires both shader inputs')
    inputs = [p.resolve() for p in (args.exe, args.shader, args.sea_shader) if p is not None]
    if args.output.resolve() in inputs or args.output.exists():
        parser.error('Choose a new output file; inputs and existing files are never overwritten')
    result = build(args.exe, args.shader, args.sea_shader, args.nasm, args.render_pass_bias)
    args.output.write_bytes(result)
    print('Built:', args.output)
    print('SHA256:', hashlib.sha256(result).hexdigest())


if __name__ == '__main__':
    main()
