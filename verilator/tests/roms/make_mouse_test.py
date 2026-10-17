#!/usr/bin/env python3
"""Build mouse_test.rom: an IPL replacement that programs the HD46505 and then, about every 13 ms, reads the mouse on
joystick port 2 as SMC Paint 2.3's driver does (AC9Eh): OUT 51h,05h / wait / IN (B = 0) high nibble, OUT 51h,15h /
wait / IN low nibble, for X then Y, then the buttons (IN 51h, B = 0). Run with --mouse-move and check the reads
(run_tests.sh mouse): every 5 reads of port 0051h are X high, X low, Y high, Y low, buttons."""
import sys
CRTC = [0x7f, 0x50, 0x60, 0x3a, 0x1f, 0x06, 0x19, 0x1c, 0xa0, 0x07, 0x60, 0x0f, 0, 0, 0, 0]
code = bytearray()
def emit(*b): code.extend(b)
def djnz_self(): emit(0x10, 0xfe)                 # djnz $
emit(0xf3, 0x31, 0x00, 0x00)
for r in range(15, -1, -1):
    emit(0x3e, r, 0xd3, 0x18, 0x3e, CRTC[r], 0xd3, 0x19)
loop = len(code)
emit(0x0e, 0x51)                                  # ld c,51h
for d in (0x18, 0x09):                            # X (longer first wait, as SMC Paint), then Y
    emit(0x3e, 0x05, 0xed, 0x79)                  # ld a,05h; out (c),a   strobe low
    emit(0x06, d); djnz_self()                    # ld b,d; djnz $        (B = 0 for the IN)
    emit(0xed, 0x78)                              # in a,(c)
    emit(0x3e, 0x15, 0xed, 0x79)                  # ld a,15h; out (c),a   strobe high
    emit(0x06, 0x09); djnz_self()
    emit(0xed, 0x78)
emit(0x01, 0x51, 0x00, 0xed, 0x78)                # ld bc,0051h; in a,(c)  buttons
emit(0x11, 0x00, 0x08)                            # ld de,0800h
wait = len(code)
emit(0x1b, 0x7a, 0xb3)                            # dec de; ld a,d; or e
emit(0x20, (wait - (len(code) + 2)) & 0xff)       # jr nz,wait
emit(0x18, (loop - (len(code) + 2)) & 0xff)       # jr loop
open(sys.argv[1], 'wb').write(bytes(code) + b'\xff' * (0x4000 - len(code)))
