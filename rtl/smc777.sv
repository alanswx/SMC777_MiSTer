//============================================================================
//  Sony SMC-777 machine
//
//  References: Common Source Code Project (src/vm/smc777, eSMC-777) and MAME (sony/smc777.cpp),
//  http://www.x1center.org/smc777/smc70_777_IOMAP_20210923.txt
//
//  The 32.2238 MHz master clock (MAME) gives the Z80 at /8 (4.028 MHz), dots at /2 (16.11 MHz), the HD46505
//  character clock at /16. clk_sys is CLK_MUL times the master clock: 2 on the MiSTer (64.4476 MHz, so the
//  scandoubler has 4 clocks per pixel), 1 for the fast simulation build. The IPL programs a 128 x 262 character raster
//  (1024 dots x 262 lines, 15.73 kHz / 60.05 Hz) with 640 x 200 visible.
//
//  Memory: 64 KiB RAM; the 16 KiB IPL ROM overlays 0000-3FFF for reads until port 1Ch selects RAM
//  (the switch takes effect at the second opcode fetch after the OUT, as in CSP). Writes always go to RAM.
//
//  I/O uses the full 16-bit port address (OUT (C) with B as the high byte):
//    00-07  text VRAM   {port[2:0], B}      08-0F  attribute RAM    10-17  PCG (font) RAM
//    18/19  HD46505     1A/1B  8041 keyboard (rtl/smc777_kbd.sv)    1C/1D  LS259 latch / status
//    20     display mode (GCW)   21  vsync IRQ flag / enable   23  border colour
//    30-33  MB8877A FDC, 34  drive select / FDC IRQ+DRQ status (rtl/smc777_fdc.sv)
//    51     joysticks + blanking / palette select   52  palette board   53  SN76489AN
//    7E/7F  kanji ROM: JIS code hi/lo (write), pattern byte {B[4:0]} (read 7Eh)
//    80-FF  graphics VRAM {port[6:0], B} (32 KiB)
//============================================================================

module smc777 #(parameter CLK_MUL = 2)
(
	input         clk_sys,
	input         reset,
	input         reset_warm,         // with reset: warm start (port 1Ch bit 7 reads 1, the RESET key)
	input         border_en,          // show the border (port 23h colour) around the 640x200 picture, as MAME

	input  [10:0] ps2_key,            // hps_io ps2_key
	input   [5:0] joy0,               // MiSTer joystick bits: 0 right, 1 left, 2 down, 3 up, 4 button 1, 5 button 2
	input   [5:0] joy1,

	// boot.rom download (hps_io ioctl index 0): IPL ROM (SMCROM.DAT) at 0000-3FFF, kanji ROM (KANJIROM.DAT) at
	// 4000-273FF
	input         ioctl_download,
	input   [7:0] ioctl_index,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,

	output        ce_pix,
	output reg [7:0] R,
	output reg [7:0] G,
	output reg [7:0] B,
	output reg    HSync,
	output reg    VSync,
	output reg    HBlank,
	output reg    VBlank,

	output [15:0] audio_l,
	output [15:0] audio_r,

	// cassette: line-in bit, motor relay, line-out bit
	input         tape_in,
	output        tape_motor,
	output        tape_out,

	// floppy image slots (hps_io sd_*), drives A and B; D88 images
	input   [1:0] img_mounted,
	input         img_readonly,
	input  [63:0] img_size,
	output [31:0] sd_lba[2],
	output  [1:0] sd_rd,
	output  [1:0] sd_wr,
	input   [1:0] sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din[2],
	input         sd_buff_wr,
	output        fdd_busy,

	output        caps_led,
	output        kana_led,

	// debug / simulation
	output [15:0] cpu_addr,
	output        cpu_ce,
	output        cpu_m1_n,
	output        dbg_io_wr,
	output        dbg_io_rd,
	output [15:0] dbg_io_port,
	output  [7:0] dbg_io_data
);

//------------------------------------------------------------------------------------------------
// Clock enables
//------------------------------------------------------------------------------------------------

// cnt counts master-clock phases (0-15 per character); last = the last clk_sys of a phase
reg [4:0] cnt = 0;
always @(posedge clk_sys) cnt <= cnt + 1'd1;
wire [3:0] ph   = CLK_MUL == 2 ? cnt[4:1] : cnt[3:0];
wire       last = CLK_MUL == 2 ? cnt[0] : 1'b1;

wire ce_cpu  = last && ph[2:0] == 3'd7;   // 4.028 MHz
wire ce_char = last && ph == 4'd15;       // 2.014 MHz: CRTC advances at the end of phase 15
assign ce_pix = last && ph[0];            // 16.11 MHz, see the video output below
assign cpu_ce = ce_cpu;

//------------------------------------------------------------------------------------------------
// CPU
//------------------------------------------------------------------------------------------------

wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;
wire [15:0] A;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;
wire        int_n;

wire cpu_reset = reset | ioctl_download;

// T80 v350 (rtl/T80_v350, Sorgelig's ZEXALL-tested MiSTer T80). The sim gets T80s as a ghdl synth netlist with these
// generics fixed (verilator/Makefile, -g...): keep both in step.
`ifdef VERILATOR
T80s cpu
`else
T80s #(.Mode(0), .T2Write(1), .IOWait(1)) cpu
`endif
(
	.RESET_n(~cpu_reset),
	.CLK(clk_sys),
	.CEN(ce_cpu),
	.OUT0(1'b0),
	.WAIT_n(1'b1),
	.INT_n(int_n),
	.NMI_n(1'b1),
	.BUSRQ_n(1'b1),
	.M1_n(m1_n),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.RFSH_n(),
	.HALT_n(),
	.BUSAK_n(),
	.A(A),
	.DI(cpu_din),
	.DO(cpu_dout)
);

assign cpu_addr = A;
assign cpu_m1_n = m1_n;

wire mem_rd = ~mreq_n & ~rd_n;
wire mem_wr = ~mreq_n & ~wr_n;
wire io_rd  = ~iorq_n & ~rd_n & m1_n;
wire io_wr  = ~iorq_n & ~wr_n;
wire inta   = ~iorq_n & ~m1_n;

// One-clock strobes per bus cycle (I/O devices with side effects)
reg io_wr_d = 0, io_rd_d = 0, m1_d = 1, inta_d = 0;
reg [15:0] io_port_l;
always @(posedge clk_sys) begin
	io_wr_d <= io_wr;
	io_rd_d <= io_rd;
	m1_d    <= m1_n;
	inta_d  <= inta;
	if (io_rd) io_port_l <= A;
end
wire io_wr_stb  = io_wr & ~io_wr_d;
wire io_rd_end  = ~io_rd & io_rd_d;       // read side effects after the CPU has the data
wire m1_start   = ~m1_n & m1_d;
wire inta_start = inta & ~inta_d;

wire [7:0] lo = A[7:0];
wire [7:0] hi = A[15:8];


//------------------------------------------------------------------------------------------------
// Memory: 64 KiB RAM, 16 KiB IPL ROM overlay
//------------------------------------------------------------------------------------------------

reg raminh;                               // 1: IPL ROM readable at 0000-3FFF
reg [1:0] bank_wait;
reg bank_next;

wire [7:0] ram_q, rom_q;

spram #(16, 8) ram
(
	.clock(clk_sys),
	.address(A),
	.wren(mem_wr),
	.data(cpu_dout),
	.q(ram_q)
);

dpram #(14, 8) rom
(
	.clock_a(clk_sys),
	.address_a(A[13:0]),
	.enable_a(1'b1),
	.wren_a(1'b0),
	.data_a(8'h00),
	.q_a(rom_q),

	.clock_b(clk_sys),
	.address_b(ioctl_addr[13:0]),
	.enable_b(1'b1),
	.wren_b(ioctl_download && ioctl_wr && ioctl_index == 8'd0 && ioctl_addr[24:14] == 0),
	.data_b(ioctl_dout),
	.q_b()
);

wire [7:0] mem_dout = (raminh && A[15:14] == 2'b00) ? rom_q : ram_q;

//------------------------------------------------------------------------------------------------
// Video memories: CPU port (I/O mapped) and video port
//------------------------------------------------------------------------------------------------

wire sel_cram = lo[7:3] == 5'b00000;
wire sel_aram = lo[7:3] == 5'b00001;
wire sel_pcg  = lo[7:3] == 5'b00010;
wire sel_gram = lo[7];

wire [10:0] vram_a = {lo[2:0], hi};
wire [14:0] gram_a = {lo[6:0], hi};

wire [7:0] cram_q, aram_q, pcg_q, gram_q;
wire [7:0] cram_v, aram_v, pcg_v, gram_v;
reg [10:0] txt_va;
reg [10:0] pcg_va;
reg [14:0] gram_va;

dpram #(11, 8) cram
(
	.clock_a(clk_sys), .address_a(vram_a), .enable_a(1'b1), .wren_a(io_wr_stb & sel_cram), .data_a(cpu_dout), .q_a(cram_q),
	.clock_b(clk_sys), .address_b(txt_va), .enable_b(1'b1), .wren_b(1'b0), .data_b(8'h00), .q_b(cram_v)
);

dpram #(11, 8) aram
(
	.clock_a(clk_sys), .address_a(vram_a), .enable_a(1'b1), .wren_a(io_wr_stb & sel_aram), .data_a(cpu_dout), .q_a(aram_q),
	.clock_b(clk_sys), .address_b(txt_va), .enable_b(1'b1), .wren_b(1'b0), .data_b(8'h00), .q_b(aram_v)
);

dpram #(11, 8) pcg
(
	.clock_a(clk_sys), .address_a(vram_a), .enable_a(1'b1), .wren_a(io_wr_stb & sel_pcg), .data_a(cpu_dout), .q_a(pcg_q),
	.clock_b(clk_sys), .address_b(pcg_va), .enable_b(1'b1), .wren_b(1'b0), .data_b(8'h00), .q_b(pcg_v)
);

dpram #(15, 8) gram
(
	.clock_a(clk_sys), .address_a(gram_a), .enable_a(1'b1), .wren_a(io_wr_stb & sel_gram), .data_a(cpu_dout), .q_a(gram_q),
	.clock_b(clk_sys), .address_b(gram_va), .enable_b(1'b1), .wren_b(1'b0), .data_b(8'h00), .q_b(gram_v)
);

//------------------------------------------------------------------------------------------------
// I/O registers
//------------------------------------------------------------------------------------------------

reg  [7:0] gcw;                           // 20h: b7 40 columns, b6 40-column page, b5 640 colour set, b3 640x200
reg        ief_vsync, vsync_idf, irq_vsync;
reg  [3:0] border;
reg        vsup, sound_out, motor, cas_out;
reg        use_pal_text, use_pal_graph;
reg  [3:0] pal_r[16], pal_g[16], pal_b[16];
reg  [4:0] crtc_ar;                       // shadow of the HD46505 registers the renderer needs
reg  [6:0] crtc_r10;
reg  [4:0] crtc_r11;
reg [13:0] crtc_cursor;

reg        warm_start;
reg  [6:0] kanji_hi, kanji_lo;

reg  [7:0] io_dout, io_dout_l;
wire [7:0] crtc_do;
wire       disp;                          // CRTC display enable (for port 51h bit 7)
wire [13:0] ma;
wire  [4:0] ra;
wire        crtc_de, crtc_hde, crtc_vde, crtc_hs, crtc_vs;

// Vsync interrupt: requested on the trailing edge of VSYNC, held until the CPU acknowledges it (IM 1/RST 38h)
reg vsync_d;
always @(posedge clk_sys) vsync_d <= crtc_vs;
wire vsync_fall = vsync_d & ~crtc_vs;

always @(posedge clk_sys) begin
	if (cpu_reset) begin
		raminh <= 1'b1;
		bank_wait <= 2'd0;
		gcw <= 8'h80;
		ief_vsync <= 1'b0;
		vsync_idf <= 1'b0;
		border <= 4'd0;
		{vsup, sound_out, motor, cas_out} <= 4'b0000;
		{use_pal_text, use_pal_graph} <= 2'b00;
		warm_start <= reset_warm;
	end
	else begin
		// RAM/ROM switch at the second opcode fetch after the OUT
		if (m1_start && bank_wait != 2'd0) begin
			bank_wait <= bank_wait - 1'd1;
			if (bank_wait == 2'd1) raminh <= bank_next;
		end

		if (io_wr_stb) begin
			case (lo)
			8'h18: crtc_ar <= cpu_dout[4:0];
			8'h19: case (crtc_ar)
			       5'd10: crtc_r10 <= cpu_dout[6:0];
			       5'd11: crtc_r11 <= cpu_dout[4:0];
			       5'd14: crtc_cursor[13:8] <= cpu_dout[5:0];
			       5'd15: crtc_cursor[7:0] <= cpu_dout;
			       default: ;
			       endcase
			8'h1c, 8'h1d: case (cpu_dout[2:0])   // LS259: pin cpu_dout[2:0] <= cpu_dout[4]
			       3'd0: begin bank_next <= ~cpu_dout[4]; bank_wait <= 2'd2; end
			       3'd1: vsup <= cpu_dout[4];
			       3'd4: motor <= cpu_dout[4];
			       3'd5: sound_out <= cpu_dout[4];
			       3'd7: cas_out <= cpu_dout[4];
			       default: ;                   // 2: 525/625, 3: RGB/composite, 6: printer strobe
			       endcase
			8'h20: gcw <= cpu_dout;
			8'h21: ief_vsync <= cpu_dout[0];
			8'h23: border <= cpu_dout[3:0];
			8'h51: case (cpu_dout[2:0])
			       3'd6: use_pal_text  <= cpu_dout[4];
			       3'd7: use_pal_graph <= cpu_dout[4];
			       default: ;
			       endcase
			8'h52: case (hi[5:4])
			       2'd0: pal_r[hi[3:0]] <= cpu_dout[7:4];
			       2'd1: pal_g[hi[3:0]] <= cpu_dout[7:4];
			       2'd2: pal_b[hi[3:0]] <= cpu_dout[7:4];
			       default: ;
			       endcase
			8'h7e: kanji_hi <= cpu_dout[6:0];
			8'h7f: kanji_lo <= cpu_dout[6:0];
			default: ;
			endcase
		end

		if (io_rd_end) begin
			case (io_port_l[7:0])
			8'h21: vsync_idf <= 1'b0;
			default: ;
			endcase
		end

		if (vsync_fall && ief_vsync) vsync_idf <= 1'b1;
	end
end

// Interrupts (vsync, keyboard) share /INT and are held until the CPU acknowledges; the handler polls 21h and 1Bh.
// An acknowledge clears both, as CSP's Z80 does with no interrupt controller.
reg irq_key;
always @(posedge clk_sys) begin
	if (cpu_reset) begin irq_vsync <= 1'b0; irq_key <= 1'b0; end
	else if (inta_start) begin irq_vsync <= 1'b0; irq_key <= 1'b0; end
	else begin
		if (vsync_fall && ief_vsync) irq_vsync <= 1'b1;
		if (kbd_irq) irq_key <= 1'b1;
	end
end
assign int_n = ~(irq_vsync | irq_key);

//------------------------------------------------------------------------------------------------
// Keyboard, floppy, kanji ROM
//------------------------------------------------------------------------------------------------

wire [7:0] kbd_dout, fdc_dout;
wire       kbd_irq;

smc777_kbd #(.CLK_MUL(CLK_MUL)) kbd
(
	.clk_sys(clk_sys),
	.reset(cpu_reset),
	.frame(vsync_fall),
	.ps2_key(ps2_key),
	.wr(io_wr_stb && (lo == 8'h1a || lo == 8'h1b)),
	.rd_end(io_rd_end && (io_port_l[7:0] == 8'h1a || io_port_l[7:0] == 8'h1b)),
	.a0(io_rd_end ? io_port_l[0] : lo[0]),
	.din(cpu_dout),
	.dout(kbd_dout),
	.irq(kbd_irq),
	.caps_led(caps_led),
	.kana_led(kana_led)
);

smc777_fdc fdc
(
	.clk_sys(clk_sys),
	.reset(cpu_reset),
	.ce_cpu(ce_cpu),
	.io_addr(lo),
	.io_rd(io_rd),
	.io_wr(io_wr),
	.io_dout(cpu_dout),
	.io_din(fdc_dout),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.busy(fdd_busy)
);

// Kanji ROM, 144 KiB: JIS rows 21h-4Fh x columns 20h-7Fh, 32 bytes per character (16x16, left/right halves)
localparam KANJI_SIZE = 18'h23400;
reg  [7:0] kanji_rom[KANJI_SIZE];
reg  [7:0] kanji_q;
wire [17:0] kanji_dl = ioctl_addr[17:0] - 18'h04000;
wire       kanji_wr = ioctl_download && ioctl_wr && ioctl_index == 8'd0 && ioctl_addr >= 25'h04000 && ioctl_addr < 25'h04000 + KANJI_SIZE;
wire       kanji_ok = kanji_hi >= 7'h21 && kanji_hi <= 7'h4f && kanji_lo >= 7'h20;
wire [12:0] kanji_chr = {kanji_hi - 7'h21, 6'd0} + {kanji_hi - 7'h21, 5'd0} + (kanji_lo - 7'h20);   // row * 96 + column
always @(posedge clk_sys) begin
	if (kanji_wr) kanji_rom[kanji_dl] <= ioctl_dout;
	kanji_q <= kanji_rom[{kanji_chr, hi[4:0]}];
end

assign tape_motor = motor;
assign tape_out   = cas_out;

always @(*) begin
	io_dout = 8'h00;
	if (sel_cram) io_dout = cram_q;
	else if (sel_aram) io_dout = aram_q;
	else if (sel_pcg) io_dout = pcg_q;
	else if (sel_gram) io_dout = gram_q;
	else case (lo)
	8'h18, 8'h19: io_dout = crtc_do;
	8'h1a, 8'h1b: io_dout = kbd_dout;
	8'h1c: io_dout = {warm_start, 7'd0};  // b7: 1 = warm start (RESET key); b4 0 = palette board fitted (CSP: 0)
	8'h1d: io_dout = {tape_in, 7'd0};     // b7: cassette in; b4/b3 printer busy/ack
	8'h20: io_dout = gcw;
	8'h21: io_dout = {7'd0, vsync_idf};
	8'h30, 8'h31, 8'h32, 8'h33, 8'h34: io_dout = fdc_dout;
	// 51h: B bit 0 = 1 joystick #1 (5 bits), 0 joystick #2 (6 bits); active low F B L R T USER; b7 = ~blanking
	8'h51: io_dout = {disp, 1'b0, hi[0] ? ~joy_smc(joy0) & 6'h1f : ~joy_smc(joy1)};
	8'h7e: io_dout = kanji_ok ? kanji_q : 8'h00;
	default: io_dout = 8'h00;
	endcase
end

always @(posedge clk_sys) if (io_rd) io_dout_l <= io_dout;

// MiSTer joystick -> {USER, T, R, L, B, F}
function automatic [5:0] joy_smc(input [5:0] j);
	joy_smc = {j[5], j[4], j[0], j[1], j[2], j[3]};
endfunction

assign dbg_io_wr   = io_wr_stb;
assign dbg_io_rd   = io_rd_end;
assign dbg_io_port = io_wr_stb ? A : io_port_l;
assign dbg_io_data = io_wr_stb ? cpu_dout : io_dout_l;

always @(*) begin
	if (inta) cpu_din = 8'hff;            // RST 38h in IM 0, ignored in IM 1
	else if (~mreq_n) cpu_din = mem_dout;
	else cpu_din = io_dout;
end

//------------------------------------------------------------------------------------------------
// HD46505 CRTC
//------------------------------------------------------------------------------------------------

wire        crtc_wr = io_wr_stb && (lo == 8'h18 || lo == 8'h19);
wire        crtc_rd = io_rd && lo == 8'h19;

mc6845 crtc
(
	.CLOCK(clk_sys),
	.CLKEN(ce_char),
	.CLKEN_CPU(1'b1),
	.nRESET(~cpu_reset),

	.ENABLE(crtc_wr | crtc_rd),
	.R_nW(~crtc_wr),
	.RS(lo[0]),
	.DI(cpu_dout),
	.DO(crtc_do),

	.VSYNC(crtc_vs),
	.HSYNC(crtc_hs),
	.DE(crtc_de),
	.HDE(crtc_hde),
	.VDE(crtc_vde),
	.CURSOR(),
	.LPSTB(1'b0),

	.VGA(1'b0),

	.MA(ma),
	.RA(ra),
	.test()
);

assign disp = crtc_de;

//------------------------------------------------------------------------------------------------
// Video: fetch during character period N, shown in period N+2 (the IPL sets R8 = A0h: display
// enable and cursor skew of two characters)
//------------------------------------------------------------------------------------------------

// Text blink (attribute bit 6): 4 Hz; cursor blink from the frame count, as CSP
localparam BLINK_HALF = 4027975 * CLK_MUL;   // 125 ms
reg [22:0] blink_cnt;
reg        blink;
reg  [4:0] frame_cnt;
always @(posedge clk_sys) begin
	if (blink_cnt == BLINK_HALF - 1) begin blink_cnt <= 0; blink <= ~blink; end
	else blink_cnt <= blink_cnt + 1'd1;
	if (vsync_fall) frame_cnt <= frame_cnt + 1'd1;
end

wire        col40 = gcw[7];
wire [10:0] txt_addr = col40 ? {ma[10:1], gcw[6]} : ma[10:0];
wire [10:0] cur_addr = col40 ? {crtc_cursor[10:1], gcw[6]} : crtc_cursor[10:0];

always @(*) begin
	txt_va  = txt_addr;
	pcg_va  = {cram_v, ra[2:0]};
	gram_va = {ra[2:0], ma[10:0], ph[3]};
end

// fetched in period N
reg [7:0] f_pat, f_attr, f_g0, f_g1;
reg       f_cursor, f_half;
// two-stage delay to period N+2
reg [7:0] s1_pat, s1_attr, s1_g0, s1_g1, s2_pat, s2_attr, s2_g0, s2_g1;
reg       s1_cursor, s1_half, s2_cursor, s2_half;

wire cursor_on = crtc_r10[6:5] == 2'b00 ? 1'b1 :
                 crtc_r10[6:5] == 2'b10 ? frame_cnt[3] :
                 crtc_r10[6:5] == 2'b11 ? frame_cnt[4] : 1'b0;

always @(posedge clk_sys) begin
	if (last && ph == 4'd6) f_g0 <= gram_v;
	if (last && ph == 4'd14) begin
		f_pat    <= pcg_v;
		f_attr   <= aram_v;
		f_g1     <= gram_v;
		f_half   <= col40 & ma[0];
		f_cursor <= cursor_on && txt_addr == cur_addr && ra >= crtc_r10[4:0] && ra <= crtc_r11;
	end
	if (ce_char) begin
		{s1_pat, s1_attr, s1_g0, s1_g1, s1_cursor, s1_half} <= {f_pat, f_attr, f_g0, f_g1, f_cursor, f_half};
		{s2_pat, s2_attr, s2_g0, s2_g1, s2_cursor, s2_half} <= {s1_pat, s1_attr, s1_g0, s1_g1, s1_cursor, s1_half};
	end
end

// Text pixel: {opaque, colour}. Attribute: b7 force white, b6 blink, b5 reverse,
// b4-3 background (0 transparent, 1 white, 2 black, 3 complement in colours 8-15), b2-0 foreground
wire [2:0] px = ph[3:1];
wire [7:0] attr = s2_attr[7] ? 8'h07 : s2_attr;
wire       reverse = attr[5] ^ (attr[6] & blink);
wire [7:0] pat = reverse ? ~s2_pat : s2_pat;
wire       tbit = col40 ? pat[3'd7 - {s2_half, px[2:1]}] : pat[3'd7 - px];

reg [4:0] tpix;
always @(*) begin
	if (s2_cursor) tpix = 5'h17;
	else if (tbit) tpix = {2'b10, attr[2:0]};
	else case (attr[4:3])
	2'd0: tpix = 5'h00;
	2'd1: tpix = 5'h17;
	2'd2: tpix = 5'h10;
	2'd3: tpix = {2'b11, ~attr[2:0]};
	endcase
end

// Graphics pixel: 640x200 2 bpp (colour set by GCW b5) or 320x200 4 bpp
wire [15:0] gw = {s2_g0, s2_g1};
wire  [1:0] g2 = gw[5'd15 - {px, 1'b0} -: 2];
wire  [3:0] g4 = gw[5'd15 - {px[2:1], 2'b00} -: 4];
wire  [3:0] gpix = gcw[3] ? (g2 == 2'd0 ? 4'd0 : g2 == 2'd1 ? 4'd4 : g2 == 2'd2 ? 4'd2 : (gcw[5] ? 4'd7 : 4'd1)) : g4;

wire        is_text = tpix[4];
wire  [3:0] cidx = is_text ? tpix[3:0] : gpix;
wire        use_pal = is_text ? use_pal_text : use_pal_graph;

// Colour generator (digital RGB 0-7; 8-15 as in WinSMC/CSP)
reg [23:0] cg;
always @(*) begin
	case (cidx)
	4'd0:  cg = 24'h000000;  4'd1:  cg = 24'h0000ff;  4'd2:  cg = 24'h00ff00;  4'd3:  cg = 24'h00ffff;
	4'd4:  cg = 24'hff0000;  4'd5:  cg = 24'hff00ff;  4'd6:  cg = 24'hffff00;  4'd7:  cg = 24'hffffff;
	4'd8:  cg = 24'h104010;  4'd9:  cg = 24'h107020;  4'd10: cg = 24'hd05020;  4'd11: cg = 24'he09020;
	4'd12: cg = 24'h105080;  4'd13: cg = 24'h1090e0;  4'd14: cg = 24'hf07090;  4'd15: cg = 24'h808080;
	endcase
end

// CSP scales the palette board's 4-bit levels as n*255/15 = n*17
wire [23:0] pb = {pal_r[cidx], pal_r[cidx], pal_g[cidx], pal_g[cidx], pal_b[cidx], pal_b[cidx]};

// Border: learn where the display window sits (characters from HSYNC, lines from VSYNC) and open the
// blanking 4 characters and 16 lines wider around it. Off: blanking is the CRTC's display window, as CSP.
reg  [7:0] hpos, h_start, h_end;
reg  [8:0] vpos, v_start, v_end;
reg        hs_d, vs_d2, hde_d, vde_d;
always @(posedge clk_sys) begin
	if (ce_char) begin
		hs_d  <= crtc_hs;
		hde_d <= crtc_hde;
		hpos  <= (crtc_hs & ~hs_d) ? 8'd0 : hpos + 1'd1;
		if (crtc_hde & ~hde_d) h_start <= hpos;
		if (~crtc_hde & hde_d) h_end <= hpos;
		if (crtc_hs & ~hs_d) begin
			vs_d2 <= crtc_vs;
			vde_d <= crtc_vde;
			vpos  <= (crtc_vs & ~vs_d2) ? 9'd0 : vpos + 1'd1;
			if (crtc_vde & ~vde_d) v_start <= vpos;
			if (~crtc_vde & vde_d) v_end <= vpos;
		end
	end
end
wire border_h = hpos + 8'd4 >= h_start && hpos < h_end + 8'd4;
wire border_v = vpos + 9'd16 >= v_start && vpos < v_end + 9'd16;
wire show_h   = border_en ? border_h : crtc_hde;
wire show_v   = border_en ? border_v : crtc_vde;

reg [23:0] bc;
always @(*) begin
	case (border)
	4'd0:  bc = 24'h000000;  4'd1:  bc = 24'h0000ff;  4'd2:  bc = 24'h00ff00;  4'd3:  bc = 24'h00ffff;
	4'd4:  bc = 24'hff0000;  4'd5:  bc = 24'hff00ff;  4'd6:  bc = 24'hffff00;  4'd7:  bc = 24'hffffff;
	4'd8:  bc = 24'h104010;  4'd9:  bc = 24'h107020;  4'd10: bc = 24'hd05020;  4'd11: bc = 24'he09020;
	4'd12: bc = 24'h105080;  4'd13: bc = 24'h1090e0;  4'd14: bc = 24'hf07090;  4'd15: bc = 24'h808080;
	endcase
end

always @(posedge clk_sys) begin
	{R, G, B} <= vsup ? 24'h000000 : !crtc_de ? (border_en ? bc : 24'h000000) : use_pal ? pb : cg;
	HBlank <= ~show_h;
	VBlank <= ~show_v;
	HSync  <= crtc_hs;
	VSync  <= crtc_vs;
end

//------------------------------------------------------------------------------------------------
// Sound: beeper (LS259 pin 5) and SN76489AN at 53h
//------------------------------------------------------------------------------------------------

wire [7:0] psg_out;

SN76496 psg
(
	.clk(clk_sys),
	.clken(ce_cpu),
	.reset(cpu_reset),
	.ce(1'b1),
	.we(io_wr_stb && lo == 8'h53),
	.data(cpu_dout),
	.chmsk(4'hf),
	.sndout(psg_out),
	.chactv(),
	.lreg()
);

// Signed output (AUDIO_S = 1): the PSG (0-255 summed channels), beeper and cassette monitor as levels
wire [15:0] mix = {2'b00, psg_out, 6'd0} + (sound_out ? 16'h1800 : 16'h0000) + ((motor && (cas_out ^ tape_in)) ? 16'h0400 : 16'h0000);
assign audio_l = mix;
assign audio_r = mix;

endmodule
