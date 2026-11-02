`timescale 1ns/1ns
//
// Simulation top for the SMC-777 core: the machine (rtl/smc777.sv) with its ports made visible to the C++
// harness (sim_headless.cpp). It stands in for smc777.sv (the MiSTer top); the harness plays hps_io
// (ps2_key and the ioctl ROM download).
//
module top(
   input         clk_sys /*verilator public_flat*/,
   input         reset /*verilator public_flat*/,

   output [7:0]  VGA_R /*verilator public_flat*/,
   output [7:0]  VGA_G /*verilator public_flat*/,
   output [7:0]  VGA_B /*verilator public_flat*/,
   output        VGA_HS /*verilator public_flat*/,
   output        VGA_VS /*verilator public_flat*/,
   output        VGA_HB /*verilator public_flat*/,
   output        VGA_VB /*verilator public_flat*/,
   output        ce_pix /*verilator public_flat*/,

   output [15:0] AUDIO_L /*verilator public_flat*/,
   output [15:0] AUDIO_R /*verilator public_flat*/,

   input  [10:0] ps2_key,
   input   [5:0] joy0,
   input   [5:0] joy1,
   input         mouse_en,
   input  [24:0] ps2_mouse,
   input         reset_warm,
   input         border_en,
   input         tape_in,             // line-in (--tape), when no tape image is mounted
   output        tape_motor,
   input         tape_turbo_req,      // OSD Tape speed 8x
   input         tape_rewind,
   input         tape_overlay_en,
   output        tape_loaded /*verilator public_flat*/,
   output        tape_turbo /*verilator public_flat*/,
   output        tape_underflow /*verilator public_flat*/,
   output        tape_bad /*verilator public_flat*/,
   output [31:0] tape_lba,
   output        tape_rd,
   input         tape_ack,

   // floppy image slots (hps_io sd_* bus), flattened for the C++ harness
   input   [2:0] img_mounted,          // 2: the tape
   input         img_readonly,
   input  [63:0] img_size,
   output [31:0] fdd_lba0,
   output [31:0] fdd_lba1,
   output  [1:0] fdd_rd,
   output  [1:0] fdd_wr,
   input   [1:0] fdd_ack,
   input   [8:0] sd_buff_addr,
   input   [7:0] sd_buff_dout,
   output  [7:0] fdd_buff_din0,
   output  [7:0] fdd_buff_din1,
   input         sd_buff_wr,
   output        fdd_busy /*verilator public_flat*/,

   input         ioctl_download,
   input   [7:0] ioctl_index,
   input         ioctl_wr,
   input  [24:0] ioctl_addr,
   input   [7:0] ioctl_dout,
   output        ioctl_wait,

   output [15:0] cpu_addr /*verilator public_flat*/,
   output        cpu_ce /*verilator public_flat*/,
   output        cpu_m1_n /*verilator public_flat*/,
   output        dbg_io_wr /*verilator public_flat*/,
   output        dbg_io_rd /*verilator public_flat*/,
   output [15:0] dbg_io_port /*verilator public_flat*/,
   output [7:0]  dbg_io_data /*verilator public_flat*/
);

assign ioctl_wait = 1'b0;

wire [31:0] fdd_lba[2];
wire  [7:0] fdd_buff_din[2];
assign fdd_lba0 = fdd_lba[0];
assign fdd_lba1 = fdd_lba[1];
assign fdd_buff_din0 = fdd_buff_din[0];
assign fdd_buff_din1 = fdd_buff_din[1];

`ifdef SMC_FAST_SIM
localparam CLK_MUL = 1, CLK_HZ = 32223800, TURBO = 4;   // 'make fast': clk_sys = the 32.2238 MHz master clock
`else
localparam CLK_MUL = 2, CLK_HZ = 64447600, TURBO = 8;   // as the MiSTer: clk_sys = 64.4476 MHz
`endif

wire        tape_level, tape_playing, cpu_turbo;
wire [17:0] tape_rate;
wire [31:0] tape_pos, tape_len;
wire  [7:0] R, G, B;
wire        HB, VB;
assign VGA_HB = HB;
assign VGA_VB = VB;

smc777_tape #(.CLK_HZ(CLK_HZ), .TURBO(TURBO)) smc777_tape
(
   .clk(clk_sys), .rewind(tape_rewind), .motor(tape_motor), .turbo_req(tape_turbo_req),
   .img_mounted(img_mounted[2]), .img_size(img_size),
   .sd_lba(tape_lba), .sd_rd(tape_rd), .sd_ack(tape_ack),
   .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
   .level(tape_level), .loaded(tape_loaded), .playing(tape_playing), .turbo(tape_turbo),
   .ready(), .bad(tape_bad), .underflow(tape_underflow),
   .rate(tape_rate), .position(tape_pos), .length(tape_len)
);

smc777_tape_overlay #(.TURBO(TURBO)) smc777_tape_overlay
(
   .clk(clk_sys),
   .loaded(tape_loaded), .playing(tape_playing), .fast(tape_turbo), .underflow(tape_underflow),
   .rate(tape_rate), .position(tape_pos), .length(tape_len),
   .enable(tape_overlay_en), .ce_pix(ce_pix), .hblank(HB), .vblank(VB),
   .r_in(R), .g_in(G), .b_in(B), .r_out(VGA_R), .g_out(VGA_G), .b_out(VGA_B)
);

smc777 #(.CLK_MUL(CLK_MUL)) smc777
(
   .clk_sys(clk_sys),
   .reset(reset),
   .reset_warm(reset_warm),
   .border_en(border_en),
   .ps2_key(ps2_key),
   .joy0(joy0), .joy1(joy1),
   .mouse_en(mouse_en), .ps2_mouse(ps2_mouse),

   .ioctl_download(ioctl_download),
   .ioctl_index(ioctl_index),
   .ioctl_wr(ioctl_wr),
   .ioctl_addr(ioctl_addr),
   .ioctl_dout(ioctl_dout),

   .ce_pix(ce_pix),
   .R(R), .G(G), .B(B),
   .HSync(VGA_HS), .VSync(VGA_VS),
   .HBlank(HB), .VBlank(VB),

   .audio_l(AUDIO_L),
   .audio_r(AUDIO_R),

   .tape_in(tape_loaded ? tape_level : tape_in), .tape_motor(tape_motor), .tape_out(),
   .cpu_turbo(tape_turbo), .tape_audio(1'b1),

   .img_mounted(img_mounted[1:0]), .img_readonly(img_readonly), .img_size(img_size),
   .sd_lba(fdd_lba), .sd_rd(fdd_rd), .sd_wr(fdd_wr), .sd_ack(fdd_ack),
   .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(fdd_buff_din), .sd_buff_wr(sd_buff_wr),
   .fdd_busy(fdd_busy),
   .caps_led(), .kana_led(),

   .cpu_addr(cpu_addr),
   .cpu_ce(cpu_ce),
   .cpu_m1_n(cpu_m1_n),
   .dbg_io_wr(dbg_io_wr),
   .dbg_io_rd(dbg_io_rd),
   .dbg_io_port(dbg_io_port),
   .dbg_io_data(dbg_io_data)
);

endmodule
