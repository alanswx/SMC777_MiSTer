//============================================================================
//  SMC-777 mouse on joystick port 2 (MSX-style protocol), as SMC Paint 2.3 reads it
//
//  Neither CSP nor MAME emulates the mouse; the protocol is SMC Paint's driver (AC9Eh, AB67h):
//    OUT 51h,05h (pin 5 = strobe low), wait, IN 51h (B = 0): bits 3-0 = high nibble
//    OUT 51h,15h (strobe high),        wait, IN 51h:         bits 3-0 = low nibble
//    movement = -(byte); once for X, then once for Y, each vsync interrupt.
//  Buttons: bit 4 (~T, trigger 1) = left, bit 5 (~USER, trigger 2) = right, active low. SMC Paint's AB67h returns
//  them as 2 = left, 1 = right, and its menu selects with 2.
//
//  Each strobe edge moves to the next nibble: X high, X low, Y high, Y low. The first edge after 1 ms without one
//  starts a new sequence and latches the movement counted since the last one, as an MSX mouse does: up to +-127
//  per sequence (SMC Paint negates the byte, so 80h can't be sent), the rest is kept for the next. The bytes are
//  minus the movement, with X right and Y down positive on the screen.
//============================================================================

module smc777_mouse #(parameter CLK_MUL = 2)
(
	input             clk_sys,
	input             reset,

	input      [24:0] ps2_mouse,      // hps_io ps2_mouse: [24] toggles per packet, [23:16] Y, [15:8] X, [7:0] status
	input             strobe,         // port 51h pin 5 (OUT 51h with bits 2-0 = 5, data bit 4)

	output reg  [3:0] nibble,
	output      [1:0] buttons         // {right, left}, 1 = pressed
);

localparam TIMEOUT = 32224 * CLK_MUL;   // 1 ms of the 32.2238 MHz master clock

assign buttons = ps2_mouse[1:0];     // PS/2 status: bit 0 left, bit 1 right

// movement since the last latch, in screen terms (right / down positive), kept within +-1024
reg  signed [11:0] acc_x, acc_y;
wire signed [11:0] dx = {{4{ps2_mouse[4]}}, ps2_mouse[15:8]};
wire signed [11:0] dy = -{{4{ps2_mouse[5]}}, ps2_mouse[23:16]};  // PS/2: up is positive

reg        pkt_d;
wire       pkt = ps2_mouse[24] != pkt_d;

reg        strobe_d;
reg  [1:0] idx;
reg  [7:0] lx, ly;
reg [16:0] idle;

function automatic signed [11:0] sat_add(input signed [11:0] a, input signed [11:0] b);  // kept within +-1024
	reg signed [11:0] r;
	r = a + b;
	if (r > 12'sd1024) sat_add = 12'sd1024;
	else if (r < -12'sd1024) sat_add = -12'sd1024;
	else sat_add = r;
endfunction

function automatic signed [11:0] clamp127(input signed [11:0] v);   // SMC Paint NEGs the byte: 80h would stay -128
	if (v > 12'sd127) clamp127 = 12'sd127;
	else if (v < -12'sd127) clamp127 = -12'sd127;
	else clamp127 = v;
endfunction

wire       edge_s  = strobe != strobe_d;
wire       restart = idle >= TIMEOUT[16:0];
wire [1:0] cur     = restart ? 2'd0 : idx;
wire       latch   = edge_s && cur == 2'd0;
wire signed [11:0] cx = clamp127(acc_x);   // sent now; the rest stays for the next sequence
wire signed [11:0] cy = clamp127(acc_y);
wire signed [11:0] nx = -cx;
wire signed [11:0] ny = -cy;

always @(posedge clk_sys) begin
	pkt_d <= ps2_mouse[24];
	strobe_d <= strobe;

	if (reset) begin
		acc_x <= 12'sd0;
		acc_y <= 12'sd0;
		idx <= 2'd0;
		idle <= TIMEOUT[16:0];
		nibble <= 4'd0;
		lx <= 8'd0;
		ly <= 8'd0;
	end
	else begin
		if (!restart) idle <= idle + 1'd1;

		if (latch) begin
			lx <= nx[7:0];
			ly <= ny[7:0];
			acc_x <= sat_add(acc_x - cx, pkt ? dx : 12'sd0);
			acc_y <= sat_add(acc_y - cy, pkt ? dy : 12'sd0);
		end
		else if (pkt) begin
			acc_x <= sat_add(acc_x, dx);
			acc_y <= sat_add(acc_y, dy);
		end

		if (edge_s) begin
			idle <= 17'd0;
			idx <= cur + 1'd1;
			case (cur)
			2'd0: nibble <= nx[7:4];
			2'd1: nibble <= lx[3:0];
			2'd2: nibble <= ly[7:4];
			2'd3: nibble <= ly[3:0];
			endcase
		end
	end
end

endmodule
