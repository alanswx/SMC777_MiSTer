//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;                       // signed
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = cfg[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

// boot.rom (index 0, loaded by Main from games/SonySMC777/boot.rom): SMCROM.DAT (16 KiB IPL) followed by KANJIROM.DAT
// (144 KiB). Floppies: D88 images (the usual ".1dd" SMC-777 images are D88; rename or pick "all files").
// Tape: a WAV (rtl/smc777_tape.sv), not remembered, rewound at every mount.
// Layout: ~/dev2/osd-standard.md and tape-standard.md. P1 Machine, P2 Video, P3 Input, P4 Audio. Video settings
// take effect at the next reset (cfg); media, Input, the tape rows and the buttons act at once. The status bits are
// those of the earlier flat menu, so saved settings carry over.
`include "build_id.v"
localparam CONF_STR = {
	"SonySMC777;;",
	"-;",
	"S0,D881DDD77,Pri. Drive A;",
	"S1,D881DDD77,Drive B;",
	"S2,WAV,Tape;",
	"F0,ROM,Load ROM;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P4,Audio;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	// 8x: while the deck plays, the CPU and the tape run eight times faster
	"P1O[7],Tape speed,8x,Normal;",
	"P1-;",
	"P1T[10],Rewind tape;",
	"P1T[1],RESET key (warm);",

	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[4:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"P2O[5],Border,Off,On;",
	"P2O[8],Tape overlay,On,Off;",
	"P2O[11],Interlace text,SMC-777,SMC-70;",

	"P3O[6],Port 2,Joystick,Mouse;",

	"P4O[9],Tape audio,Off,On;",

	// shown for 2 s at a tape mount (Main's Info box: lines up to 30 columns, no commas): 1 ready, 2 rejected,
	// 3 ready with no disk in drive A, where BASIC (System 1.1J) has to come from
	"I,Tape ready (rewound)\nIn System 1.1J BASIC type\nCLOAD \"NAME\" or CLOAD \"\",",
	"Tape format not supported,",
	"Tape ready (rewound)\nBoot System 1.1J on drive A\nthen in BASIC type CLOAD \"\";",
	"J1,Trigger 1,Trigger 2;",
	"jn,A,B;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;
wire [31:0] joystick_0, joystick_1;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;

// Image slots S0/S1 (floppy drives A and B) and S2 (tape), 512-byte blocks
wire  [2:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba[3];
wire  [2:0] sd_rd, sd_wr, sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[3];
wire        sd_buff_wr;
wire  [5:0] sd_blk_cnt[3] = '{6'd0, 6'd0, 6'd0};

reg         info_req;
reg   [7:0] info;
wire        pending;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(3)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, pending}),
	.info_req(info_req),
	.info(info),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

// clk_sys = 2 x the SMC-777's 32.2238 MHz master clock (the PLL makes 64.4444 MHz from 50 MHz), so the
// 16.11 MHz dots have 4 clocks each for the scandoubler. rtl/smc777.sv CLK_MUL = 2.
wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

wire warm  = status[1];
wire reset = RESET | status[0] | buttons[1] | warm | ~pll_locked;

// the settings the machine runs with, taken from the OSD at every reset (osd-standard.md rule 1): the Video page
reg [127:0] cfg;
always @(posedge clk_sys) if (reset) cfg <= status;
assign pending = {status[5:3], status[122:121]} != {cfg[5:3], cfg[122:121]};

///////////////////////   CASSETTE   ///////////////////////////////

// A WAV on S2 (rtl/smc777_tape.sv), else line-in through the ADC (as the other MiSTer computer cores). The cassette
// monitor (OSD Tape audio) is in the machine's sound.
wire tape_adc, tape_adc_act;
ltc2308_tape #(.CLK_RATE(64444444)) ltc2308_tape
(
	.reset(reset),
	.clk(clk_sys),
	.ADC_BUS(ADC_BUS),
	.dout(tape_adc),
	.active(tape_adc_act),
	.adc_sync(),
	.adc_data()
);

wire        tape_motor, tape_level, tape_loaded, tape_playing, tape_turbo, tape_ready, tape_bad, tape_underflow;
wire [17:0] tape_rate;
wire [31:0] tape_pos, tape_len;
reg         rewind_d;
always @(posedge clk_sys) rewind_d <= status[10];

smc777_tape #(.CLK_HZ(64444444), .TURBO(8)) smc777_tape
(
	.clk(clk_sys),
	.rewind(status[10] & ~rewind_d),
	.motor(tape_motor),
	.turbo_req(~status[7]),
	.img_mounted(img_mounted[2]),
	.img_size(img_size),
	.sd_lba(sd_lba[2]),
	.sd_rd(sd_rd[2]),
	.sd_ack(sd_ack[2]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.level(tape_level),
	.loaded(tape_loaded),
	.playing(tape_playing),
	.turbo(tape_turbo),
	.ready(tape_ready),
	.bad(tape_bad),
	.underflow(tape_underflow),
	.rate(tape_rate),
	.position(tape_pos),
	.length(tape_len)
);
assign sd_wr[2] = 1'b0;
assign sd_buff_din[2] = 8'd0;

wire [31:0] fdd_lba[2];
wire  [1:0] fdd_rd, fdd_wr;
wire  [7:0] fdd_buff_din[2];
assign sd_lba[0] = fdd_lba[0];
assign sd_lba[1] = fdd_lba[1];
assign sd_rd[1:0] = fdd_rd;
assign sd_wr[1:0] = fdd_wr;
assign sd_buff_din[0] = fdd_buff_din[0];
assign sd_buff_din[1] = fdd_buff_din[1];

// drive A holds a disk (System 1.1J BASIC loads tapes): img_size is valid with the mount strobe
reg fdd_a_in = 1'b0;
always @(posedge clk_sys) if (img_mounted[0]) fdd_a_in <= img_size != 64'd0;

always @(posedge clk_sys) begin
	info_req <= tape_ready | tape_bad;
	if (tape_ready | tape_bad) info <= tape_bad ? 8'd2 : fdd_a_in ? 8'd1 : 8'd3;
end

///////////////////////   MACHINE   ///////////////////////////////

wire HBlank, HSync, VBlank, VSync, ce_pix;
wire [7:0] R, G, B;
wire fdd_busy, caps_led, kana_led;

smc777 #(.CLK_MUL(2)) smc777
(
	.clk_sys(clk_sys),
	.reset(reset),
	.reset_warm(warm),
	.border_en(cfg[5]),
	.smc70_il(status[11]),
	.ps2_key(ps2_key),
	.joy0(joystick_0[5:0]),
	.joy1(joystick_1[5:0]),
	.mouse_en(status[6]),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index[7:0]),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),

	.ce_pix(ce_pix),
	.R(R), .G(G), .B(B),
	.HSync(HSync), .VSync(VSync),
	.HBlank(HBlank), .VBlank(VBlank),

	.audio_l(AUDIO_L),
	.audio_r(AUDIO_R),

	.tape_in(tape_loaded ? tape_level : tape_adc & tape_adc_act),
	.tape_motor(tape_motor),
	.tape_out(),
	.cpu_turbo(tape_turbo),
	.tape_audio(status[9]),

	.img_mounted(img_mounted[1:0]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(fdd_lba),
	.sd_rd(fdd_rd),
	.sd_wr(fdd_wr),
	.sd_ack(sd_ack[1:0]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(fdd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.fdd_busy(fdd_busy),

	.caps_led(caps_led),
	.kana_led(kana_led),

	.cpu_addr(), .cpu_ce(), .cpu_m1_n(),
	.dbg_io_wr(), .dbg_io_rd(), .dbg_io_port(), .dbg_io_data()
);

assign LED_DISK = {1'b0, fdd_busy};
assign LED_USER = ioctl_download | caps_led;

///////////////////////   VIDEO   ///////////////////////////////

// 15.73 kHz: the scandoubler (with HQ2x / CRT scanlines) on request or for VGA monitors (forced_scandoubler)
wire [1:0] scale = cfg[4:3];
wire [2:0] sl    = scale ? scale - 1'd1 : 3'd0;
wire       sd_on = scale != 2'd0 || forced_scandoubler;
assign VGA_SL = sd_on ? sl[1:0] : 2'd0;
assign CLK_VIDEO = clk_sys;

// the tape status bar over the picture, before the scaler
wire [7:0] ov_r, ov_g, ov_b;
smc777_tape_overlay #(.TURBO(8)) smc777_tape_overlay
(
	.clk(clk_sys),
	.loaded(tape_loaded), .playing(tape_playing), .fast(tape_turbo), .underflow(tape_underflow),
	.rate(tape_rate), .position(tape_pos), .length(tape_len),
	.enable(~status[8]),
	.ce_pix(ce_pix), .hblank(HBlank), .vblank(VBlank),
	.r_in(R), .g_in(G), .b_in(B),
	.r_out(ov_r), .g_out(ov_g), .b_out(ov_b)
);

video_mixer #(.LINE_LENGTH(1024), .HALF_DEPTH(0), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix),
	.scandoubler(sd_on),
	.hq2x(scale == 2'd1),
	.gamma_bus(gamma_bus),
	.R(ov_r), .G(ov_g), .B(ov_b),
	.HSync(HSync), .VSync(VSync),
	.HBlank(HBlank), .VBlank(VBlank),
	.HDMI_FREEZE(1'b0),
	.freeze_sync(),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS),
	.VGA_DE(VGA_DE)
);

endmodule
