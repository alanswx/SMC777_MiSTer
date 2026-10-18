# Verilator simulation

Headless simulation of the SMC-777 core, organised like SharpMZ2500_MiSTer's `verilator/`: one harness binary that runs
a number of frames, writes PNG screenshots, logs a hash of every frame and traces the CPU and I/O, plus a regression
script.

```
make            # build ./obj_dir_headless/Vtop
make test       # run_tests.sh: build, then the regression tests (out/test/)
make clean
```

Requires `verilator` 5.x, `ghdl` 5.x with `synth` (Homebrew's `ghdl` has it) and `python3` (no packages).

`make fast` builds `obj_dir_fast/Vtop` with clk_sys at the 32.2238 MHz master clock (CLK_MUL 1) instead of the
MiSTer's 2x: the same enables drive the CPU, CRTC and video, so frames and hashes are identical, at about twice the
speed. The default build is the MiSTer configuration.

## How it is built

- `sim.v` is the simulation top (`top`). It stands in for `smc777.sv` and instantiates the same machine,
  `rtl/smc777.sv`, so the core and the sim share all machine RTL. The C++ harness plays the part of hps_io.
- The CPU is the VHDL T80 v350 (rtl/T80_v350, as SharpMZ2500_MiSTer), converted by `ghdl synth --out=verilog` to
  `gen/t80s.v` with the instance's generics fixed; `fix_port_aliases.py` restores port aliases ghdl drops. (tv80 was
  used before; it had no refresh register, which hangs BASIC's random seed loop, and other ALU differences.)
- The floppy controller is `rtl/wd1793/wd1793.sv` (Sorgelig's, with FM-7_MiSTer's D77/D88 support as in
  SharpMZ2500) plus SMC-777 local changes: 1D/1DD media (one track per cylinder) and 2D media in the 80-track
  drive (head/2), both as CSP's DISK class.
- PNGs are written with `stb_image_write.h` (public domain); `ps2_keys.h` (from SharpMZ2500) turns `--type` text
  into PS/2 events for when the core has a keyboard.

## Harness options

```
./obj_dir_headless/Vtop --help
  --stop-at-frame N      exit after frame N (default 60)
  --rom FILE             IPL ROM, 16 KiB (default ../bios/SMCROM.DAT); --rom-dir DIR: DIR/SMCROM.DAT
  --screenshot N         PNG of frame N (repeatable); --dump-frames A:B; --dump-every K; --out DIR
  --double-lines         PNGs at 640x400 (each line twice, as CSP's screenshots)
  --frame-log FILE       frame,fb_hash,cpu_cycles,pc per frame (fb_hash = FNV-1a 32 over the RGB888 picture)
  --trace-cpu FILE       frame,cpu_cycle,pc at each M1
  --trace-io FILE        frame,cpu_cycle,pc,kind,address,data for each IN/OUT (the CSP CLI's columns)
  --trace-from/--trace-to N
  --fdd FILE             D88/.1dd image in drive A; --fdd-b FILE drive B; --fdd-readonly
  --type FRAME:TEXT      PS/2 typing (US layout; capitals with shift); --type-rate P:R frames pressed:released
                         (default 4:4; P = 0: press and release 1 ms apart); --type-burst F:TEXT: all of TEXT
                         inside frame F (events 1 ms apart, up to 15 keys)
                         {RETURN} {ESC} {BS} {DEL} {INS} {HOME} {CLR} {RUBOUT} {LF} {H} {BREAK} arrows {F1}-{F5} {WAITn}
                         {KANA} {RALT} {RGUI} {CTRL} {SHIFT}; {+NAME} / {-NAME} press / release only (a frame each)
  --joy F:PORT:BITS      joystick state from frame F (MiSTer bits: 1 right 2 left 4 down 8 up 16/32 triggers)
  --mouse                the mouse on joystick port 2 (OSD option); --mouse-move F:DX:DY[:B] moves it DX right and
                         DY down from frame F (PS/2 packets of up to 100, one per ms), buttons B (1 left, 2 right)
  --reset-at F / --warm-reset-at F   cold / warm (RESET key) reset before frame F
  --border               the border colour around the picture (704x232), the OSD option
  --kanji FILE           kanji ROM (default ../bios/KANJIROM.DAT); --rom-dir DIR: DIR/SMCROM.DAT + DIR/KANJIROM.DAT
  --wav FILE             audio from reset release, 48 kHz 16-bit stereo
  --save-state N:FILE    save the machine at the start of frame N; --load-state FILE resumes there
```

Frames are counted from the first full frame after the IPL programs the CRTC and end when vertical blanking starts.
That is about 12 frames after power-on, so sim frame N is roughly CSP frame N+12. A PNG is the active picture as the
core outputs it: 640x200.

The ROM goes in through the same ioctl download port the MiSTer uses (one byte per 4 clocks, machine in reset).

Speed on an M4 Max: about 2 frames per second (default build, the T80 netlist is the main cost), 3.6 with
`make fast`. Use `--save-state`/`--load-state` to skip the boot: System 1.1J's menu is at frame 300, BASIC at 800.

## Tests

`run_tests.sh` runs each test in parallel and compares against `tests/expected/`. `UPDATE=1 ./run_tests.sh` rewrites
the expected files (check the PNGs first).

| Test | Checks |
|---|---|
| `ipl_nodisk` | real IPL, no FDC: frame 500 hash ("Please Insert DISK" after the FDC timeout) |
| `ipl_nodisk_vs_csp` | the same frame equals CSP's screenshot pixel for pixel (`tests/ref/csp_ipl_nodisk_f600.png`) |
| `kanji_rom_vs_csp` | `tests/roms/make_kanji_test.py` as the IPL: 224 kanji ROM reads (7Eh) equal CSP's |
| `mouse` | `tests/roms/make_mouse_test.py` as the IPL reads the mouse as SMC Paint does; with `--mouse-move` the decoded movement and buttons must match (CSP has no mouse) |
| `sys11_menu_vs_csp` (GAMES=1) | System 1.1J's menu at frame 300 equals CSP's |
| `basic_typing` (GAMES=1) | System 1.1J -> BASIC with the cursor keys, a typed PRINT/hex$ and a FOR loop program, RUN |
| `basic_taps` (GAMES=1) | the same typed with 1 ms key taps (shift too) at 15 keys/s, then 14 keys in one frame: none lost or reordered |
| `yakyuukyou_vs_csp` (GAMES=1) | Yakyuu-Kyou (2D D88, 640x200 colour set 2) title equals CSP's |
| `sos22_vs_csp` (GAMES=1) | S-OS 2.2 (80 columns) at frame 1800 equals CSP's |
| `choplifter` (GAMES=1) | Choplifter (320x200 16 colours, animated attract) frame 1500 hash |
| `lode_runner` (GAMES=1) | Lode Runner: READ TRACK (its copy protection), title, attract mode at frame 1500 |
| `smc_paint` (GAMES=1) | SMC Paint 2.3 with the mouse: select Line, click two points; frame 1140 hash |

`GAMES=1` tests use the disks in `../software/extracted/` (not in the repository; `smc777/` and `Sony SMC-777/`
from the archives in ~/Downloads) and the fast build.

## Comparing with the reference emulator

The Common Source Code Project's macOS build (sibling `common_source_code/`) has a headless CLI for this machine,
modelled on the X1 one and on SharpMZ's `--script` mode:

```
cmake -S ../../common_source_code -B /tmp/csp-build -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/csp-build --target smc777 -j 8
/tmp/csp-build/smc777.app/Contents/MacOS/smc777 --headless --rom-dir ../bios --out /tmp/csp-ipl \
    --stop-at-frame 600 --screenshot 600 --trace-io io.csv --trace-to 120
/tmp/csp-build/smc777.app/Contents/MacOS/smc777 --headless --rom-dir ../bios --out /tmp/csp-sys11 \
    --disk-a "../software/extracted/smc777/smc777/sys11j/system 11.1dd" --stop-at-frame 900 --screenshot 900
```

It writes `frames.csv` (frame,clock,width,height,pc,rgb_fnv1a64), PNGs, optional CPU/I/O traces and `--wav` sound;
disks are always mounted as private copies in the output directory. `python3 wavinfo.py FILE.wav` lists tone
segments (start, length, frequency) for comparing sound: the IPL beep (210 ms, 1190.5 Hz) and a PSG tone set from
BASIC with OUT &H53 (719 Hz ideal; CSP 717.9, sim 718.8) agree. `python3 pngdiff.py --double-a sim.png csp.png` compares a
640x200 sim picture with a CSP screenshot. With the I/O traces, compare the `address,data` columns: the PC column
differs inside block instructions (CSP reports the ED prefix, the sim the last M1).

The sim boots disks faster than CSP (System 1.1J's menu at sim frame ~288 = CSP 300 vs CSP 402): the wd1793 model has
no rotational latency like CSP's MB8877. The screens match; only the frame at which they appear differs.
