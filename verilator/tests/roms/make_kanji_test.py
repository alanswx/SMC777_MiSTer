#!/usr/bin/env python3
"""Build kanji_test.rom: a 16 KiB IPL replacement that reads the kanji ROM through port 7Eh.

It programs the HD46505 as the real IPL does (so the sim has frames), waits ~0.4 s, then for each JIS code in CODES
writes 7Eh/7Fh and reads the 32 pattern bytes with IN A,(C), B = 0..31. Run it as the IPL in the sim and in CSP
(--rom-dir with it as SMCROM.DAT plus KANJIROM.DAT) and compare the --trace-io reads of 7Eh.
"""
import sys

CRTC = [0x7f, 0x50, 0x60, 0x3a, 0x1f, 0x06, 0x19, 0x1c, 0xa0, 0x07, 0x60, 0x0f, 0, 0, 0, 0]
CODES = [(0x21, 0x21), (0x30, 0x21), (0x4f, 0x7e), (0x21, 0x20), (0x3c, 0x5a), (0x50, 0x21), (0x20, 0x30)]

code = bytearray()
def emit(*b): code.extend(b)
emit(0xf3, 0x31, 0x00, 0x00)                      # di; ld sp,0
for r in range(15, -1, -1):
    emit(0x3e, r, 0xd3, 0x18, 0x3e, CRTC[r], 0xd3, 0x19)   # ld a,r; out (18h),a; ld a,v; out (19h),a
emit(0x11, 0x00, 0x00)                            # ld de,0
wait = len(code)
emit(0x1b, 0x7a, 0xb3)                       # dec de; ld a,d; or e
emit(0x20, (wait - (len(code) + 2)) & 0xff)       # jr nz,wait
table_ld = len(code); emit(0x21, 0, 0)            # ld hl,table (patched)
loop = len(code)
emit(0x7e, 0xb7)                                  # ld a,(hl); or a
jz = len(code); emit(0x28, 0)                     # jr z,done (patched)
emit(0xd3, 0x7e, 0x23, 0x7e, 0xd3, 0x7f, 0x23)    # out (7eh),a; inc hl; ld a,(hl); out (7fh),a; inc hl
emit(0x06, 0x00, 0x0e, 0x7e)                      # ld b,0; ld c,7eh
inner = len(code)
emit(0xed, 0x78, 0x04, 0x78, 0xfe, 0x20)          # in a,(c); inc b; ld a,b; cp 32
emit(0x20, (inner - (len(code) + 2)) & 0xff)      # jr nz,inner
emit(0x18, (loop - (len(code) + 2)) & 0xff)       # jr loop
done = len(code)
emit(0x18, 0xfe)                                  # jr $
code[jz + 1] = (done - (jz + 2)) & 0xff
table = len(code)
code[table_ld + 1], code[table_ld + 2] = table & 0xff, table >> 8
for hi, lo in CODES: emit(hi, lo)
emit(0)
open(sys.argv[1], 'wb').write(bytes(code) + b'\xff' * (0x4000 - len(code)))
