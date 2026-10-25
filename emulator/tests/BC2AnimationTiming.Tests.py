"""Execute BC2's original/patched PPC duration guard and check frame-size cases.

The guard instructions are read from the supplied extracted memory image;
only the two generated patch words differ. No game image is distributed.
"""
from pathlib import Path
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from bc2_animation_timing import SITES, build

BASE = 0x82A00000
START = 0x82E36A04
VALID = 0x82E36A38
INVALID = 0x82E36AA4

def evaluate(image, patched, duration, empty=False):
    regs = [0]*32
    regs[30] = int(empty)
    floats = [0.0]*32
    floats[0] = duration
    cr = [False]*32
    pc = START
    for _ in range(32):
        if pc in (VALID, INVALID):
            return pc == VALID
        w = struct.unpack_from('>I', image, pc-BASE)[0]
        if patched and pc in SITES:
            assert w == SITES[pc][0]
            w = SITES[pc][1]
        opcode, rt, ra, rb = w>>26, (w>>21)&31, (w>>16)&31, (w>>11)&31
        imm = w&65535
        signed = imm - 65536 if imm&32768 else imm
        next_pc = pc + 4
        if opcode == 21:
            assert ((w>>11)&31, (w>>6)&31, (w>>1)&31) == (0,24,31)
            regs[ra] = regs[rt]&255
        elif opcode == 10:
            bf = (w>>23)&7
            a, b = regs[ra]&0xffffffff, imm
            cr[4*bf:4*bf+4] = [a<b, a>b, a==b, False]
        elif opcode == 15:
            assert ra == 0
            regs[rt] = (signed<<16)&0xffffffff
        elif opcode == 48:
            addr = (regs[ra]+signed)&0xffffffff
            floats[rt] = struct.unpack_from('>f', image, addr-BASE)[0]
        elif opcode == 14:
            assert ra == 0
            regs[rt] = signed
        elif opcode == 63:
            assert (w>>1)&1023 == 0  # fcmpu
            bf = (w>>23)&7
            a, b = floats[ra], floats[rb]
            cr[4*bf:4*bf+4] = [a<b, a>b, a==b, False]
        elif opcode == 16:
            bo, bi = (w>>21)&31, (w>>16)&31
            assert bo in (4,12)
            if cr[bi] == (bo == 12):
                disp=w&0xfffc
                next_pc=pc+(disp-65536 if disp&32768 else disp)
        elif opcode == 31:
            assert (w>>1)&1023 == 444 and rt == rb  # mr/or
            regs[ra] = regs[rt]
        else:
            raise AssertionError((hex(pc),hex(w)))
        pc=next_pc
    raise AssertionError('Guard did not reach either original successor')

def main(image):
    checks=0
    for hz in (15,24,25,30,40,50,59.94,60,90,120,144,240):
        t=struct.unpack('>f',struct.pack('>f',1/hz))[0]
        assert evaluate(image,False,t) == (t>=struct.unpack('>f',bytes.fromhex('3ca3d70a'))[0])
        assert evaluate(image,True,t)
        assert not evaluate(image,False,t,True)
        assert not evaluate(image,True,t,True)
        checks+=4
    epsilon=struct.unpack('>f',bytes.fromhex('358637bd'))[0]
    for t in (-1,0,epsilon/2):
        assert not evaluate(image,False,t)
        assert not evaluate(image,True,t)
        checks+=2
    assert evaluate(image,True,epsilon)
    for index in range(2001):
        t=index/10000
        if evaluate(image,False,t):
            assert evaluate(image,True,t)
        checks+=1
    # A linear 1.7456934 m, 0.76666665 s transition must retain its
    # constituent movement at 60 Hz, with unchanged duration and travel.
    distance, duration=1.7456934,0.76666665
    for hz in (30,60,120):
        chunks=[1/hz]*int(duration*hz)
        chunks+=[duration-sum(chunks)]
        old=sum(t*distance/duration for t in chunks if evaluate(image,False,t))
        new=sum(t*distance/duration for t in chunks if evaluate(image,True,t))
        assert abs(new-distance)<1e-9
        if hz>=60:assert old==0
        print(f'{hz} Hz: old guard retains {old:.6f} m, corrected guard {new:.6f} m')
        checks+=2
    print(checks+1,'checks passed: actual PPC branch paths, valid/empty/zero/tiny time, preserved original accepted domain.')

def fixture():
    # The original guard's 13 instructions and its two read-only constants.
    # Full game executables and live memory captures are deliberately excluded.
    image=bytearray(VALID-BASE)
    words=(0x57CB063E,0x2B0B0000,0x409A0018,0x3D6082A1,0xC1AB7884,
           0x39600000,0xFF006800,0x40980008,0x39600001,0x556B063E,
           0x7D6A5B78,0x2B0B0000,0x409A0070)
    struct.pack_into('>13I',image,START-BASE,*words)
    struct.pack_into('>I',image,0x82A17884-BASE,0x3CA3D70A)
    struct.pack_into('>I',image,0x82A00D58-BASE,0x358637BD)
    return image

if __name__=='__main__':
    image=Path(sys.argv[1]).read_bytes() if len(sys.argv)>1 else fixture()
    patch=build(image)
    assert patch.count('[[patch.be32]]')==2
    assert 'hash = "C1F8A2BE5BCF6B96"' in patch
    broken=bytearray(image)
    struct.pack_into('>I',broken,0x82E36A10-BASE,0x60000000)
    try:build(broken)
    except ValueError:pass
    else:raise AssertionError('Generator accepted a mismatched executable')
    main(image)
