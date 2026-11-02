// Cassette deck for a WAV image on an hps_io SD slot (~/dev2/tape-standard.md).
//
// The SMC-777 reads tape as the level of port 1Dh bit 7, timed by CPU polling loops (System 1.1J BASIC,
// F59Eh-F6ABh), so a tape is plain audio: PCM WAV, 8- or 16-bit, mono or stereo (the first channel plays), 4-192 kHz.
// The image is not held on chip: an 8-sector ring buffer is filled ahead of the playing position, so any length works.
// Each mount starts rewound. The level goes through a comparator with a little hysteresis (5% of full scale), as the
// simulator's line-in model (verilator/sim_headless.cpp --tape) and tools/smc777_tape.py.
//
// The deck plays while the motor relay (port 1Ch) is on. Turbo (rule 7): while it plays, the CPU runs TURBO times
// faster (rtl/smc777.sv cpu_turbo) and the samples are played TURBO times faster, so BASIC's loops see the same pulse
// widths. Turbo is chosen when the deck starts, and only if the stream fits MAX_BPS bytes per second from the SD card
// (rule 9); a faster WAV plays at 1x. If the ring buffer runs dry the deck waits (no invented samples) and `underflow`
// is set until the next mount or rewind.
module smc777_tape #(
	parameter int CLK_HZ  = 64444444,
	parameter int TURBO   = 8,
	parameter int MAX_BPS = 400000
) (
	input             clk,
	input             rewind,       // back to the first sample
	input             motor,        // the deck plays while the relay is on
	input             turbo_req,    // OSD: Tape speed = TURBO x (taken when the deck starts)

	// hps_io block device for this slot
	input             img_mounted,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg        sd_rd = 1'b0,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,

	output reg        level = 1'b0, // to the cassette input
	output reg        loaded = 1'b0,// a playable WAV is mounted
	output            playing,      // motor on, samples left
	output            turbo,        // the CPU runs fast now
	output reg        ready,        // one-clock pulses after a mount: OSD info messages 1 and 2
	output reg        bad,
	output reg        underflow = 1'b0,
	output reg [17:0] rate = 18'd0, // samples per second
	output reg [31:0] position = 32'd0, // samples played
	output reg [31:0] length = 32'd0    // samples on the tape
);

// ---- sector ring: 8 x 512 bytes ------------------------------------------------------------------------------------
// Sectors base..head-1 have been fetched since the last refetch; the ring holds the last 8 of them. Fetches run
// ahead of the read position by up to 8 sectors. A fetch still in flight when head moves elsewhere is dropped.

reg  [31:0] rd = 32'd0;           // byte position read next
reg  [22:0] head = 23'd0, base = 23'd0, fetch_lba = 23'd0;
reg         busy = 1'b0;
reg         drop = 1'b0;          // the fetch in flight belongs to the image before a mount
reg  [31:0] size = 32'd0;
reg   [1:0] wait_q = 2'd0;        // clocks since rd changed (the ring's read port is registered)
wire [22:0] rd_sec = rd[31:9];
wire [22:0] low    = head - base > 23'd8 ? head - 23'd8 : base;
wire        avail  = rd_sec >= low && rd_sec < head;
wire        byte_ok = avail && wait_q == 2'd2;
wire  [7:0] buf_q;

dpram #(12, 8) ring
(
	.clock_a(clk), .enable_a(1'b1), .wren_a(sd_ack & sd_buff_wr), .address_a({fetch_lba[2:0], sd_buff_addr}),
	.data_a(sd_buff_dout), .q_a(),
	.clock_b(clk), .enable_b(1'b1), .wren_b(1'b0), .address_b(rd[11:0]), .data_b(8'h00), .q_b(buf_q)
);

// ---- WAV parser and player ------------------------------------------------------------------------------------------

localparam [31:0] ID_RIFF = 32'h46464952, ID_WAVE = 32'h45564157, ID_FMT = 32'h20746d66, ID_DATA = 32'h61746164;

// S_RIFF..S_FMT3 read one little-endian word each into w; S_WORD then acts on it (`what` = the state that read it)
localparam [3:0] S_IDLE = 0, S_RIFF = 1, S_RSIZE = 2, S_WAVE = 3, S_CHID = 4, S_CHSZ = 5, S_FMT0 = 6, S_FMT1 = 7,
                 S_FMT2 = 8, S_FMT3 = 9, S_WORD = 10, S_PLAY = 11;

reg   [3:0] state = S_IDLE, what = S_IDLE;
reg  [31:0] w = 32'd0;
reg   [1:0] nb = 2'd3;            // bytes still to read into w after this one
reg  [31:0] id = 32'd0, fmt_end = 32'd0, tag_ch = 32'd0;
reg  [31:0] data_start = 32'd0, data_end = 32'd0;
reg   [2:0] align = 3'd1;         // bytes per frame: 1, 2 or 4
reg         bits16 = 1'b0, fmt_ok = 1'b0;
reg   [5:0] chunks = 6'd0;        // chunk headers read: give up on garbage

// player
reg  [31:0] acc = 32'd0;
reg  [21:0] step = 22'd0;         // samples per second, times TURBO while turbo
reg         due = 1'b0, fast = 1'b0, motor_d = 1'b0;
reg         rd_hi = 1'b0;         // the low byte of a 16-bit sample has been read
reg   [7:0] lo_byte = 8'd0;
reg   [4:0] dry = 5'd0;           // clocks a due sample has waited for the SD card

assign playing = loaded && motor && rd + align <= data_end;
assign turbo   = playing && fast;

wire [32:0] chunk_end = {1'b0, rd} + {1'b0, w} + w[0];   // after the size word: body plus pad byte
wire [31:0] chunk_end_sat = chunk_end[32] ? 32'hFFFFFFFF : chunk_end[31:0];
wire [32:0] data_lim = {1'b0, rd} + {1'b0, w};
wire [15:0] s16 = {buf_q, lo_byte};

// fmt: tag 1 (PCM), 1-2 channels, 8/16 bits, block align = channels * bytes per sample
wire [15:0] f_ch = tag_ch[31:16], f_bits = w[31:16], f_align = w[15:0];
wire        f_ok = tag_ch[15:0] == 16'd1 && (f_ch == 16'd1 || f_ch == 16'd2) && (f_bits == 16'd8 || f_bits == 16'd16) &&
                   f_align == (f_ch << (f_bits == 16'd16 ? 1 : 0)) && rate >= 18'd4000;

// move the read position; outside the resident sectors the ring refetches from there
task seek(input [31:0] to);
	rd <= to;
	wait_q <= 2'd0;
	if (!(to[31:9] >= low && to[31:9] < head)) begin head <= to[31:9]; base <= to[31:9]; end
endtask

always @(posedge clk) begin
	ready <= 1'b0;
	bad <= 1'b0;
	if (wait_q != 2'd2) wait_q <= wait_q + 2'd1;

	// sector fetch
	if (~busy && state != S_IDLE && head < rd_sec + 23'd8 && {head, 9'd0} < size) begin
		fetch_lba <= head;
		sd_lba <= {9'd0, head};
		sd_rd <= 1'b1;
		busy <= 1'b1;
	end
	if (busy && sd_ack) sd_rd <= 1'b0;
	if (busy && ~sd_rd && ~sd_ack) begin
		busy <= 1'b0;
		drop <= 1'b0;
		if (fetch_lba == head && !drop) head <= head + 23'd1;
	end

	motor_d <= motor;
	if (motor & ~motor_d) fast <= turbo_req && rate * align * TURBO <= MAX_BPS;
	step <= fast ? rate * TURBO : {4'd0, rate};

	case (state)
	S_RIFF, S_RSIZE, S_WAVE, S_CHID, S_CHSZ, S_FMT0, S_FMT1, S_FMT2, S_FMT3:
		if (rd >= size) begin
			state <= S_IDLE;
			bad <= 1'b1;
		end else if (byte_ok) begin
			w <= {buf_q, w[31:8]};
			rd <= rd + 32'd1;
			wait_q <= 2'd0;
			if (nb != 2'd0) nb <= nb - 2'd1;
			else begin
				nb <= 2'd3;
				what <= state;
				state <= S_WORD;
			end
		end

	S_WORD: begin
		state <= S_IDLE;
		case (what)
		S_RIFF:  state <= w == ID_RIFF ? S_RSIZE : S_IDLE;
		S_RSIZE: state <= S_WAVE;
		S_WAVE:  state <= w == ID_WAVE ? S_CHID : S_IDLE;
		S_CHID:  begin id <= w; chunks <= chunks + 6'd1; state <= &chunks ? S_IDLE : S_CHSZ; end
		S_CHSZ:
			if (id == ID_FMT && w >= 32'd16) begin
				fmt_end <= chunk_end_sat;
				state <= S_FMT0;
			end else if (id == ID_DATA) begin
				data_start <= rd;
				data_end <= data_lim > {1'b0, size} ? size : data_lim[31:0];
				state <= fmt_ok ? S_PLAY : S_IDLE;
				loaded <= fmt_ok;
				ready <= fmt_ok;
			end else begin
				seek(chunk_end_sat);
				state <= S_CHID;
			end
		S_FMT0:  begin tag_ch <= w; state <= S_FMT1; end
		S_FMT1:  begin rate <= w > 32'd192000 ? 18'd0 : w[17:0]; state <= S_FMT2; end
		S_FMT2:  state <= S_FMT3;                                     // byte rate
		S_FMT3:  begin
			fmt_ok <= f_ok;
			align <= f_align[2:0];
			bits16 <= f_bits == 16'd16;
			seek(fmt_end);
			state <= S_CHID;
		end
		default: ;
		endcase
		if ((what == S_RIFF && w != ID_RIFF) || (what == S_WAVE && w != ID_WAVE) ||
		    (what == S_CHID && &chunks) || (what == S_CHSZ && id == ID_DATA && !fmt_ok)) bad <= 1'b1;
	end

	S_PLAY: begin
		if (playing && !due) begin
			if (acc + step >= CLK_HZ) begin acc <= acc + step - CLK_HZ; due <= 1'b1; end
			else acc <= acc + step;
		end
		if (due) begin
			if (!avail) begin
				if (dry != 5'd31) dry <= dry + 5'd1;
				if (dry == 5'd16) underflow <= 1'b1;
			end
			if (byte_ok) begin
				if (bits16 && !rd_hi) begin
					lo_byte <= buf_q;
					rd_hi <= 1'b1;
					rd <= rd + 32'd1;
					wait_q <= 2'd0;
				end else begin
					if (bits16) begin
						if ($signed(s16) >= 16'sd1639) level <= 1'b1;
						else if ($signed(s16) <= -16'sd1639) level <= 1'b0;
						rd <= rd + align - 32'd1;
					end else begin
						if (buf_q >= 8'd135) level <= 1'b1;
						else if (buf_q <= 8'd121) level <= 1'b0;
						rd <= rd + align;
					end
					wait_q <= 2'd0;
					rd_hi <= 1'b0;
					due <= 1'b0;
					dry <= 5'd0;
					position <= position + 32'd1;
				end
			end
		end
		if (rewind) begin
			seek(data_start);
			position <= 32'd0;
			acc <= 32'd0;
			due <= 1'b0;
			rd_hi <= 1'b0;
			level <= 1'b0;
			underflow <= 1'b0;
		end
	end

	default: ;
	endcase

	if (img_mounted) begin
		size <= img_size[63:32] != 32'd0 ? 32'hFFFFFFFF : img_size[31:0];
		rd <= 32'd0;
		head <= 23'd0;
		base <= 23'd0;
		wait_q <= 2'd0;
		nb <= 2'd3;
		chunks <= 6'd0;
		fmt_ok <= 1'b0;
		loaded <= 1'b0;
		rate <= 18'd0;
		position <= 32'd0;
		acc <= 32'd0;
		due <= 1'b0;
		rd_hi <= 1'b0;
		level <= 1'b0;
		underflow <= 1'b0;
		dry <= 5'd0;
		drop <= busy;
		state <= img_size == 64'd0 ? S_IDLE : S_RIFF;
	end
end

// samples on the tape: the data bytes over the frame size (1, 2 or 4)
always @(posedge clk) length <= (data_end - data_start) >> (align == 3'd4 ? 2 : align == 3'd2 ? 1 : 0);

endmodule
