#!/usr/bin/env python3
"""Find and decode SMC-777 cassette blocks in a WAV file.

    smc777_tape.py TAPE.wav [--from SEC] [--to SEC] [--dump DIR]

The format is taken from System 1.1J BASIC's tape routines (loaded at F59Eh-F6ABh; CPU 4.028 MHz):
  write: leader of half-cycles of B = D0h (~745 Hz; 6250 halves for a header block, 20 for the block after it),
         sync halves B = 5Bh, 56h, then per byte: start halves 5Bh, 5Dh; 8 bits MSB first, each a full cycle of
         two halves 5Ch (0, ~1600 Hz) or 7Bh (1, ~1200 Hz); stop halves 5Eh, 54h. After the data an XOR checksum byte,
         then 7002 halves of 5Ah (~1600 Hz) as a trailer.
  read:  the polling loop takes 54 T-states. Leader: full cycles longer than 49 loops (0.657 ms); then halves longer
         than 40 loops (0.536 ms) until the short sync half; a bit is 1 when its full cycle is longer than 53 loops
         (0.711 ms). Edges are level changes of port 1Dh bit 7, so the polarity doesn't matter.
A file is a header block (382 bytes after a long leader: type 01 = BASIC, 00 = Sony Filer; 8+3 name; at 10h a
length for BASIC files, which matches MAKEMAP and TAKOKU but not all files: a guess) and the 128-byte blocks after
it, each with a short leader. Prints the files found (-v: every block) with the leader frequency against the nominal 726.5 Hz, and a --tape-speed for the sim that puts
BASIC's bit threshold midway between the longest 0 and the shortest 1 cycles (1% outliers dropped; the lowest over
the file's blocks); --dump writes them out. The Sony Filer's files
(type 00, the 1985 ASCII tapes) have their own block checksum: their last byte is not decoded here."""
import argparse, array, os, wave

T = 54 / 4.028e6                     # one pass of BASIC's polling loop
LEADER_CYC = 49 * T                  # header: leader full cycle longer than this
LEADER_HALF = 40 * T                 # leader halves until the sync half
BIT_CYC = 53 * T                     # a data bit's full cycle longer than this = 1
# The leader as BASIC writes it: halves of DJNZ B = D0h plus the loop at F669h, 2772 T-states. A tape whose leader is
# faster than this plays fast: its 1 bits (~59 polls) come close to the threshold of 54 and read as 0.
LEADER_HZ = 4.028e6 / (2 * 2772)

def edges(path, t0, t1):
    w = wave.open(path)
    rate, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
    w.setpos(int(t0 * rate))
    n = int(((t1 if t1 else w.getnframes() / rate) - t0) * rate)
    raw = w.readframes(n)
    a = array.array('B' if sw == 1 else 'h', raw)[::ch]
    mid, hyst = (128, 8) if sw == 1 else (0, 1500)
    level, out = None, []
    for i, v in enumerate(a):
        nl = 1 if v > mid + hyst else 0 if v < mid - hyst else level
        if nl is not None and nl != level:
            if level is not None: out.append(t0 + i / rate)
            level = nl
    return out

def decode(ts):
    halves = [(ts[i], ts[i + 1] - ts[i]) for i in range(len(ts) - 1)]
    i, blocks = 0, []
    global ones, zeros
    while i < len(halves) - 40:
        # leader: at least 5 full cycles longer than LEADER_CYC
        run = 0
        while i < len(halves) - 1 and run < 8:
            if halves[i][1] + halves[i + 1][1] > LEADER_CYC: run += 1; i += 2
            else: run = 0; i += 1
        if run < 8: break
        start = halves[i][0]
        nlead, j0 = run, i
        while i < len(halves) and halves[i][1] > LEADER_HALF: i += 1; nlead += 1
        j0 = max(j0, i - 2000)                       # the end of the leader: speech can come before it
        lead_hz = (i - j0) / 2 / (halves[i - 1][0] + halves[i - 1][1] - halves[j0][0]) if i - j0 > 100 else 0
        i += 2                                       # the two sync halves
        data, ones, zeros = [], [], []
        while i + 20 <= len(halves):
            h = [d for _, d in halves[i:i + 20]]
            if max(h) > 0.0012 or h[0] + h[1] > LEADER_CYC * 1.3: break   # gap, noise or next leader
            b = 0
            for k in range(8):
                cyc = h[2 + 2 * k] + h[3 + 2 * k]
                b = b << 1 | (cyc > BIT_CYC)
                (ones if cyc > BIT_CYC else zeros).append(cyc)
            data.append(b)
            i += 20
        if data:
            x = 0
            for b in data[:-1]: x ^= b
            # the speed that puts BASIC's threshold midway between the longest 0s and the shortest 1s
            if len(ones) > 20 and len(zeros) > 20:
                ones.sort(); zeros.sort()
                mid = (zeros[len(zeros) * 99 // 100] + ones[len(ones) // 100]) / 2
                speed = mid / (BIT_CYC + T)
            else:
                speed = 0
            blocks.append((start, nlead, bytes(data), x == data[-1], lead_hz, speed))
    return blocks

def show(b):
    s = ''.join(chr(c) if 32 <= c < 127 else '.' for c in b[:48])
    return b[:24].hex(' ') + '  |' + s + '|'

def write_wav(path, hdr, blocks, rate=22050):
    """BASIC's SAVE (F624h): half-cycles in T-states at 4.028 MHz from its DJNZ counts."""
    out, lvl = bytearray(), [0]
    def half(tstates):
        n = round(tstates / 4.028e6 * rate * 1e0)
        out.extend(bytes([0x30 if lvl[0] else 0xd0]) * n); lvl[0] ^= 1
    def block(data, leader):
        for _ in range(leader): half(2772)            # D0h
        half(1223); half(1158)                        # sync 5Bh, 56h
        x = 0
        for k, b in enumerate(list(data) + [None]):
            if b is None: b = x
            else: x ^= b
            half(1223); half(1249)                    # start 5Bh, 5Dh
            for i in range(7, -1, -1):
                t = 1634 if b >> i & 1 else 1236     # 7Bh / 5Ch
                half(t); half(t)
            half(1262); half(1132)                    # stop 5Eh, 54h
        half(1225); half(1225)                        # two more halves before the gap (BASIC stops here)
    def gap(sec): out.extend(b'\x80' * int(sec * rate))
    gap(1)
    block(hdr, 6250)
    for _ in range(7002): half(1225)                  # trailer 5Ah after the header
    for d in blocks:
        gap(0.5); block(d, 20)
    gap(1)
    import wave as _w
    os.makedirs(os.path.dirname(path), exist_ok=True)
    w = _w.open(path, 'wb'); w.setnchannels(1); w.setsampwidth(1); w.setframerate(rate); w.writeframes(bytes(out)); w.close()

ap = argparse.ArgumentParser()
ap.add_argument('wav'); ap.add_argument('--from', dest='t0', type=float, default=0)
ap.add_argument('--to', dest='t1', type=float, default=0)
ap.add_argument('--dump', help='write each file (header + its data blocks, cut to the header length) to DIR')
ap.add_argument('-v', action='store_true', help='list every block, not just the files')
ap.add_argument('--write-wav', metavar='DIR', help='write each BASIC file as a clean WAV (22050 Hz, 8-bit) at BASIC\'s own timing')
a = ap.parse_args()
files = []
for t, lead, data, ok, hz, sp in decode(edges(a.wav, a.t0, a.t1)):
    if len(data) < 2: continue
    if a.v: print(f'{t:8.2f}s leader {lead:5d}  {len(data) - 1:6d} bytes  checksum {"ok " if ok else "BAD"}  {show(data)}')
    if len(data) >= 33 and lead > 1000:          # header: type, 8+3 name, ..., length at 10h
        data = data[:32] + bytes([data[32]])          # a 32-byte header; the trailer after it reads as zeros
        files.append({'t': t, 'hdr': data[:-1], 'ok': ok, 'blocks': [], 'hz': hz, 'sp': []})
    elif files and lead < 100:
        files[-1]['blocks'].append((data, ok)); files[-1]['sp'].append(sp)
for f in files:
    h = f['hdr']
    name = h[1:9].decode('latin1').rstrip() + '.' + h[9:12].decode('latin1').rstrip()
    if a.write_wav and h[0] == 1: write_wav(os.path.join(a.write_wav, name + '.wav'), h, [d[:-1] for d, _ in f['blocks']])
    length = h[0x10] | h[0x11] << 8
    bad = sum(1 for _, ok in f['blocks'] if not ok)
    body = b''.join(d[:-1] for d, _ in f['blocks'])
    print(f'{f["t"]:8.2f}s  {name:12s} type {h[0]:02x}  length {length:5d}  {len(f["blocks"]):3d} blocks, {bad} with bad checksums'
          f'{"" if f["ok"] else "  (header checksum BAD)"}  leader {f["hz"]:.1f} Hz ({LEADER_HZ / f["hz"]:.3f} of nominal);'
          f' --tape-speed {min(x for x in f["sp"] if x) if any(f["sp"]) else LEADER_HZ / f["hz"]:.3f}')
    if a.dump:
        os.makedirs(a.dump, exist_ok=True)
        open(os.path.join(a.dump, name), 'wb').write(body[:length] if h[0] == 1 and length <= len(body) else body)
        open(os.path.join(a.dump, name + '.hdr'), 'wb').write(h)
