# SMC-777 MiSTer core: status and remaining work

Status 2026-10-17: verified in simulation against CSP (eSMC-777) and on a MiSTer (mister126, below); mouse added
(SMC Paint). Quartus 17.0.2 build (misterubuntu): fits (16,081 ALMs 38%, 450/553 RAM blocks 81%), timing met (slow
85C model: core PLL 64.44 MHz +2.889 ns setup, +0.253 ns hold, TNS 0 on all clocks). releases/SMC777_20261017.rbf.

## Done (simulation, compared with CSP)

1. Floppy: MB8877A at 30h-34h (`rtl/smc777_fdc.sv`, wd1793 with D88), two drives on the MiSTer slots. 1DD media
   (one track per cylinder) and 2D media in the 80-track drive (head/2, odd tracks unformatted) as CSP's DISK.
   System 1.1J menu, Yakyuu-Kyou title, S-OS 2.2: pixel-identical.
2. Keyboard: 8041 key encoder (`rtl/smc777_kbd.sv`): shift/ctrl/caps/kana, repeat, programmable F1-F5/H, keyboard
   IRQ. PS/2 (US layout) table generated from CSP's (`tools/gen_kbd_table.py`). Unlike CSP (first held key in table
   order once a frame), presses queue in order with their shift/ctrl state and go out once a frame after the CPU has
   read the last code: on hardware, typing through MiSTerKVMS lost and reordered keys before. Right Alt toggles kana
   only when tapped alone (a KVM's Cmd+Option+Esc escape had turned kana on).
3. Video: 80/40-column text (both 40-column pages), attributes, cursor, 640x200 (both colour sets) and 320x200,
   colour generator and palette board, vsup, kanji ROM (7Eh/7Fh, reads identical to CSP), optional border (MAME
   style). MiSTer: video_mixer with scandoubler/HQ2x/scanlines.
4. Sound: beeper (IPL beep 210 ms / 1190.5 Hz = CSP), SN76489 at 4.028 MHz (divider fixed to period N: 718.8 Hz vs
   719 ideal), signed output. Cassette: line-in via the MiSTer ADC (ltc2308_tape), motor/out bits, monitor in the mix.
5. System: warm reset (1Ch bit 7, OSD), joysticks at 51h (CSP bit layout), shared vsync/keyboard IRQ held until
   acknowledge, T80 CPU (tv80 lacked the R register: BASIC hung; also hex$ printed lower case).
6. MiSTer top: hps_io with two VD slots, boot.rom = IPL + kanji, OSD (aspect, scandoubler, border, warm/cold
   reset, joystick), PLL 64.444 MHz (2 x master; CLK_MUL = 2), disk LED, Verilator lint of the top.

Also fixed: the HD46505 Verilog port had lost its HSYNC width counter (HSYNC stuck high: no horizontal sync on a
real display); restored from mc6845.vhd.

## Hardware (mister126, 2026-10-17, HDMI through MiSTerKVMS)

Native screenshots compared at each core pixel: System 1.1J menu, Yakyuu-Kyou title and S-OS 2.2 identical to CSP;
SMC Paint's mouse-drawn line identical to the sim. Floppy boots (MGL mounts), keyboard (BASIC typing at the KVM's
default 50 ms per key), mouse (moves, clicks, Line tool), PSG tone (717.7 Hz) and the IPL beep (210 ms) on HDMI
audio, Choplifter and Lode Runner run.

READ TRACK ($E0) added to the wd1793 for D88 images (a track synthesised as CSP's make_track): Lode Runner's loader
checks an ID with H = $AA and the gap after it, and hung at a black screen without it.

## Remaining

- Hardware not yet tried: analog 15 kHz output, the scandoubler/HQ2x options, two drives at once, disk writes, the
  ADC cassette, joysticks. RAM blocks are at 81%: room is limited if more BRAM is added.
- Quartus fixes made for 17.0 (Verilator accepted them): function-result bit selects in smc777_kbd, `'0` and regs
  driven by assign in mc6845.v, and the port's duplicated h_counter process (where the HSYNC counter belonged).
- Floppy timing: no rotational latency (boots faster than CSP); fine for software seen so far. Disk writes verified:
  after BASIC SAVE "test" the sim's image is byte-identical to CSP's written copy.
- Cassette: untested (no SMC-777 tape images in the library); test with a WAV through line-in.
- Joysticks: port 51h values equal CSP's (run_tests joystick); not yet tried with a game (Dragon expects port 1).
- Mouse (OSD Port 2 = Mouse, `rtl/smc777_mouse.sv`): neither CSP nor MAME emulates it, so the protocol is taken from
  SMC Paint 2.3's driver (MSX style: OUT 51h pin 5 strobe, nibbles X hi/lo, Y hi/lo on bits 3-0; buttons on the trigger bits 4/5).
  SMC Paint's pointer follows the mouse in the sim. Unknown: the real mouse's sign/scale and the strobe timing it
  needs, and whether other software (graphics editors) uses the same protocol. SMC Paint also has a serial mouse
  driver (ports 26h/27h, Microsoft 3-byte packets) patched out; RS-232 is not modelled.
- Interlace / 400-line modes (CP/M setup in MAME's TODO) and CRTC R9 != 7 rasters: nothing in the library uses them.
- Floppy-less boot paths: auto-start ROM (70h), the SMC-70 (RTC, extra graphics modes) are not modelled.
- Printer (22h/1Dh), RS-232, expansion bus: not modelled.
- RAM/ROM bank switch: CSP's two-fetch delay is modelled; writes under the ROM go to RAM (MAME); CSP discards
  them. No software seen depends on it.
- Repository: `bios/` holds copyrighted ROMs and a disk image; remove them (and from history) before publishing.
- CSP CLI: tape (`--tape`) for cassette comparisons.
