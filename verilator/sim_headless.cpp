// Headless SMC-777 simulation: run frames, type keys, capture PNG screenshots, frame hashes and traces.
//
// Same organisation and option names as SharpMZ2500_MiSTer's verilator/sim_headless.cpp, and the CSV columns
// line up with the Common Source Code Project's macOS CLI (smc777 --headless, docs/emulators.md) so runs can be
// diffed against it. Examples:
//
//   ./obj_dir_headless/Vtop --stop-at-frame 500 --screenshot 500
//   ./obj_dir_headless/Vtop --stop-at-frame 200 --frame-log out/frames.csv --trace-io out/io.csv --trace-to 20
//
// A frame ends when vertical blanking starts; frame 0 is the first full one after reset. Each PNG is the active
// picture as the core outputs it, 640x200 (--double-lines: 640x400, the CSP screenshot size).

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <map>
#include <deque>
#include <cstring>
#include <algorithm>
#include <sys/stat.h>

#include "Vtop.h"
#include "verilated.h"
#include "verilated_save.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "ps2_keys.h"

#ifdef SMC_FAST_SIM
static const double CLK_HZ = 32223800.0;   // clk_sys = the 32.2238 MHz master clock ('make fast')
#else
static const double CLK_HZ = 64447600.0;   // clk_sys = 2 x the master clock, as the MiSTer
#endif

struct TypeCmd { uint32_t frame; std::string text; bool burst; };

struct Options {
    uint32_t    stop_frame = 60;
    bool        quiet = false;
    std::set<uint32_t> screenshots;       // --screenshot N
    bool        dump_range = false;
    uint32_t    dump_from = 0, dump_to = 0;
    uint32_t    dump_every = 0;
    bool        double_lines = false;
    bool        border = false;           // --border: show the border colour around the picture
    std::string out_dir = "out";
    std::string frame_log;
    std::vector<TypeCmd> types;
    uint32_t    type_press = 4, type_release = 4;
    std::string trace_file;               // --trace-cpu
    std::string io_file;                  // --trace-io
    uint32_t    trace_from = 0, trace_to = 0xFFFFFFFF;
    std::string rom_file;                 // --rom: IPL ROM (SMCROM.DAT, 16 KiB)
    std::string kanji_file;               // --kanji: KANJIROM.DAT (144 KiB)
    std::string fdd[2];                   // --fdd / --fdd-b: D88 (.1dd) images in drives A and B
    bool        fdd_readonly = false;     // --fdd-readonly: never write back to the image files
    struct JoyEv { uint32_t frame; int port; uint32_t bits; };
    std::vector<JoyEv> joy;               // --joy FRAME:PORT:BITS
    bool        mouse = false;            // --mouse: joystick port 2 has the mouse (OSD option)
    struct MouseEv { uint32_t frame; int dx, dy, buttons; };
    std::vector<MouseEv> mouse_moves;     // --mouse-move FRAME:DX:DY[:BUTTONS]
    std::set<uint32_t> resets;            // --reset-at / --warm-reset-at FRAME
    std::set<uint32_t> warm_resets;
    std::string wav_file;                 // --wav
    std::string tape_file;                // --tape FILE[@SECONDS]: WAV played into the cassette input
    double      tape_start = 0;
    double      tape_speed = 1.0;         // --tape-speed F: play the WAV at F times its rate
    uint32_t    save_frame = 0;           // --save-state FRAME:FILE
    std::string save_file;
    std::string load_file;                // --load-state FILE
};

static void usage()
{
    fprintf(stderr,
"usage: Vtop [options]\n"
"  --stop-at-frame N      exit after frame N (default 60)\n"
"  --quiet                no progress on stderr\n"
"  --rom FILE             IPL ROM, 16 KiB (default ../bios/SMCROM.DAT); --kanji FILE kanji ROM (../bios/KANJIROM.DAT)\n"
"                         --rom-dir DIR: DIR/SMCROM.DAT and DIR/KANJIROM.DAT\n"
"  --fdd FILE             D88/.1dd image in drive A; --fdd-b FILE: drive B; --fdd-readonly: don't write to them\n"
"  --type FRAME:TEXT      type TEXT from FRAME (US PS/2 layout); \\n or {RETURN}, {ESC}, {F1}, {WAITn} ...\n"
"  --joy F:PORT:BITS[:H]  joystick PORT (0/1) from frame F: MiSTer bits (1 right 2 left 4 down 8 up 16/32 buttons)\n"
"                         or names (u/d/l/r/a/b/fire1/fire2, +-joined); optional :H releases after H frames\n"
"  --mouse                the mouse on joystick port 2 instead of joystick 2 (OSD option)\n"
"  --mouse-move F:DX:DY[:B]  move the mouse DX right, DY down from frame F (PS/2 packets, one per ms); buttons B\n"
"                         (1 left, 2 right) from then on\n"
"  --reset-at F           cold reset before frame F; --warm-reset-at F: warm reset (RESET key, port 1Ch bit 7)\n"
"  --type-burst F:TEXT    type TEXT with every press and release in frame F (1 ms apart: at most 15 keys)\n"
"  --type-rate P:R        frames per key press:release (default 4:4; P = 0: press and release 1 ms apart)\n"
"  --screenshot N         PNG of frame N (repeatable)\n"
"  --dump-frames A:B      PNG of every frame A..B\n"
"  --dump-every K         PNG of every Kth frame\n"
"  --double-lines         PNGs at 640x400 (each line twice, as CSP's screenshots)\n"
"  --border               show the border (port 23h) around the picture: 704x232 (OSD option)\n"
"  --out DIR              output directory (default ./out)\n"
"  --frame-log FILE       frame,fb_hash,cpu_cycles,pc per frame\n"
"  --trace-cpu FILE       frame,cpu_cycle,pc at each instruction fetch (M1)\n"
"  --trace-io FILE        frame,cpu_cycle,pc,kind,address,data for each IN/OUT (CSP CLI columns)\n"
"  --trace-from N         start tracing at frame N; --trace-to N stops after frame N\n"
"  --wav FILE             record the audio output (48 kHz, 16-bit stereo WAV)\n"
"  --tape FILE[@SEC]      play a WAV (8/16-bit PCM, first channel) into the cassette input from SEC seconds; the tape\n"
"                         runs while the motor relay is on (port 1Ch) and stops with it, as a recorder with remote\n"
"  --tape-speed F         play the tape at F times its speed (a WAV dumped from a fast deck: 0.95 plays it slower)\n"
"  --save-state N:FILE    save the machine state at the start of frame N; --load-state FILE resumes from it\n"
"fb_hash is FNV-1a 32 over the RGB888 bytes of the active picture (640x200).\n");
}

static void mkdir_p(const std::string &path)
{
    for (size_t i = 1; i <= path.size(); i++)
        if (i == path.size() || path[i] == '/') mkdir(path.substr(0, i).c_str(), 0777);
}

static uint32_t parse_num(const std::string &s) { return (uint32_t)std::stoul(s, nullptr, 0); }

static bool parse_joy_bits(const std::string &s, uint32_t &bits)
{
    if (s.empty()) return false;
    if (isdigit((unsigned char)s[0])) { bits = parse_num(s); return true; }
    bits = 0;
    size_t i = 0;
    while (i < s.size()) {
        size_t j = s.find_first_of("+,|", i);
        std::string tok = s.substr(i, j == std::string::npos ? std::string::npos : j - i);
        for (char &c : tok) c = (char)tolower((unsigned char)c);
        if (tok == "r" || tok == "right") bits |= 1;
        else if (tok == "l" || tok == "left") bits |= 2;
        else if (tok == "d" || tok == "down") bits |= 4;
        else if (tok == "u" || tok == "up") bits |= 8;
        else if (tok == "a" || tok == "1" || tok == "t" || tok == "trig1" || tok == "fire" || tok == "fire1" || tok == "btn1") bits |= 16;
        else if (tok == "b" || tok == "2" || tok == "user" || tok == "trig2" || tok == "fire2" || tok == "btn2") bits |= 32;
        else if (tok == "none" || tok == "off" || tok == "release") {}
        else return false;
        if (j == std::string::npos) break;
        i = j + 1;
    }
    return true;
}

static bool parse_args(int argc, char **argv, Options &o)
{
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs an argument\n", a.c_str()); exit(2); }
            return argv[++i];
        };
        auto pair = [&](const char *what, uint32_t &x, std::string &y) -> bool {
            std::string s = next();
            size_t c = s.find(':');
            if (c == std::string::npos) { fprintf(stderr, "%s wants %s\n", a.c_str(), what); return false; }
            x = parse_num(s.substr(0, c)); y = s.substr(c + 1);
            return true;
        };
        std::string rest;
        if (a == "--help" || a == "-h") { usage(); exit(0); }
        else if (a == "--headless") {}
        else if (a == "--stop-at-frame") o.stop_frame = parse_num(next());
        else if (a == "--quiet") o.quiet = true;
        else if (a == "--type") { uint32_t f; if (!pair("FRAME:TEXT", f, rest)) return false; o.types.push_back({f, rest, false}); }
        else if (a == "--type-burst") { uint32_t f; if (!pair("FRAME:TEXT", f, rest)) return false; o.types.push_back({f, rest, true}); }
        else if (a == "--type-rate") { if (!pair("P:R", o.type_press, rest)) return false; o.type_release = parse_num(rest); }
        else if (a == "--screenshot") o.screenshots.insert(parse_num(next()));
        else if (a == "--dump-frames") { if (!pair("A:B", o.dump_from, rest)) return false; o.dump_to = parse_num(rest); o.dump_range = true; }
        else if (a == "--dump-every") o.dump_every = parse_num(next());
        else if (a == "--double-lines") o.double_lines = true;
        else if (a == "--border") o.border = true;
        else if (a == "--out") o.out_dir = next();
        else if (a == "--frame-log") o.frame_log = next();
        else if (a == "--trace-cpu") o.trace_file = next();
        else if (a == "--trace-io") o.io_file = next();
        else if (a == "--trace-from") o.trace_from = parse_num(next());
        else if (a == "--trace-to") o.trace_to = parse_num(next());
        else if (a == "--rom") o.rom_file = next();
        else if (a == "--rom-dir") { std::string d = next(); o.rom_file = d + "/SMCROM.DAT"; o.kanji_file = d + "/KANJIROM.DAT"; }
        else if (a == "--kanji") o.kanji_file = next();
        else if (a == "--fdd") o.fdd[0] = next();
        else if (a == "--fdd-b") o.fdd[1] = next();
        else if (a == "--fdd-readonly") o.fdd_readonly = true;
        else if (a == "--reset-at") o.resets.insert(parse_num(next()));
        else if (a == "--warm-reset-at") o.warm_resets.insert(parse_num(next()));
        else if (a == "--joy") {
            std::string s = next();
            size_t c1 = s.find(':'), c2 = c1 == std::string::npos ? std::string::npos : s.find(':', c1 + 1);
            if (c1 == std::string::npos || c2 == std::string::npos) { fprintf(stderr, "--joy wants F:PORT:BITS[:HOLD]\n"); return false; }
            size_t c3 = s.find(':', c2 + 1);
            Options::JoyEv j{};
            j.frame = parse_num(s.substr(0, c1));
            j.port = (int)parse_num(s.substr(c1 + 1, c2 - c1 - 1));
            std::string bstr = s.substr(c2 + 1, c3 == std::string::npos ? std::string::npos : c3 - c2 - 1);
            if (!parse_joy_bits(bstr, j.bits)) { fprintf(stderr, "--joy: bad buttons '%s'\n", bstr.c_str()); return false; }
            o.joy.push_back(j);
            if (c3 != std::string::npos) {
                uint32_t hold = parse_num(s.substr(c3 + 1));
                if (hold > 0) o.joy.push_back({j.frame + hold, j.port, 0});
            }
        }
        else if (a == "--mouse") o.mouse = true;
        else if (a == "--mouse-move") {
            Options::MouseEv m{};
            int n = sscanf(next().c_str(), "%u:%d:%d:%i", &m.frame, &m.dx, &m.dy, &m.buttons);
            if (n < 3) { fprintf(stderr, "--mouse-move wants F:DX:DY[:BUTTONS]\n"); return false; }
            o.mouse = true;
            o.mouse_moves.push_back(m);
        }
        else if (a == "--wav") o.wav_file = next();
        else if (a == "--tape-speed") o.tape_speed = atof(next().c_str());
        else if (a == "--tape") {
            o.tape_file = next();
            size_t at = o.tape_file.rfind('@');
            if (at != std::string::npos) { o.tape_start = atof(o.tape_file.c_str() + at + 1); o.tape_file.resize(at); }
        }
        else if (a == "--save-state") { if (!pair("FRAME:FILE", o.save_frame, o.save_file)) return false; }
        else if (a == "--load-state") o.load_file = next();
        else if (a[0] == '+') {}   // Verilator plusargs
        else { fprintf(stderr, "unknown option %s (try --help)\n", a.c_str()); return false; }
    }
    return true;
}

struct Ps2Event { uint8_t code; bool ext; bool press; };

class Sim {
public:
    explicit Sim(const Options &o) : opt(o) { top = new Vtop; }
    ~Sim() { top->final(); delete top; }
    int run();

private:
    const Options &opt;
    Vtop     *top;
    uint64_t  cycle = 0, cpu_cycles = 0;
    uint32_t  frame = 0;
    int       exit_code = 0;
    bool      started = false;            // frames are counted from the first full one after reset

    std::vector<uint8_t> fb, line;
    int       fb_w = 0, fb_h = 0;
    bool      prev_hb = false, prev_vb = false;

    FILE     *flog = nullptr, *ftrace = nullptr, *fio = nullptr;
    bool      prev_m1 = true;
    uint16_t  last_pc = 0;

    std::multimap<uint32_t, Ps2Event> ps2_schedule;
    std::deque<Ps2Event> ps2_queue;
    uint64_t  ps2_next_ok = 0;
    bool      ps2_toggle = false;

    FILE     *fwav = nullptr;
    uint32_t  wav_samples = 0;
    double    wav_next = 0;
    bool      wav_on = false;             // from reset release (the IPL beeps before the first frame)

    // --tape: samples scaled to -1..1, position in samples; it advances only while the motor is on
    std::vector<float> tape;
    double    tape_rate = 0, tape_pos = 0;
    bool      tape_level = false, tape_motor = false;
    bool      load_tape();

    struct HState {
        uint64_t cycle, cpu_cycles, ps2_next_ok;
        uint32_t frame;
        uint8_t  prev_hb, prev_vb, prev_m1, ps2_toggle;
        uint16_t last_pc;
        int32_t  fb_w;
    };

    // hps_io style ps2_mouse packets: [24] toggles, [23:16] Y (up positive), [15:8] X, [5]/[4] Y/X sign, [1:0] buttons
    std::deque<uint32_t> mouse_queue;
    uint64_t mouse_next_ok = 0;
    int      mouse_buttons = 0;
    void     queue_mouse(int dx, int dy, int buttons);

    void clock();
    void end_frame();
    bool tracing() const { return started && frame >= opt.trace_from && frame <= opt.trace_to; }
    bool want_png(uint32_t f) const;
    void write_png(uint32_t f);
    void schedule_typing();
    bool load_rom();
    void ioctl_load(uint32_t base, const std::vector<uint8_t> &data, int index = 0);
    void save_state();
    bool load_state();
    void wav_close();
    int  finish();
    void reset_machine(bool warm);

    // hps_io sd_* block interface for the floppy slots: 512-byte blocks, one byte per clock
    FILE     *fdd[2] = {nullptr, nullptr};
    uint64_t  fdd_size[2] = {0, 0};
    enum { SD_IDLE, SD_READ, SD_READ_END, SD_WRITE } sd_state = SD_IDLE;
    int       sd_slot = 0, sd_idx = 0;
    uint32_t  sd_lba = 0;
    uint8_t   sd_data[512];
    void      sd_step();
    bool      open_fdd(int k);
    bool      mount_fdd(int k);
    bool      save_pending = false;
};

void Sim::sd_step()
{
    auto req_rd = [&](int k) -> bool { return (top->fdd_rd >> k) & 1; };
    auto req_wr = [&](int k) -> bool { return (top->fdd_wr >> k) & 1; };
    auto ack    = [&](int k, int v) { top->fdd_ack = v ? (1 << k) : 0; };

    top->sd_buff_wr = 0;
    switch (sd_state) {
    case SD_IDLE:
        for (int k = 0; k < 2; k++) {
            if (!fdd[k] || !(req_rd(k) || req_wr(k))) continue;
            sd_slot = k;
            sd_lba = k ? top->fdd_lba1 : top->fdd_lba0;
            sd_idx = 0;
            ack(k, 1);
            if (req_rd(k)) {
                memset(sd_data, 0, sizeof(sd_data));
                uint64_t off = (uint64_t)sd_lba * 512;
                if (off < fdd_size[k]) {
                    fseeko(fdd[k], (off_t)off, SEEK_SET);
                    size_t n = fread(sd_data, 1, (size_t)std::min<uint64_t>(512, fdd_size[k] - off), fdd[k]);
                    (void)n;
                }
                sd_state = SD_READ;
            }
            else sd_state = SD_WRITE;
            break;
        }
        break;
    case SD_READ:
        top->sd_buff_addr = sd_idx;
        top->sd_buff_dout = sd_data[sd_idx];
        top->sd_buff_wr = 1;
        if (++sd_idx == 512) sd_state = SD_READ_END;
        break;
    case SD_READ_END:
        ack(sd_slot, 0);
        sd_state = SD_IDLE;
        break;
    case SD_WRITE:
        // sd_buff_din is registered: it holds the byte addressed on the previous clock.
        if (sd_idx > 0) sd_data[sd_idx - 1] = sd_slot ? top->fdd_buff_din1 : top->fdd_buff_din0;
        if (sd_idx < 512) top->sd_buff_addr = sd_idx++;
        else {
            uint64_t off = (uint64_t)sd_lba * 512;
            if (!opt.fdd_readonly && off < fdd_size[sd_slot]) {
                fseeko(fdd[sd_slot], (off_t)off, SEEK_SET);
                fwrite(sd_data, 1, (size_t)std::min<uint64_t>(512, fdd_size[sd_slot] - off), fdd[sd_slot]);
                fflush(fdd[sd_slot]);
            }
            ack(sd_slot, 0);
            sd_state = SD_IDLE;
        }
        break;
    }
}

bool Sim::open_fdd(int k)
{
    fdd[k] = fopen(opt.fdd[k].c_str(), opt.fdd_readonly ? "rb" : "r+b");
    if (!fdd[k]) { fprintf(stderr, "cannot open disk image %s\n", opt.fdd[k].c_str()); return false; }
    fseeko(fdd[k], 0, SEEK_END);
    fdd_size[k] = (uint64_t)ftello(fdd[k]);
    return true;
}

// As hps_io: img_size on a shared bus, one img_mounted strobe per slot.
bool Sim::mount_fdd(int k)
{
    if (!open_fdd(k)) return false;
    top->img_size = fdd_size[k];
    top->img_readonly = opt.fdd_readonly;
    top->img_mounted = 1 << k;
    clock();
    top->img_mounted = 0;
    for (int i = 0; i < 4; i++) clock();
    if (!opt.quiet) fprintf(stderr, "[sim] drive %c: '%s', %llu bytes\n", 'A' + k, opt.fdd[k].c_str(), (unsigned long long)fdd_size[k]);
    return true;
}

// The OSD reset: a few hundred clocks with reset held (and reset_warm for the RESET key)
void Sim::reset_machine(bool warm)
{
    top->reset_warm = warm;
    top->reset = 1;
    for (int i = 0; i < 64; i++) clock();
    top->reset = 0;
    if (!opt.quiet) fprintf(stderr, "[sim] %s reset before frame %u\n", warm ? "warm" : "cold", frame);
}

static bool read_file(const std::string &name, std::vector<uint8_t> &out)
{
    FILE *f = fopen(name.c_str(), "rb");
    if (!f) return false;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.insert(out.end(), buf, buf + n);
    fclose(f);
    return true;
}

// hps_io style download: one byte every 4 clocks, machine held in reset by ioctl_download.
void Sim::ioctl_load(uint32_t base, const std::vector<uint8_t> &data, int index)
{
    top->ioctl_index = index;
    top->ioctl_download = 1;
    for (size_t i = 0; i < data.size(); i++) {
        top->ioctl_addr = base + (uint32_t)i;
        top->ioctl_dout = data[i];
        top->ioctl_wr = 1;
        clock();
        top->ioctl_wr = 0;
        clock(); clock(); clock();
        while (top->ioctl_wait) clock();
    }
    top->ioctl_download = 0;
}

bool Sim::load_rom()
{
    std::string name = opt.rom_file.empty() ? "../bios/SMCROM.DAT" : opt.rom_file;
    std::vector<uint8_t> d;
    if (!read_file(name, d)) { fprintf(stderr, "cannot read IPL ROM %s\n", name.c_str()); return false; }
    if (d.size() != 0x4000) fprintf(stderr, "warning: %s is %zu bytes, expected 16384\n", name.c_str(), d.size());
    d.resize(0x4000, 0xFF);
    std::string kname = opt.kanji_file.empty() ? "../bios/KANJIROM.DAT" : opt.kanji_file;
    std::vector<uint8_t> k;
    if (read_file(kname, k)) { k.resize(0x23400, 0xFF); d.insert(d.end(), k.begin(), k.end()); }
    else fprintf(stderr, "warning: no kanji ROM %s\n", kname.c_str());
    ioctl_load(0, d);   // boot.rom: IPL at 0, kanji at 4000h
    if (!opt.quiet) fprintf(stderr, "[sim] boot.rom: IPL '%s'%s\n", name.c_str(), k.empty() ? "" : " + kanji ROM");
    return true;
}

static void wav_header(FILE *f, uint32_t samples)
{
    uint32_t data = samples * 4, riff = 36 + data, fmt_len = 16, rate = 48000, brate = 48000 * 4;
    uint16_t pcm = 1, ch = 2, align = 4, bits = 16;
    fseek(f, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmt_len, 4, 1, f); fwrite(&pcm, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f);
    fwrite(&brate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
}

void Sim::wav_close()
{
    if (!fwav) return;
    wav_header(fwav, wav_samples);
    fclose(fwav);
    fwav = nullptr;
}

void Sim::save_state()
{
    if (sd_state != SD_IDLE) { save_pending = true; return; }   // not in the middle of a block transfer
    VerilatedSave os;
    os.open(opt.save_file.c_str());
    os << *top;
    HState h = {cycle, cpu_cycles, ps2_next_ok, frame, prev_hb, prev_vb, prev_m1, ps2_toggle, last_pc, fb_w};
    os.write(&h, sizeof(h));
    os.close();
    if (!opt.quiet) fprintf(stderr, "[sim] state saved at frame %u to %s\n", frame, opt.save_file.c_str());
}

bool Sim::load_state()
{
    VerilatedRestore is;
    is.open(opt.load_file.c_str());
    if (!is.isOpen()) { fprintf(stderr, "cannot read %s\n", opt.load_file.c_str()); return false; }
    is >> *top;
    HState h;
    is.read(&h, sizeof(h));
    is.close();
    cycle = h.cycle; cpu_cycles = h.cpu_cycles; ps2_next_ok = h.ps2_next_ok; frame = h.frame;
    prev_hb = h.prev_hb; prev_vb = h.prev_vb; prev_m1 = h.prev_m1; ps2_toggle = h.ps2_toggle;
    last_pc = h.last_pc; fb_w = h.fb_w;
    for (int k = 0; k < 2; k++)
        if (!opt.fdd[k].empty() && !open_fdd(k)) return false;
    if (!opt.quiet) fprintf(stderr, "[sim] state loaded from %s, frame %u\n", opt.load_file.c_str(), frame);
    return true;
}

void Sim::clock()
{
    // Sample what the video pipeline sees at this rising edge: MiSTer's video_mixer latches RGB on the
    // clk_sys edge where CE_PIXEL is high.
    top->clk_sys = 0;
    top->eval();
    if (top->ce_pix) {
        bool hb = top->VGA_HB, vb = top->VGA_VB;
        if (!hb && !vb) {
            line.push_back(top->VGA_R);
            line.push_back(top->VGA_G);
            line.push_back(top->VGA_B);
        }
        if (hb && !prev_hb && !line.empty()) {
            int w = (int)line.size() / 3;
            if (fb_h == 0) fb_w = w;
            line.resize((size_t)fb_w * 3, 0);
            fb.insert(fb.end(), line.begin(), line.end());
            fb_h++;
            line.clear();
        }
        prev_hb = hb;
        if (vb && !prev_vb) end_frame();
        prev_vb = vb;
    }

    top->clk_sys = 1;
    top->eval();
    cycle++;

    if (top->cpu_ce) cpu_cycles++;
    if (!tape.empty()) {
        if (top->tape_motor != tape_motor) {
            tape_motor = top->tape_motor;
            if (!opt.quiet) fprintf(stderr, "[sim] frame %u: tape motor %s at %.2f s\n", frame, tape_motor ? "on" : "off", tape_pos / tape_rate);
        }
        if (tape_motor && tape_pos < tape.size() - 1) {
            float v = tape[(size_t)tape_pos];
            if (v > 0.05f) tape_level = true;            // a little hysteresis, as a comparator on line-in
            else if (v < -0.05f) tape_level = false;
            tape_pos += tape_rate * opt.tape_speed / CLK_HZ;
        }
        top->tape_in = tape_level;
    }
    sd_step();
    if (save_pending && sd_state == SD_IDLE) { save_pending = false; save_state(); }
    if (fwav && wav_on && cycle >= wav_next) {
        int16_t lr[2] = {(int16_t)top->AUDIO_L, (int16_t)top->AUDIO_R};   // signed, as the core's AUDIO_S = 1
        fwrite(lr, 2, 2, fwav);
        wav_samples++;
        wav_next += CLK_HZ / 48000.0;
    }
    bool m1 = top->cpu_m1_n;
    if (!m1 && prev_m1) {
        last_pc = top->cpu_addr;
        if (ftrace && tracing()) fprintf(ftrace, "%u,%llu,%04x\n", frame, (unsigned long long)cpu_cycles, last_pc);
    }
    prev_m1 = m1;
    if (fio && tracing() && (top->dbg_io_wr || top->dbg_io_rd))
        fprintf(fio, "%u,%llu,%04x,%c,%04x,%02x\n", frame, (unsigned long long)cpu_cycles, last_pc,
                top->dbg_io_wr ? 'W' : 'R', top->dbg_io_port, top->dbg_io_data);

    // hps_io style ps2_key: bit 10 toggles per event, 9 = pressed, 8 = extended. One event per ~1 ms.
    if (!ps2_queue.empty() && cycle >= ps2_next_ok) {
        Ps2Event e = ps2_queue.front();
        ps2_queue.pop_front();
        ps2_toggle = !ps2_toggle;
        top->ps2_key = (uint16_t)((ps2_toggle << 10) | (e.press << 9) | (e.ext << 8) | e.code);
        ps2_next_ok = cycle + (uint64_t)(CLK_HZ / 1000);
    }
    if (!mouse_queue.empty() && cycle >= mouse_next_ok) {
        uint32_t p = mouse_queue.front();
        mouse_queue.pop_front();
        top->ps2_mouse = (((top->ps2_mouse >> 24) & 1) ^ 1) << 24 | p;
        mouse_next_ok = cycle + (uint64_t)(CLK_HZ / 1000);
    }
}

void Sim::queue_mouse(int dx, int dy, int buttons)
{
    mouse_buttons = buttons;
    do {
        int x = dx > 100 ? 100 : dx < -100 ? -100 : dx;
        int y = dy > 100 ? 100 : dy < -100 ? -100 : dy;
        dx -= x; dy -= y;
        int py = -y;   // PS/2: up is positive
        mouse_queue.push_back((uint32_t)((py & 0xff) << 16 | (x & 0xff) << 8 | (py < 0) << 5 | (x < 0) << 4 | 8 | (buttons & 3)));
    } while (dx || dy);
}

void Sim::end_frame()
{
    if (!started) { fb.clear(); fb_h = 0; line.clear(); return; }
    uint32_t h = 2166136261u;
    for (uint8_t b : fb) { h ^= b; h *= 16777619u; }
    if (flog) fprintf(flog, "%u,%08x,%llu,%04x\n", frame, h, (unsigned long long)cpu_cycles, last_pc);
    if (want_png(frame)) write_png(frame);
    if (!opt.quiet && frame % 50 == 0)
        fprintf(stderr, "[sim] frame %u  %.3fs emulated  %dx%d  pc %04x  hash %08x\n",
                frame, cycle / CLK_HZ, fb_w, fb_h, last_pc, h);
    fb.clear(); fb_h = 0; line.clear();
    frame++;
    if (!opt.save_file.empty() && frame == opt.save_frame) save_state();
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);
    for (auto &j : opt.joy) if (j.frame == frame) { if (j.port) top->joy1 = j.bits; else top->joy0 = j.bits; }
    for (auto &m : opt.mouse_moves) if (m.frame == frame) queue_mouse(m.dx, m.dy, m.buttons);
    if (opt.resets.count(frame)) reset_machine(false);
    if (opt.warm_resets.count(frame)) reset_machine(true);
}

bool Sim::want_png(uint32_t f) const
{
    if (opt.screenshots.count(f)) return true;
    if (opt.dump_range && f >= opt.dump_from && f <= opt.dump_to) return true;
    if (opt.dump_every && f % opt.dump_every == 0) return true;
    return false;
}

void Sim::write_png(uint32_t f)
{
    if (fb_w == 0 || fb_h == 0) { fprintf(stderr, "[sim] frame %u: no picture (display not enabled)\n", f); return; }
    char name[1024];
    snprintf(name, sizeof(name), "%s/frame_%06u.png", opt.out_dir.c_str(), f);
    const std::vector<uint8_t> *img = &fb;
    std::vector<uint8_t> doubled;
    int h = fb_h;
    if (opt.double_lines) {
        for (int y = 0; y < fb_h; y++)
            for (int k = 0; k < 2; k++)
                doubled.insert(doubled.end(), fb.begin() + (size_t)y * fb_w * 3, fb.begin() + (size_t)(y + 1) * fb_w * 3);
        img = &doubled;
        h *= 2;
    }
    if (!stbi_write_png(name, fb_w, h, 3, img->data(), fb_w * 3)) {
        fprintf(stderr, "cannot write %s\n", name);
        exit_code = 3;
    }
    else if (!opt.quiet) fprintf(stderr, "[sim] wrote %s (%dx%d)\n", name, fb_w, h);
}

void Sim::schedule_typing()
{
    for (auto &t : opt.types) {
        uint32_t f = t.frame;
        uint32_t press = t.burst ? 0 : opt.type_press, release = t.burst ? 0 : opt.type_release;
        const std::string &s = t.text;
        for (size_t i = 0; i < s.size(); i++) {
            Ps2Key k;
            bool ok = false;
            if (s[i] == '\\' && i + 1 < s.size()) {
                char c = s[++i];
                ok = ps2_from_ascii(c == 'n' || c == 'r' ? '\n' : c, k);
            } else if (s[i] == '{') {
                size_t e = s.find('}', i);
                std::string name = s.substr(i + 1, e - i - 1);
                i = e;
                if (name.rfind("WAIT", 0) == 0) { f += parse_num(name.substr(4)); continue; }
                if (name[0] == '+' || name[0] == '-') {   // {+NAME} press only, {-NAME} release only (chords)
                    if (!ps2_from_name(name.substr(1), k)) { fprintf(stderr, "--type: unknown key {%s}\n", name.c_str()); continue; }
                    ps2_schedule.insert({f, {k.code, k.extended, name[0] == '+'}});
                    f += 1;
                    continue;
                }
                ok = ps2_from_name(name, k);
                if (!ok) fprintf(stderr, "--type: unknown key {%s}\n", name.c_str());
            } else {
                ok = ps2_from_ascii(s[i], k);
                if (!ok) fprintf(stderr, "--type: no key for '%c'\n", s[i]);
            }
            if (!ok) continue;
            if (k.shift) ps2_schedule.insert({f, {PS2_LSHIFT, false, true}});
            ps2_schedule.insert({f, {k.code, k.extended, true}});
            ps2_schedule.insert({f + press, {k.code, k.extended, false}});
            if (k.shift) ps2_schedule.insert({f + press, {PS2_LSHIFT, false, false}});
            f += press + release;
        }
    }
}

bool Sim::load_tape()
{
    FILE *f = fopen(opt.tape_file.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot read %s\n", opt.tape_file.c_str()); return false; }
    std::vector<uint8_t> d;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
    fclose(f);
    auto u16 = [&](size_t i) { return (uint32_t)d[i] | (uint32_t)d[i + 1] << 8; };
    auto u32 = [&](size_t i) { return u16(i) | u16(i + 2) << 16; };
    if (d.size() < 12 || memcmp(&d[0], "RIFF", 4) || memcmp(&d[8], "WAVE", 4)) { fprintf(stderr, "%s: not a WAV file\n", opt.tape_file.c_str()); return false; }
    uint32_t ch = 0, bits = 0;
    for (size_t p = 12; p + 8 <= d.size(); ) {
        uint32_t len = u32(p + 4);
        if (!memcmp(&d[p], "fmt ", 4)) { ch = u16(p + 10); tape_rate = u32(p + 12); bits = u16(p + 22); }
        else if (!memcmp(&d[p], "data", 4)) {
            if (!ch || (bits != 8 && bits != 16)) { fprintf(stderr, "%s: only 8/16-bit PCM\n", opt.tape_file.c_str()); return false; }
            size_t step = ch * bits / 8, end = std::min(d.size(), p + 8 + (size_t)len);
            for (size_t i = p + 8; i + step <= end; i += step)
                tape.push_back(bits == 8 ? (d[i] - 128) / 128.0f : (int16_t)u16(i) / 32768.0f);
            break;
        }
        p += 8 + len + (len & 1);
    }
    if (tape.empty()) { fprintf(stderr, "%s: no samples\n", opt.tape_file.c_str()); return false; }
    tape_pos = opt.tape_start * tape_rate;
    if (!opt.quiet) fprintf(stderr, "[sim] tape %s: %.1f s at %.0f Hz, from %.2f s\n", opt.tape_file.c_str(), tape.size() / tape_rate, tape_rate, opt.tape_start);
    return true;
}

int Sim::run()
{
    mkdir_p(opt.out_dir);
    if (!opt.frame_log.empty()) {
        if (!(flog = fopen(opt.frame_log.c_str(), "w"))) { fprintf(stderr, "cannot write %s\n", opt.frame_log.c_str()); return 2; }
        fprintf(flog, "frame,fb_hash,cpu_cycles,pc\n");
    }
    if (!opt.trace_file.empty()) {
        if (!(ftrace = fopen(opt.trace_file.c_str(), "w"))) { fprintf(stderr, "cannot write %s\n", opt.trace_file.c_str()); return 2; }
        fprintf(ftrace, "frame,cpu_cycle,pc\n");
    }
    if (!opt.io_file.empty()) {
        if (!(fio = fopen(opt.io_file.c_str(), "w"))) { fprintf(stderr, "cannot write %s\n", opt.io_file.c_str()); return 2; }
        fprintf(fio, "frame,cpu_cycle,pc,kind,address,data\n");
    }
    if (!opt.wav_file.empty()) {
        if (!(fwav = fopen(opt.wav_file.c_str(), "wb"))) { fprintf(stderr, "cannot write %s\n", opt.wav_file.c_str()); return 2; }
        wav_header(fwav, 0);
    }

    if (!opt.tape_file.empty() && !load_tape()) return 2;
    top->tape_in = 0;
    if (!opt.load_file.empty()) {
        if (!load_state()) return 2;
        top->border_en = opt.border;
        top->mouse_en = opt.mouse;
        started = true;
        wav_on = true;
        wav_next = (double)cycle;
        schedule_typing();
        auto range = ps2_schedule.equal_range(frame);
        for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);
        for (auto &j : opt.joy) if (j.frame == frame) { if (j.port) top->joy1 = j.bits; else top->joy0 = j.bits; }
        for (auto &m : opt.mouse_moves) if (m.frame == frame) queue_mouse(m.dx, m.dy, m.buttons);
        while (frame <= opt.stop_frame && !Verilated::gotFinish()) clock();
        return finish();
    }

    top->reset = 1;
    top->reset_warm = 0;
    top->border_en = opt.border;
    top->joy0 = 0; top->joy1 = 0;
    top->mouse_en = opt.mouse;
    top->ps2_mouse = 0;
    top->ps2_key = 0;
    top->ioctl_download = 0; top->ioctl_wr = 0;
    for (int i = 0; i < 256; i++) clock();
    // As on the MiSTer: Main holds the core in reset while it sends boot.rom, then releases it.
    if (!load_rom()) return 2;
    for (int i = 0; i < 256; i++) clock();
    top->reset = 0;
    wav_on = true;
    wav_next = (double)cycle;
    for (int k = 0; k < 2; k++)
        if (!opt.fdd[k].empty() && !mount_fdd(k)) return 2;

    // The CRTC is unprogrammed until the IPL sets it up: frame 0 is the first full frame after that.
    // Give up if no vertical blanking appears within ~2 s of emulated time.
    const uint64_t limit = cycle + (uint64_t)(2 * CLK_HZ);
    while (!top->VGA_VB && cycle < limit) clock();
    while (top->VGA_VB && cycle < limit) clock();
    if (cycle >= limit) {
        fprintf(stderr, "[sim] no video timing after 2 s (CRTC never programmed?), pc %04x\n", last_pc);
        exit_code = 4;
        return finish();
    }
    frame = 0; cpu_cycles = 0; fb.clear(); fb_h = 0; line.clear();
    started = true;

    schedule_typing();
    auto range = ps2_schedule.equal_range(0);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);
    for (auto &j : opt.joy) if (j.frame == 0) { if (j.port) top->joy1 = j.bits; else top->joy0 = j.bits; }
    for (auto &m : opt.mouse_moves) if (m.frame == 0) queue_mouse(m.dx, m.dy, m.buttons);

    while (frame <= opt.stop_frame && !Verilated::gotFinish()) clock();
    return finish();
}

int Sim::finish()
{
    wav_close();
    if (flog) fclose(flog);
    if (ftrace) fclose(ftrace);
    if (fio) fclose(fio);
    if (!opt.quiet) fprintf(stderr, "[sim] done: %u frames, %llu clk_sys cycles, %llu CPU cycles\n",
                            frame, (unsigned long long)cycle, (unsigned long long)cpu_cycles);
    return exit_code;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Options opt;
    if (!parse_args(argc, argv, opt)) return 2;
    Sim sim(opt);
    return sim.run();
}
