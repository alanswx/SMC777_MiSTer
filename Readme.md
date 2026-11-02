# Sony SMC-777 for MiSTer

The Sony SMC-777 (1983): Z80A at 4.028 MHz, 64 KiB RAM, 16 KiB IPL ROM, HD46505 CRTC with 80/40-column text and a
programmable font (PCG), 640x200 4-colour / 320x200 16-colour graphics, the colour palette board, kanji ROM,
SN76489AN + beeper, MB8877A floppy controller with 3.5" drives, cassette.

Status: verified in simulation against the Common Source Code Project (eSMC-777): the IPL, System 1.1J and its
BASIC (keyboard, typing, programs), Choplifter, Yakyuu-Kyou and S-OS boot, with screens pixel-identical to CSP's.
SMC Paint 2.3 works with the mouse (OSD Port 2 = Mouse), Lode Runner (READ TRACK protection) runs. Tested on a
MiSTer over HDMI: screens identical to CSP, floppy, keyboard, mouse and sound work. Builds in Quartus 17.0.2 and meets
timing (clk_sys 64.44 MHz, +2.89 ns setup slack; 38% ALMs, 81% RAM blocks): `releases/SMC777_20261017.rbf`. See [TODO.md](TODO.md).

- `smc777.sv` MiSTer top (hps_io, PLL, floppy slots, cassette ADC, video_mixer), `rtl/smc777.sv` the machine,
  `rtl/smc777_kbd.sv` keyboard (8041), `rtl/smc777_mouse.sv` mouse, `rtl/smc777_fdc.sv` floppy (wd1793 with D88), `rtl/T80_v350` the CPU.
- `verilator/` headless simulation, regression tests and the comparison with CSP: [verilator/README.md](verilator/README.md).

## Setup

`games/SMC777/boot.rom` = `SMCROM.DAT` (16 KiB IPL ROM) followed by `KANJIROM.DAT` (144 KiB), as used by WinSMC/CSP:

```
cat SMCROM.DAT KANJIROM.DAT > boot.rom
```

Without the kanji part, everything but kanji text works.

Floppies: D88 images on drives A and B (S0/S1). The SMC-777 disk images found as `.1dd` are D88 files (media byte
30h/40h, one track per cylinder); 40-track 2D D88 images are read in the 80-track drive as on the real machine.

## OSD

Laid out as the MiSTer computer-core OSD and tape standards (`osd-standard.md`, `tape-standard.md`): media on the
top page, then the pages, then Apply and reset. The Video settings take effect at Apply and reset ("Changes pending"
shows until then); media, Input, the tape rows and the buttons act at once.

- Top: Pri. Drive A, Drive B (D88), Tape (WAV), Load ROM; Machine, Video, Input, Audio; Apply and reset (cold reset).
- Machine: Tape speed (8x, Normal), Rewind tape, RESET key (warm reset: port 1Ch bit 7 = 1, the IPL keeps memory).
- Video: Aspect ratio, Scandoubler Fx (HQ2x, CRT scanlines; the core is 15.7 kHz, the scandoubler is used for VGA
  too), Border (the border colour, port 23h, around the 640x200 picture, as MAME; CSP does not draw it), Tape overlay.
- Input: Port 2 = Joystick or Mouse (the SMC-777 mouse on joystick port 2, for SMC Paint; the MiSTer's USB/PS/2
  mouse, left and right buttons). Joysticks: port 1 and 2, two triggers.
- Audio: Tape audio (the cassette monitor: the tape signal in the sound while the motor runs).

## Keyboard

The SMC-777 keyboard is ASCII-layout, so a US PC keyboard maps by position. Shift, Ctrl, Caps Lock; the JP kana
key, or Right Alt tapped on its own, toggles kana (Right Alt as part of a combination, such as a KVM's escape keys,
does not). F1-F5 are the programmable function keys, F11 = H (home-position key), F12 = LF,
End = CLR, F6, F10 or the JP yen key = RUB OUT (ル), backtick = ` ~, backslash = \ |.

## Cassette

A WAV on the Tape slot (`rtl/smc777_tape.sv`): PCM, 8- or 16-bit, mono or stereo (the first channel plays), 4-192 kHz,
streamed from the SD card, any length. Each mount starts rewound. The mount shows "Tape ready (rewound)" with a reminder to
`CLOAD` in System 1.1J BASIC (or, with drive A empty, to boot System 1.1J first) for 2 seconds; anything else is
"Tape format not supported". In System 1.1J BASIC type `CLOAD "NAME"` (or `CLOAD ""` for the next file; a bare `CLOAD` is a syntax error): the deck plays while
BASIC has the motor relay (port 1Ch) on, like a recorder with remote control. Rewind tape (Machine) goes back to the
start, for example to load a file again.

Tape speed 8x: while the deck plays, the CPU and the tape both run eight times faster (32 MHz, every other clk_sys),
so BASIC's polling loops see the same pulse widths; the FDC, keyboard, PSG and video keep their speed, and the
machine is back at 4 MHz the moment the motor stops. Turbo is chosen when the motor starts, and only for WAVs up to
50 000 bytes per second (22/44 kHz 8-bit mono, 22 kHz 16-bit mono); larger ones play at 1x. There is no quick start:
the SMC-777 loads tapes from a typed BASIC command, with no cartridge or ROM boot path to use (tape standard, "Other
machines").

The status bar (Video: Tape overlay) shows `TAPE > m:ss/ m:ss x8` and a progress bar at the bottom left while the
deck plays; a `!` after it means the deck had to wait for the SD card (a buffer underflow; please report it).

Without a tape image, the cassette input is line-in through the MiSTer ADC (I/O board / analog input): `CLOAD "NAME"`,
then play the tape; the motor relay (port 1Ch) is the cue. The format (System 1.1J BASIC, F59Eh-F6ABh): a ~726 Hz leader, then bytes of a start cycle, 8 bits MSB
first (0 ~1600 Hz, 1 ~1200 Hz cycles) and a stop cycle; a 32-byte header block (type, 8+3 name, ...) and 128-byte
data blocks, each with an XOR checksum. BASIC's bit threshold leaves only a few percent of margin for tape speed.

## Tools

- `tools/smc777_tape.py WAV` finds SMC-777 files on a tape recording, `--dump DIR` extracts them, `--write-wav DIR`
  writes clean WAVs at BASIC's own timing; it prints the `--tape-speed` the sim needs for a fast or slow dump.
- `tools/img2d88.py IN OUT.1dd` converts SMC-70/777 ImageDisk (.imd) or raw (.img) disks to the D88 the core mounts
  (Sony's CP/M 2.2 boots from them).
- `tools/gen_kbd_table.py` generates the PS/2 keyboard table from CSP's.
