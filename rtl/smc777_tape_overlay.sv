// Tape status bar (~/dev2/tape-standard.md rules 19-24, after the Basic Master L3 and Sharp X1 cores).
// "TAPE > m:ss/ m:ss x8" and a 64-step progress bar in the bottom-left corner of the picture while a tape is mounted
// and the deck plays. Times are at the tape's own rate (samples / sample rate), saturating at 99:59; "x8" shows while
// turbo is active, "!" after a buffer underflow (a diagnostic: the deck had to wait for the SD card). It is mixed into
// the RGB after the machine and never changes it. Everything runs on clk_sys (CLK_VIDEO = clk_sys): no handshake.
module smc777_tape_overlay #(
	parameter int TURBO = 8               // one digit
) (
	input             clk,
	input             loaded,
	input             playing,
	input             fast,
	input             underflow,
	input      [17:0] rate,
	input      [31:0] position,           // samples played (0 after mount/rewind)
	input      [31:0] length,             // samples on the tape

	input             enable,
	input             ce_pix,
	input             hblank,
	input             vblank,
	input       [7:0] r_in, g_in, b_in,
	output reg  [7:0] r_out, g_out, b_out
);

function [15:0] bcd_tick;                // m1 m0 s1 s0 + 1 s
	input [15:0] t;
	begin
		bcd_tick = t;
		if (t != 16'h9959) begin
			if (t[3:0] != 4'd9) bcd_tick[3:0] = t[3:0] + 4'd1;
			else begin
				bcd_tick[3:0] = 4'd0;
				if (t[7:4] != 4'd5) bcd_tick[7:4] = t[7:4] + 4'd1;
				else begin
					bcd_tick[7:4] = 4'd0;
					if (t[11:8] != 4'd9) bcd_tick[11:8] = t[11:8] + 4'd1;
					else begin bcd_tick[11:8] = 4'd0; bcd_tick[15:12] = t[15:12] + 4'd1; end
				end
			end
		end
	end
endfunction

// ---- status ---------------------------------------------------------------------------------------------------------
reg [15:0] elapsed = 0, total = 0;
reg [17:0] acc = 0;                       // samples into the current second
reg [31:0] last_pos = 0, last_len = 0, rem = 0, cell_n = 0;
reg [17:0] last_rate = 0;
reg        computing = 0;
reg  [6:0] fill = 0;
wire [31:0] cell_len = length[31:6] == 0 ? 32'd1 : {6'd0, length[31:6]};

always @(posedge clk) begin
	last_pos <= position;
	if (position == 0 || position < last_pos) begin
		elapsed <= 0; acc <= 0; fill <= 0; cell_n <= 0;
	end else if (position != last_pos) begin
		if (acc + 18'd1 >= rate) begin acc <= 0; elapsed <= bcd_tick(elapsed); end
		else acc <= acc + 18'd1;
		if (cell_n + 32'd1 >= cell_len) begin
			cell_n <= 0;
			if (fill != 7'd64) fill <= fill + 7'd1;
		end else cell_n <= cell_n + 32'd1;
	end
	// total: take one second of samples off the length per clock
	last_len <= length; last_rate <= rate;
	if (length != last_len || rate != last_rate) begin
		rem <= length; total <= 0; computing <= rate != 0;
	end else if (computing) begin
		if (rem >= {14'd0, rate}) begin rem <= rem - {14'd0, rate}; total <= bcd_tick(total); end
		else computing <= 1'b0;
	end
end

// ---- picture --------------------------------------------------------------------------------------------------------
reg [10:0] x = 0, width = 0;
reg  [9:0] y = 0, height = 0;
reg        line_active = 0, old_hb = 0, old_vb = 0;

always @(posedge clk) if (ce_pix) begin
	old_hb <= hblank; old_vb <= vblank;
	if (~hblank & ~vblank) begin x <= x + 11'd1; line_active <= 1'b1; end
	if (hblank & ~old_hb) begin
		if (line_active) begin width <= x; y <= y + 10'd1; end
		x <= 0; line_active <= 1'b0;
	end
	if (vblank & ~old_vb) begin height <= y; y <= 0; end
end

localparam [4:0] TDIGIT = TURBO;
localparam CHARS = 22, BOX_W = CHARS * 8 + 4, BOX_H = 18;
wire       visible = enable & loaded & playing;
// doubled on pictures at least 512 wide and 300 lines high
wire       sx = width >= 11'd512, sy = height >= 10'd300;
wire [10:0] x0 = 11'd4;
wire  [9:0] y0 = height - (sy ? 10'd2 * BOX_H : 10'd1 * BOX_H) - 10'd4;
wire [10:0] dx = x - x0;
wire  [9:0] dy = y - y0;
wire [10:0] lx = sx ? {1'b0, dx[10:1]} : dx;
wire  [9:0] ly = sy ? {1'b0, dy[9:1]} : dy;
wire       in_box = x >= x0 && y >= y0 && lx < BOX_W && ly < BOX_H;

// text at ly 2..9: 0-9 digits, 10 ':', 11 '/', 12 T, 13 A, 14 P, 15 E, 16 x, 17 play, 18 space, 19 '!'
wire [10:0] tx = lx - 11'd2;
wire  [9:0] ty = ly - 10'd2;
wire  [4:0] col = tx[7:3];
reg   [4:0] code;
always @(*) begin
	case (col)
	5'd0: code = 5'd12;  5'd1: code = 5'd13;  5'd2: code = 5'd14;  5'd3: code = 5'd15;
	5'd5: code = 5'd17;
	5'd7: code = elapsed[15:12] == 0 ? 5'd18 : {1'b0, elapsed[15:12]};
	5'd8: code = {1'b0, elapsed[11:8]};   5'd9: code = 5'd10;
	5'd10: code = {1'b0, elapsed[7:4]};   5'd11: code = {1'b0, elapsed[3:0]};
	5'd12: code = 5'd11;
	5'd13: code = total[15:12] == 0 ? 5'd18 : {1'b0, total[15:12]};
	5'd14: code = {1'b0, total[11:8]};    5'd15: code = 5'd10;
	5'd16: code = {1'b0, total[7:4]};     5'd17: code = {1'b0, total[3:0]};
	5'd19: code = fast ? 5'd16 : 5'd18;
	5'd20: code = fast ? TDIGIT : 5'd18;
	5'd21: code = underflow ? 5'd19 : 5'd18;
	default: code = 5'd18;
	endcase
end
reg [63:0] g;
always @(*) begin
	case (code)
	5'd0:  g = 64'h3C666E7666663C00;  5'd1:  g = 64'h1838181818187E00;
	5'd2:  g = 64'h3C66060C30607E00;  5'd3:  g = 64'h3C66061C06663C00;
	5'd4:  g = 64'h0C1C3C6C7E0C0C00;  5'd5:  g = 64'h7E607C0606663C00;
	5'd6:  g = 64'h1C30607C66663C00;  5'd7:  g = 64'h7E060C1830303000;
	5'd8:  g = 64'h3C66663C66663C00;  5'd9:  g = 64'h3C66663E060C3800;
	5'd10: g = 64'h0018180018180000;  5'd11: g = 64'h02060C1830604000;
	5'd12: g = 64'h7E18181818181800;  5'd13: g = 64'h183C66667E666600;
	5'd14: g = 64'h7C66667C60606000;  5'd15: g = 64'h7E60607C60607E00;
	5'd16: g = 64'h0000663C183C6600;  5'd17: g = 64'h4060707870604000;
	5'd19: g = 64'h1818181818001800;
	default: g = 64'h0;
	endcase
end
wire [7:0] glyph_row = g[63 - {ty[2:0], 3'd0} -: 8];
wire       text_on = ty < 10'd8 && tx < CHARS * 8 && glyph_row[3'd7 - tx[2:0]];
// bar at ly 12..15, 128 px for 64 steps
wire       bar_area = ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
wire       bar_on = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

always @(*) begin
	{r_out, g_out, b_out} = {r_in, g_in, b_in};
	if (visible && in_box)
		{r_out, g_out, b_out} = text_on ? 24'hFFFFFF : bar_on ? 24'h44CC44 : bar_area ? 24'h333333 : 24'h000000;
end

endmodule
