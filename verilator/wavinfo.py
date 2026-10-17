#!/usr/bin/env python3
"""Summarise a 16-bit WAV: tone segments (start, length, frequency from the dominant edge rate) and levels.

    wavinfo.py FILE.wav [--min-ms N]

Used to compare the core's sound (sim --wav) with CSP's (smc777 --headless --wav). Standard library only.
"""
import struct
import sys
import wave


def main():
    path = sys.argv[1]
    min_ms = float(sys.argv[sys.argv.index('--min-ms') + 1]) if '--min-ms' in sys.argv else 5
    w = wave.open(path)
    rate, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
    raw = w.readframes(n)
    s = struct.unpack('<%dh' % (len(raw) // 2), raw)[::ch]
    print(f'{path}: {rate} Hz, {n / rate:.3f} s, min {min(s)} max {max(s)}')
    win = max(1, rate // 100)                      # 10 ms windows
    segs, cur = [], None
    for i in range(0, len(s) - win, win):
        blk = s[i:i + win]
        mean = sum(blk) / win
        edges = sum(1 for a, b in zip(blk, blk[1:]) if (a - mean) * (b - mean) < 0 and abs(b - a) > 64)
        amp = max(blk) - min(blk)
        f = edges / 2 / (win / rate)
        active = amp > 256 and edges >= 2
        if active and cur and abs(f - cur[2] / cur[3]) < 0.1 * max(f, 1):
            cur[1] = i + win; cur[2] += f; cur[3] += 1; cur[4] = max(cur[4], amp)
        else:
            if cur: segs.append(cur)
            cur = [i, i + win, f, 1, amp] if active else None
    if cur: segs.append(cur)
    for a, b, fs, k, amp in segs:
        if (b - a) * 1000 / rate >= min_ms:
            print(f'  {a / rate:7.3f} s  {(b - a) * 1000 / rate:7.1f} ms  {fs / k:7.1f} Hz  p-p {amp}')


if __name__ == '__main__':
    main()
