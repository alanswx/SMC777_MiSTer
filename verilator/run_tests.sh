#!/bin/bash
# Regression tests for the SMC-777 simulation. Run from verilator/ (make test).
#
#   ipl_nodisk  real IPL, no FDC/disk: the IPL polls the FDC (not ready) for ~5 s and prints "Please Insert DISK".
#               Frame 500 hash, and the picture must equal CSP's screenshot pixel for pixel
#               (tests/ref/csp_ipl_nodisk_f600.png: smc777 --headless ... --screenshot 600, see README.md).
#
#   kanji_rom   tests/roms/make_kanji_test.py as the IPL: 224 reads of port 7Eh (seven JIS codes x 32 bytes, two of
#               them out of range) must equal CSP's (tests/ref/csp_kanji_reads.md5).
#   joystick    tests/roms/make_joy_test.py as the IPL with --joy states: the port 51h values must equal CSP's
#               (tests/ref/csp_joy_reads.txt, smc777 --headless --joy with the same states in CSP's bit order).
#   mouse       tests/roms/make_mouse_test.py as the IPL with --mouse-move: reads the mouse on port 2 as SMC Paint does;
#               the decoded movement must add up to the moves (more than 127 split over reads, never 80h) and the
#               buttons follow them. CSP has no mouse: the protocol is SMC Paint's driver (rtl/smc777_mouse.sv).
#
# GAMES=1 adds disk tests (the software library, ../software/extracted/, see ../README.md; read-only mounts).
# They run on the fast build (make fast; same frames, half the clk_sys) and take several minutes each, in parallel:
#   sys11_menu     System 1.1J boots to its file menu; frame 300 equals CSP's (palette board, PCG font)
#   basic_typing   System 1.1J -> BASIC (cursor keys, RETURN), types a program and RUNs it: frame hash
#   yakyuukyou     Yakyuu-Kyou (2D D88 in the 80-track drive, 640x200 colour set 2): title equals CSP's
#   sos22          S-OS 2.2 (80 columns): frame 1800 equals CSP's
#   choplifter     Choplifter (320x200 16 colours): frame 1500 hash
#   smc_paint      SMC Paint 2.3 with the mouse: click the Line tool, click two points: frame 1140 hash (a line from
#                  60,60 to 200,150, "LINE 200,150")
#
# Needs the IPL ROM (../bios/SMCROM.DAT, or ROM=path). Tests run in parallel; each writes to out/test/<name>.log.
# Set UPDATE=1 to rewrite the expected files. The IPL test takes about 4 minutes (~2 frames per second).

cd "$(dirname "$0")"
BIN=${BIN:-./obj_dir_headless/Vtop}
OUT=${OUT:-out/test}
EXP=tests/expected
ROMARG=()
[ -n "$ROM" ] && ROMARG=(--rom "$ROM")
mkdir -p "$OUT"

pids=(); names=()
run() {   # run NAME ARGS...
    local name=$1; shift
    ( $BIN --quiet "${ROMARG[@]}" --out "$OUT/$name" "$@" > "$OUT/$name.out" 2> "$OUT/$name.log" ) &
    pids+=($!); names+=("$name")
}

run ipl_nodisk --stop-at-frame 500 --screenshot 500 --double-lines --frame-log "$OUT/ipl_nodisk.csv"
mkdir -p "$OUT/kanji"
python3 tests/roms/make_kanji_test.py "$OUT/kanji/kanji_test.rom"
( $BIN --quiet --rom "$OUT/kanji/kanji_test.rom" --out "$OUT/kanji_rom" --stop-at-frame 40 --trace-io "$OUT/kanji_rom.io" \
    > "$OUT/kanji_rom.out" 2> "$OUT/kanji_rom.log" ) &
pids+=($!); names+=(kanji_rom)

python3 tests/roms/make_joy_test.py "$OUT/kanji/joy_test.rom"
( $BIN --quiet --rom "$OUT/kanji/joy_test.rom" --out "$OUT/joystick" --stop-at-frame 50 --trace-io "$OUT/joystick.io" \
    --joy 10:0:8 --joy 20:0:17 --joy 30:1:36 --joy 40:0:0 --joy 40:1:0 > "$OUT/joystick.out" 2> "$OUT/joystick.log" ) &
pids+=($!); names+=(joystick)

python3 tests/roms/make_mouse_test.py "$OUT/kanji/mouse_test.rom"
( $BIN --quiet --rom "$OUT/kanji/mouse_test.rom" --out "$OUT/mouse" --stop-at-frame 50 --trace-io "$OUT/mouse.io" \
    --mouse-move 10:300:-40:1 --mouse-move 25:-7:13:2 --mouse-move 35:0:0:0 > "$OUT/mouse.out" 2> "$OUT/mouse.log" ) &
pids+=($!); names+=(mouse)

SW=../software/extracted/smc777/smc777
FAST=${FAST:-./obj_dir_fast/Vtop}
runf() { local b=$BIN; BIN=$FAST; run "$@"; BIN=$b; }
if [ -n "$GAMES" ]; then
    runf sys11_menu --fdd "$SW/sys11j/system 11.1dd" --fdd-readonly --stop-at-frame 300 --screenshot 300 --double-lines
    runf basic_typing --fdd "$SW/sys11j/system 11.1dd" --fdd-readonly --type '310:{DOWN}{DOWN}{DOWN}{DOWN}{DOWN}{DOWN}' \
        --type '390:\n' --type-rate 3:3 --type '805:print "Hello, World!";3*4+1;hex$(43981)\n10 FOR I=1 TO 3:PRINT I*I;:NEXT\nRUN\n' \
        --stop-at-frame 1300 --screenshot 1300 --double-lines --frame-log "$OUT/basic_typing.csv"
    runf yakyuukyou --fdd "$SW/yakyuuky/yakyuu-kyou (smc-777) [fd].d88" --fdd-readonly --stop-at-frame 1500 --screenshot 1500 --double-lines
    runf sos22 --fdd "$SW/sos22/s-os sword monitor 2.2.1dd" --fdd-readonly --stop-at-frame 1800 --screenshot 1800 --double-lines
    runf choplifter --fdd "$SW/choplift/choplifter.1dd" --fdd-readonly --stop-at-frame 1500 --screenshot 1500 --double-lines \
        --frame-log "$OUT/choplifter.csv"
    SW2="../software/extracted/Sony SMC-777/Sony SMC-777"
    runf smc_paint --fdd "$SW2/SMC_PAINT23.1DD" --fdd-readonly --mouse-move 1005:88:10 --mouse-move 1020:0:0:1 \
        --mouse-move 1025:0:0:0 --mouse-move 1050:-28:50 --mouse-move 1070:0:0:1 --mouse-move 1075:0:0:0 \
        --mouse-move 1085:140:90 --mouse-move 1105:0:0:1 --mouse-move 1110:0:0:0 \
        --stop-at-frame 1140 --screenshot 1140 --double-lines --frame-log "$OUT/smc_paint.csv"
fi

fail=0
for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then echo "FAIL ${names[$i]} (exit status; see $OUT/${names[$i]}.log)"; fail=1; fi
done

# Frame hash at a given frame from a --frame-log CSV.
hash_at() { awk -F, -v f="$2" '$1 == f { print $2 }' "$1"; }

check() {   # check NAME ACTUAL
    local name=$1 actual=$2
    if [ -n "$UPDATE" ]; then echo "$actual" > "$EXP/$name.txt"; echo "UPDATED $name"; return; fi
    if [ "$actual" == "$(cat "$EXP/$name.txt" 2>/dev/null)" ]; then echo "PASS $name"
    else echo "FAIL $name: got '$actual', expected '$(cat "$EXP/$name.txt" 2>/dev/null)'"; fail=1; fi
}

check ipl_nodisk "$(hash_at "$OUT/ipl_nodisk.csv" 500)"
if python3 pngdiff.py "$OUT/ipl_nodisk/frame_000500.png" tests/ref/csp_ipl_nodisk_f600.png > "$OUT/ipl_nodisk.cmp"; then
    echo "PASS ipl_nodisk_vs_csp"
else echo "FAIL ipl_nodisk_vs_csp: $(cat "$OUT/ipl_nodisk.cmp")"; fail=1; fi

kanji=$(awk -F, '$4=="R" && $5 ~ /7e$/ {print $5, $6}' "$OUT/kanji_rom.io" | md5 -q 2>/dev/null || awk -F, '$4=="R" && $5 ~ /7e$/ {print $5, $6}' "$OUT/kanji_rom.io" | md5sum | cut -d' ' -f1)
if [ "$kanji" == "$(cat tests/ref/csp_kanji_reads.md5)" ]; then echo "PASS kanji_rom_vs_csp"; else echo "FAIL kanji_rom_vs_csp"; fail=1; fi

python3 - "$OUT/joystick.io" > "$OUT/joystick.txt" <<'PY'
import csv, sys
last = {}
for r in csv.DictReader(open(sys.argv[1])):
    if r["kind"] == "R" and r["address"].endswith("51"):
        v = int(r["data"], 16) & 0x7f          # bit 7 is the blanking status
        if last.get(r["address"]) != v:
            print(r["address"], "%02x" % v); last[r["address"]] = v
PY
if cmp -s "$OUT/joystick.txt" tests/ref/csp_joy_reads.txt; then echo "PASS joystick_vs_csp"; else echo "FAIL joystick_vs_csp"; fail=1; fi

python3 - "$OUT/mouse.io" > "$OUT/mouse.txt" <<'PY'
import csv, sys
r = [int(x["data"], 16) for x in csv.DictReader(open(sys.argv[1])) if x["kind"] == "R" and x["address"] == "0051"]
dx = dy = 0; bad = 0; btn = []
for i in range(0, len(r) - 4, 5):
    x = (r[i] & 15) << 4 | (r[i + 1] & 15); y = (r[i + 2] & 15) << 4 | (r[i + 3] & 15)
    bad += (x == 0x80) + (y == 0x80)
    dx -= x - 256 if x & 0x80 else x; dy -= y - 256 if y & 0x80 else y
    b = (~r[i + 4] >> 4) & 3                    # bit 4 = left, bit 5 = right, active low
    if not btn or btn[-1] != b: btn.append(b)
print("dx %d dy %d buttons %s bad %d" % (dx, dy, btn, bad))
PY
if [ "$(cat "$OUT/mouse.txt")" == "dx 293 dy -27 buttons [0, 1, 2, 0] bad 0" ]; then echo "PASS mouse"
else echo "FAIL mouse: $(cat "$OUT/mouse.txt")"; fail=1; fi

vs_csp() {   # vs_csp NAME FRAME REF.png
    if python3 pngdiff.py "$OUT/$1/frame_$(printf %06d $2).png" "tests/ref/$3" > "$OUT/$1.cmp"; then echo "PASS ${1}_vs_csp"
    else echo "FAIL ${1}_vs_csp: $(cat "$OUT/$1.cmp")"; fail=1; fi
}
if [ -n "$GAMES" ]; then
    vs_csp sys11_menu 300 csp_sys11_menu_f900.png
    vs_csp yakyuukyou 1500 csp_yakyuukyou_title_f1800.png
    vs_csp sos22 1800 csp_sos22_f1800.png
    check basic_typing "$(hash_at "$OUT/basic_typing.csv" 1300)"
    check choplifter "$(hash_at "$OUT/choplifter.csv" 1500)"
    check smc_paint "$(hash_at "$OUT/smc_paint.csv" 1140)"
fi

exit $fail
