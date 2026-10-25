#!/usr/bin/env python3
"""Convert an SMC-70/777 3.5" single-sided disk image to D88 (1DD media, as the .1dd images the core mounts).

    img2d88.py IN OUT.1dd

IN is an ImageDisk file (.imd, e.g. MAME's cpm22.imd) or a raw sector dump (.img: tracks of 16 x 256-byte sectors,
286720 bytes for 70 tracks). D88: one track per cylinder (head 0), sectors C/H/R/N = track/0/1../1, MFM."""
import struct, sys

def read_imd(d):
    p = d.index(0x1a) + 1
    tracks = {}
    while p < len(d):
        mode, cyl, head, ns, sz = d[p:p + 5]; p += 5
        smap = d[p:p + ns]; p += ns
        if head & 0x80: p += ns          # cylinder map
        if head & 0x40: p += ns          # head map
        size = 128 << sz
        secs = {}
        for r in smap:
            t = d[p]; p += 1
            if t == 0: data = bytes(size)                       # unavailable
            elif t in (2, 4, 6, 8): data = bytes([d[p]]) * size; p += 1   # compressed
            else: data = d[p:p + size]; p += size
            secs[r] = data
        tracks[(cyl, head & 0x3f)] = (size, [(r, secs[r]) for r in sorted(secs)])
    return tracks

def read_raw(d):
    tsz = 16 * 256
    return {(c, 0): (256, [(r + 1, d[c * tsz + r * 256:c * tsz + (r + 1) * 256]) for r in range(16)])
            for c in range(len(d) // tsz)}

def write_d88(tracks, name):
    ntr = max(c for c, h in tracks) + 1
    offs = [0] * 164
    body = bytearray()
    for c in range(ntr):
        if (c, 0) not in tracks: continue
        offs[c] = 0x2b0 + len(body)
        size, secs = tracks[(c, 0)]
        n = {128: 0, 256: 1, 512: 2, 1024: 3}[size]
        for r, data in secs:
            body += struct.pack('<4BHBBB5xH', c, 0, r, n, len(secs), 0, 0, 0, size) + data
    hdr = name.encode()[:16].ljust(17, b'\0') + bytes(9) + bytes([0x00, 0x30]) + struct.pack('<I', 0x2b0 + len(body))
    return hdr + struct.pack('<164I', *offs) + body

src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
tracks = read_imd(d) if d[:4] == b'IMD ' else read_raw(d)
open(dst, 'wb').write(write_d88(tracks, 'SMC'))
print(f'{dst}: {len(tracks)} tracks')
