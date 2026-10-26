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

- Aspect ratio, Scandoubler Fx (HQ2x, CRT scanlines; the core is 15.7 kHz, the scandoubler is used for VGA too).
- Border: show the border colour (port 23h) around the 640x200 picture, as MAME does (CSP does not draw it).
- Warm reset: the RESET key (port 1Ch bit 7 = 1, the IPL keeps memory); Cold reset.
- Joysticks: port 1 and 2, two triggers. Port 2: Joystick or Mouse (the SMC-777 mouse on joystick port 2, for SMC
  Paint; the MiSTer's USB/PS/2 mouse, left and right buttons).
- Cassette: line-in through the MiSTer ADC (I/O board / analog input).

## Keyboard

The SMC-777 keyboard is ASCII-layout, so a US PC keyboard maps by position. Shift, Ctrl, Caps Lock; the JP kana
key, or Right Alt tapped on its own, toggles kana (Right Alt as part of a combination, such as a KVM's escape keys,
does not). F1-F5 are the programmable function keys, F11 = H (home-position key), F12 = LF,
End = CLR, F6, F10 or the JP yen key = RUB OUT (ル), backtick = ` ~, backslash = \ |.

## Cassette

Line-in through the MiSTer ADC. In System 1.1J BASIC: `CLOAD "NAME"`, then play the tape; the motor relay (port 1Ch)
is the cue. The format (System 1.1J BASIC, F59Eh-F6ABh): a ~726 Hz leader, then bytes of a start cycle, 8 bits MSB
first (0 ~1600 Hz, 1 ~1200 Hz cycles) and a stop cycle; a 32-byte header block (type, 8+3 name, ...) and 128-byte
data blocks, each with an XOR checksum. BASIC's bit threshold leaves only a few percent of margin for tape speed.

## Tools

- `tools/smc777_tape.py WAV` finds SMC-777 files on a tape recording, `--dump DIR` extracts them, `--write-wav DIR`
  writes clean WAVs at BASIC's own timing; it prints the `--tape-speed` the sim needs for a fast or slow dump.
- `tools/img2d88.py IN OUT.1dd` converts SMC-70/777 ImageDisk (.imd) or raw (.img) disks to the D88 the core mounts
  (Sony's CP/M 2.2 boots from them).
- `tools/gen_kbd_table.py` generates the PS/2 keyboard table from CSP's.
