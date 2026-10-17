//=======================================================================================================
//
// smc777_kbd.sv - SMC-777 keyboard: the 8041 key encoder at 1Ah (data) / 1Bh (status, control).
//
// Modelled on CSP (src/vm/smc777/memory.cpp). Scan mode: once per frame the first pressed key in table order
// (rtl/smc777_kbd_table.svh) becomes a code; a new code sets BSF+ASF (status bits 0, 2), CF/SF (bits 7, 6) for
// ctrl/shift, and raises the keyboard IRQ if enabled (1Bh write bit 0). Reading 1Ah returns the code and clears BSF.
// Holding a key repeats after the start time (default 1000 ms) every interval (default 100 ms).
//
// Setting mode (1Ah/1Bh write bit 4): commands in 1Bh bits 7-6: 00 exit, 11 initialise and exit, 01 repeat
// interval = 20 + 20 * n ms, 10 function key table read (bit 5 = 0) / write (bit 5 = 1) for key n (bits 3-0:
// F1-F5, 6 = H): three data bytes on 1Ah, plain/shift/ctrl. (CSP's 01 case also catches 011 "repeat start".)
//
// Modifiers: shift (either), ctrl (either), CAPS LOCK toggles caps, the JP kana key (or right Alt) toggles kana.
//=======================================================================================================

module smc777_kbd #(parameter CLK_MUL = 2)
(
	input         clk_sys,
	input         reset,
	input         frame,          // one clock per frame (key scan)
	input  [10:0] ps2_key,        // hps_io

	input         wr,             // one-clock write strobe for 1Ah/1Bh
	input         rd_end,         // one clock after a read of 1Ah/1Bh
	input         a0,             // 0: 1Ah, 1: 1Bh (the access in progress / just ended)
	input   [7:0] din,
	output reg [7:0] dout,

	output reg    irq,            // one-clock keyboard interrupt request
	output        caps_led,
	output        kana_led
);

`include "smc777_kbd_table.svh"

localparam CYC_PER_MS = 32224 * CLK_MUL;   // clk_sys = CLK_MUL x 32.2238 MHz

//------------------------------------------------------------------------------------------------
// PS/2 key state
//------------------------------------------------------------------------------------------------

reg [KBD_KEYS-1:0] pressed;
reg  lshift, rshift, lctrl, rctrl, caps, kana;
reg  old_stb;

wire [6:0] k_idx = kbd_index({ps2_key[8], ps2_key[7:0]});
wire       make  = ps2_key[9];

always @(posedge clk_sys) begin
	old_stb <= ps2_key[10];
	if (reset) begin
		pressed <= 0;
		{lshift, rshift, lctrl, rctrl, caps, kana} <= 0;
	end
	else if (old_stb != ps2_key[10]) begin
		case ({ps2_key[8], ps2_key[7:0]})
		9'h012: lshift <= make;
		9'h059: rshift <= make;
		9'h014: lctrl  <= make;
		9'h114: rctrl  <= make;
		9'h058: if (make) caps <= ~caps;
		9'h013, 9'h111: if (make) kana <= ~kana;
		default: if (k_idx != 7'h7f) pressed[k_idx] <= make;
		endcase
	end
end

assign caps_led = caps;
assign kana_led = kana;

// First pressed key in table order
reg  [6:0] first;
reg        any;
always @(*) begin
	first = 0; any = 0;
	for (int i = KBD_KEYS - 1; i >= 0; i--)
		if (pressed[i]) begin first = 7'(i); any = 1; end
end

//------------------------------------------------------------------------------------------------
// Function key table (F1-F5, H): programmable plain / shift / ctrl codes; kana uses the plain/shift ones
//------------------------------------------------------------------------------------------------

reg [7:0] fk_code[6], fk_shift[6], fk_ctrl[6];

wire [41:0] row = kbd_codes(first);
wire  [1:0] flag = row[41:40];
wire        fk = first < 7'd6;
wire  [7:0] c_plain = fk ? fk_code[first[2:0]]  : row[39:32];
wire  [7:0] c_shift = fk ? fk_shift[first[2:0]] : row[31:24];
wire  [7:0] c_ctrl  = fk ? fk_ctrl[first[2:0]]  : row[23:16];
wire  [7:0] c_kana  = fk ? fk_code[first[2:0]]  : row[15:8];
wire  [7:0] c_kshft = fk ? fk_shift[first[2:0]] : row[7:0];

wire        m_shift = flag == 2'd2 ? 1'b1 : flag == 2'd1 ? 1'b0 : (lshift | rshift);
wire        m_ctrl  = flag != 2'd0 ? 1'b0 : (lctrl | rctrl);
wire        m_kana  = flag != 2'd0 ? 1'b0 : kana;
wire  [7:0] c_raw   = m_ctrl ? c_ctrl : (m_kana & m_shift) ? c_kshft : m_kana ? c_kana : m_shift ? c_shift : c_plain;
wire        alpha   = (c_raw >= 8'h41 && c_raw <= 8'h5a) || (c_raw >= 8'h61 && c_raw <= 8'h7a);
wire  [7:0] scan_code = !any ? 8'h00 : (caps && alpha) ? c_raw ^ 8'h20 : c_raw;

//------------------------------------------------------------------------------------------------
// 8041 registers and protocol
//------------------------------------------------------------------------------------------------

reg  [7:0] key_cmd;              // 00 scan mode, FF setting mode, else the command in progress
reg  [7:0] key_code, key_status;
reg        ief;
reg  [2:0] fk_sel;               // 0-5, 7 = none
reg  [1:0] fk_index;
reg [11:0] rep_start, rep_interval;   // ms
reg [11:0] rep_ms;
reg        rep_on;
reg [15:0] ms_cnt;

wire       fk_valid = fk_sel != 3'd7;

task automatic init_keys;
	reg [41:0] row_i;
	for (int i = 0; i < 6; i++) begin
		row_i = kbd_codes(7'(i));
		fk_code[i]  <= row_i[39:32];
		fk_shift[i] <= row_i[31:24];
		fk_ctrl[i]  <= row_i[23:16];
	end
	rep_start    <= 12'd1000;
	rep_interval <= 12'd100;
endtask

always @(posedge clk_sys) begin
	irq <= 1'b0;
	if (reset) begin
		key_cmd <= 8'h00;
		key_code <= 8'h00;
		key_status <= 8'h00;
		ief <= 1'b0;
		fk_sel <= 3'd7;
		fk_index <= 2'd0;
		rep_on <= 1'b0;
		ms_cnt <= 0;
		init_keys();
	end
	else begin
		// repeat timer (ms)
		if (ms_cnt == CYC_PER_MS - 1) begin
			ms_cnt <= 0;
			if (rep_on) begin
				if (rep_ms <= 12'd1) begin
					if (ief) irq <= 1'b1;
					key_status <= key_status | 8'h05;
					rep_ms <= rep_interval;
				end
				else rep_ms <= rep_ms - 1'd1;
			end
		end
		else ms_cnt <= ms_cnt + 1'd1;

		// once per frame: CSP MEMORY::update_key
		if (frame) begin
			if (scan_code != 8'h00) begin
				if (!key_status[2] || key_code != scan_code) begin
					if (ief) irq <= 1'b1;
					rep_on <= 1'b1;
					rep_ms <= rep_start;
					key_code <= scan_code;
					key_status <= (m_ctrl ? 8'h80 : m_shift ? 8'h40 : 8'h00) | 8'h05;
				end
			end
			else begin
				rep_on <= 1'b0;
				key_status[2] <= 1'b0;
			end
		end

		if (wr) begin
			if (key_cmd == 8'h00) begin
				// b7 (1Bh only) clear IRQ status, b4 setting mode, b0 IRQ enable
				if (a0 && din[7]) key_status[0] <= 1'b0;
				if (din[4]) key_cmd <= 8'hff;
				ief <= din[0];
			end
			else if (!a0) begin
				if (key_cmd == 8'ha0) begin
					if (fk_index == 2'd0 && fk_valid) fk_code[fk_sel] <= din;
					if (fk_index == 2'd1 && fk_valid) fk_shift[fk_sel] <= din;
					if (fk_index == 2'd2 && fk_valid) fk_ctrl[fk_sel] <= din;
					if (fk_index == 2'd3) key_cmd <= 8'hff;
					else fk_index <= fk_index + 1'd1;
				end
			end
			else begin
				key_cmd <= {din[7:5], 5'd0};
				case (din[7:6])
				2'b11: begin init_keys(); key_cmd <= 8'h00; end
				2'b00: key_cmd <= 8'h00;
				2'b01: rep_interval <= 12'd20 + 12'd20 * din[3:0];
				2'b10: begin
					fk_index <= 2'd0;
					case (din[3:0])
					4'd1: fk_sel <= 3'd0;
					4'd2: fk_sel <= 3'd1;
					4'd3: fk_sel <= 3'd2;
					4'd4: fk_sel <= 3'd3;
					4'd5: fk_sel <= 3'd4;
					4'd6: fk_sel <= 3'd5;
					default: fk_sel <= 3'd7;
					endcase
				end
				endcase
			end
		end

		if (rd_end && !a0) begin
			if (key_cmd == 8'h00) key_status[0] <= 1'b0;
			else if (key_cmd == 8'h80) begin
				if (fk_index == 2'd3) key_cmd <= 8'hff;
				else fk_index <= fk_index + 1'd1;
			end
		end
	end
end

always @(*) begin
	if (!a0) begin
		if (key_cmd == 8'h00) dout = key_code;
		else if (key_cmd == 8'h80 && fk_valid)
			dout = fk_index == 2'd0 ? fk_code[fk_sel] : fk_index == 2'd1 ? fk_shift[fk_sel] : fk_index == 2'd2 ? fk_ctrl[fk_sel] : 8'h00;
		else dout = 8'h00;
	end
	else dout = key_cmd == 8'h00 ? key_status : key_cmd == 8'h80 ? 8'h05 : 8'h04;
end

endmodule
