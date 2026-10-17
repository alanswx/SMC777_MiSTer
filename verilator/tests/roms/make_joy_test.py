#!/usr/bin/env python3
"""Build joy_test.rom: an IPL replacement that programs the HD46505 and then reads port 51h for joystick 1
(B = 01h) and joystick 2 (B = 00h) about every 8 ms, forever. Compare the --trace-io reads (bit 7, blanking, masked)
between the sim (--joy, MiSTer bits) and CSP (--joy, its bits) with the same joystick states."""
import sys
CRTC = [0x7f, 0x50, 0x60, 0x3a, 0x1f, 0x06, 0x19, 0x1c, 0xa0, 0x07, 0x60, 0x0f, 0, 0, 0, 0]
code = bytearray()
def emit(*b): code.extend(b)
emit(0xf3, 0x31, 0x00, 0x00)
for r in range(15, -1, -1):
    emit(0x3e, r, 0xd3, 0x18, 0x3e, CRTC[r], 0xd3, 0x19)
loop = len(code)
emit(0x01, 0x51, 0x01, 0xed, 0x78)                # ld bc,0151h; in a,(c)
emit(0x01, 0x51, 0x00, 0xed, 0x78)                # ld bc,0051h; in a,(c)
emit(0x11, 0x00, 0x08)                            # ld de,0800h
wait = len(code)
emit(0x1b, 0x7a, 0xb3)                            # dec de; ld a,d; or e
emit(0x20, (wait - (len(code) + 2)) & 0xff)       # jr nz,wait
emit(0x18, (loop - (len(code) + 2)) & 0xff)       # jr loop
open(sys.argv[1], 'wb').write(bytes(code) + b'\xff' * (0x4000 - len(code)))
