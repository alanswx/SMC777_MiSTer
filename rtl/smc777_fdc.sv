//=======================================================================================================
//
// smc777_fdc.sv - SMC-777 floppy interface: MB8877A at 30h-33h, drive select / status at 34h.
//
//   30-33  MB8877A (WD179x family) status/command, track, sector, data. Not inverted (CSP).
//   34     write: bit 0 drive (A/B). read: bit 7 IRQ, bit 6 ~DRQ, bits 5-0 zero.
//
// The drive motor is always on (CSP: SIG_MB8877_MOTOR held at 1); one side (the SMC-70 side select in 34h bit 7 is
// not on the 777). Two drives on the MiSTer image slots. Images are D88: the library's ".1dd" files are D88 with
// media byte 30h/40h, one track-table slot per cylinder (rtl/wd1793/wd1793.sv LOCAL ADDITION). 2D D88s
// (Yakyuu-Kyou, media 00h, 40 tracks) are read on the 80-track drive at head/2, odd tracks unformatted (DRIVE_2DD).
//
// The chip is Sorgelig's wd1793.sv with FM-7_MiSTer's D77/D88 support, as SharpMZ2500_MiSTer uses it: one instance
// per drive. Commands go to the selected drive; track, sector and data writes go to both, as a single chip has one
// register set. An empty slot reads not ready. The IRQ/DRQ go to port 34h only (software polls).
//=======================================================================================================

module smc777_fdc
(
	input         clk_sys,
	input         reset,
	input         ce_cpu,         // the controller's timing runs at the CPU clock

	input   [7:0] io_addr,
	input         io_rd,          // I/O read level (IORQ & RD)
	input         io_wr,          // I/O write level
	input   [7:0] io_dout,        // CPU data out
	output  [7:0] io_din,         // data for the CPU (valid for 30-34)

	// MiSTer image slots (hps_io), one per drive
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

	output        busy            // drive activity (LED)
);

reg  [1:0] mounted = 0;
reg  [1:0] wprot = 0;
always @(posedge clk_sys) begin
	for (int i = 0; i < 2; i++)
		if (img_mounted[i]) begin
			mounted[i] <= |img_size;
			wprot[i]   <= img_readonly;
		end
end

wire       chip  = io_addr[7:2] == 6'b001100;          // 30-33
wire [1:0] reg_a = io_addr[1:0];

reg        drive;
reg        old_wr;
always @(posedge clk_sys) begin
	old_wr <= io_wr;
	if (reset) drive <= 1'b0;
	else if (io_wr & ~old_wr && io_addr == 8'h34) drive <= io_dout[0];
end

wire [7:0] fdc_dout[2];
wire [1:0] fdc_busy, fdc_prepare, fdc_drq, fdc_irq;

genvar d;
generate
	for (d = 0; d < 2; d = d + 1) begin : drv
		wire selected = (drive == d);
		wire io_en = chip & (selected | (io_wr & reg_a != 2'd0));

		// WDT: 2 MFM byte times (64 us) at the 4 MHz ce
		wd1793 #(.RWMODE(1), .EDSK(1), .WDT(256), .DRIVE_2DD(1)) fdc
		(
			.clk_sys(clk_sys),
			.ce(ce_cpu | fdc_prepare[d]),
			.reset(reset),
			.io_en(io_en),
			.rd(io_rd),
			.wr(io_wr),
			.addr(reg_a),
			.din(io_dout),
			.crc_report(1'b1),
			.dout(fdc_dout[d]),
			.drq(fdc_drq[d]),
			.intrq(fdc_irq[d]),
			.busy(fdc_busy[d]),
			.wp(wprot[d]),
			.fmt_wp(),
			.size_code(3'd1),
			.layout(1'b0),
			.side(1'b0),
			.ready(mounted[d] & ~fdc_prepare[d]),

			.img_mounted(img_mounted[d]),
			.img_size(img_size[20:0]),
			.img_size_id(img_size[23:0]),
			.disk_index(3'd0),
			.prepare(fdc_prepare[d]),
			.sd_lba(sd_lba[d]),
			.sd_rd(sd_rd[d]),
			.sd_wr(sd_wr[d]),
			.sd_ack(sd_ack[d]),
			.sd_buff_addr(sd_buff_addr),
			.sd_buff_dout(sd_buff_dout),
			.sd_buff_din(sd_buff_din[d]),
			.sd_buff_wr(sd_buff_wr),

			.input_active(1'b0),
			.input_addr(21'd0),
			.input_data(8'd0),
			.input_wr(1'b0),
			.buff_addr(),
			.buff_read(),
			.buff_din(8'd0)
		);
	end
endgenerate

assign io_din = (io_addr == 8'h34) ? {fdc_irq[drive], ~fdc_drq[drive], 6'd0} : fdc_dout[drive];
assign busy   = |(fdc_busy & mounted);

endmodule
