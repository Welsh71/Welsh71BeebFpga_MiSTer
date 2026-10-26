// disk_osd.v - MiSTer BBC Micro: on-screen floppy status, bottom right of the picture.
//
//   D:0 T:27 S:05 READ
//
// DFS drive number (side 1 shows as drive 2/3), physical head track, sector
// register, and the last command (READ, WRITE, SEEK, FORMAT; IDLE once the
// drive motor has stopped). Glyphs are the BBC OS 1.20 character set,
// double width. mode: 0 off, 1 always on, 2 only while the drive motor runs.
//
// Pixel position counts on the falling edge of ce_pix, so it is stable while
// ce_pix is high (when the video mixer samples); the overlay pixel is ready
// 3 clk_sys after that, well inside one 16MHz (6 clk) or 12MHz (8 clk) pixel.
// The box is placed from the previous frame's measured width and height, so
// it follows the active picture in every mode.

module disk_osd
(
	input            clk,        // clk_sys
	input            ce_pix,
	input            hblank,
	input            vblank,
	input      [1:0] mode,
	input     [23:0] info,       // from fdc1772 (gated clk_48 domain, latched per frame)

	input      [3:0] r_in, g_in, b_in,
	output     [3:0] r_out, g_out, b_out
);

localparam CHARS = 20;
localparam BOXW  = CHARS*16 + 16;   // 8 pixels of border each side
localparam BOXH  = 12;              // 2 lines above and below the 8-line text
localparam MX    = 16;              // distance from the right edge
localparam MY    = 8;               // distance from the bottom edge

// ---------------------------------------------------------------- counters
reg        ce_d, hb_d, vb_d;
reg [10:0] x, y, width, height, wmax;
wire ce_fall = ce_d & ~ce_pix;

always @(posedge clk) begin
	ce_d <= ce_pix;
	if(ce_fall) begin
		hb_d <= hblank;
		vb_d <= vblank;
		if(hblank) x <= 11'd0; else x <= x + 11'd1;
		if(hblank && !hb_d) begin                // end of a line
			if(vblank) y <= 11'd0;
			else begin
				y <= y + 11'd1;
				if(x > wmax) wmax <= x;
			end
		end
		if(vblank && !vb_d) begin                // end of a frame/field
			if(y > 11'd32 && wmax > 11'd400) begin
				height <= y;
				width  <= wmax;
			end
			wmax <= 11'd0;
		end
	end
end

// ------------------------------------------- disk state, latched per frame
reg [23:0] inf;
reg  [2:0] op;        // 0 idle, 1 read, 2 write, 3 seek, 4 format
reg  [1:0] drv;
reg  [3:0] t10, t1, s10, s1;
reg        led;

wire [6:0] trk = inf[14:8];
wire [7:0] sec = inf[7:0];
wire [3:0] cmd = inf[18:15];

always @(posedge clk) begin
	if(ce_fall && vblank && !vb_d) begin
		inf <= info;
		led <= info[22];
	end

	// decode (inputs are static for a whole frame)
	if(!led) op <= 3'd0;
	else if(inf[21]) begin
		casez(cmd)
			4'b0???: op <= 3'd3;              // restore/seek/step
			4'b100?: op <= 3'd1;              // read sector
			4'b101?: op <= 3'd2;              // write sector
			4'b1100,
			4'b1110: op <= 3'd1;              // read address/track
			4'b1111: op <= 3'd4;              // write track
			default: ;
		endcase
	end
	if(inf[23]) drv <= {~inf[19], inf[20]};   // side 1 = DFS drive 2/3

	t10 <= (trk >= 7'd100) ? 4'd9 : trk / 7'd10;
	t1  <= trk % 7'd10;
	s10 <= (sec >= 8'd100) ? 4'd9 : sec / 8'd10;
	s1  <= sec % 8'd10;
end

// ------------------------------------------------------------ text
function [4:0] txt(input [4:0] col);
	begin
		case(col)
			 0: txt = 5'd13;  1: txt = 5'd11;  2: txt = {3'd0, drv};  3: txt = 5'd10;
			 4: txt = 5'd23;  5: txt = 5'd11;  6: txt = {1'b0, t10};  7: txt = {1'b0, t1};  8: txt = 5'd10;
			 9: txt = 5'd22; 10: txt = 5'd11; 11: txt = {1'b0, s10}; 12: txt = {1'b0, s1}; 13: txt = 5'd10;
			default: txt = word(op, col - 5'd14);
		endcase
	end
endfunction

function [4:0] word(input [2:0] o, input [4:0] i);
	reg [29:0] w;
	begin
		case(o)
			3'd1:    w = {5'd21, 5'd14, 5'd12, 5'd13, 5'd10, 5'd10};
			3'd2:    w = {5'd24, 5'd21, 5'd16, 5'd23, 5'd14, 5'd10};
			3'd3:    w = {5'd22, 5'd14, 5'd14, 5'd17, 5'd10, 5'd10};
			3'd4:    w = {5'd15, 5'd20, 5'd21, 5'd19, 5'd12, 5'd23};
			default: w = {5'd16, 5'd13, 5'd18, 5'd14, 5'd10, 5'd10};
		endcase
		case(i)
			0: word = w[29:25]; 1: word = w[24:20]; 2: word = w[19:15];
			3: word = w[14:10]; 4: word = w[9:5];   default: word = w[4:0];
		endcase
	end
endfunction

// ------------------------------------------------------------ font
function [7:0] glyph(input [4:0] c, input [2:0] row);
	reg [7:0] g;
	begin
		case({c,row})
		{5'd0,3'd0}: g = 8'h3C; // 0
		{5'd0,3'd1}: g = 8'h66; // 0
		{5'd0,3'd2}: g = 8'h6E; // 0
		{5'd0,3'd3}: g = 8'h7E; // 0
		{5'd0,3'd4}: g = 8'h76; // 0
		{5'd0,3'd5}: g = 8'h66; // 0
		{5'd0,3'd6}: g = 8'h3C; // 0
		{5'd0,3'd7}: g = 8'h00; // 0
		{5'd1,3'd0}: g = 8'h18; // 1
		{5'd1,3'd1}: g = 8'h38; // 1
		{5'd1,3'd2}: g = 8'h18; // 1
		{5'd1,3'd3}: g = 8'h18; // 1
		{5'd1,3'd4}: g = 8'h18; // 1
		{5'd1,3'd5}: g = 8'h18; // 1
		{5'd1,3'd6}: g = 8'h7E; // 1
		{5'd1,3'd7}: g = 8'h00; // 1
		{5'd2,3'd0}: g = 8'h3C; // 2
		{5'd2,3'd1}: g = 8'h66; // 2
		{5'd2,3'd2}: g = 8'h06; // 2
		{5'd2,3'd3}: g = 8'h0C; // 2
		{5'd2,3'd4}: g = 8'h18; // 2
		{5'd2,3'd5}: g = 8'h30; // 2
		{5'd2,3'd6}: g = 8'h7E; // 2
		{5'd2,3'd7}: g = 8'h00; // 2
		{5'd3,3'd0}: g = 8'h3C; // 3
		{5'd3,3'd1}: g = 8'h66; // 3
		{5'd3,3'd2}: g = 8'h06; // 3
		{5'd3,3'd3}: g = 8'h1C; // 3
		{5'd3,3'd4}: g = 8'h06; // 3
		{5'd3,3'd5}: g = 8'h66; // 3
		{5'd3,3'd6}: g = 8'h3C; // 3
		{5'd3,3'd7}: g = 8'h00; // 3
		{5'd4,3'd0}: g = 8'h0C; // 4
		{5'd4,3'd1}: g = 8'h1C; // 4
		{5'd4,3'd2}: g = 8'h3C; // 4
		{5'd4,3'd3}: g = 8'h6C; // 4
		{5'd4,3'd4}: g = 8'h7E; // 4
		{5'd4,3'd5}: g = 8'h0C; // 4
		{5'd4,3'd6}: g = 8'h0C; // 4
		{5'd4,3'd7}: g = 8'h00; // 4
		{5'd5,3'd0}: g = 8'h7E; // 5
		{5'd5,3'd1}: g = 8'h60; // 5
		{5'd5,3'd2}: g = 8'h7C; // 5
		{5'd5,3'd3}: g = 8'h06; // 5
		{5'd5,3'd4}: g = 8'h06; // 5
		{5'd5,3'd5}: g = 8'h66; // 5
		{5'd5,3'd6}: g = 8'h3C; // 5
		{5'd5,3'd7}: g = 8'h00; // 5
		{5'd6,3'd0}: g = 8'h1C; // 6
		{5'd6,3'd1}: g = 8'h30; // 6
		{5'd6,3'd2}: g = 8'h60; // 6
		{5'd6,3'd3}: g = 8'h7C; // 6
		{5'd6,3'd4}: g = 8'h66; // 6
		{5'd6,3'd5}: g = 8'h66; // 6
		{5'd6,3'd6}: g = 8'h3C; // 6
		{5'd6,3'd7}: g = 8'h00; // 6
		{5'd7,3'd0}: g = 8'h7E; // 7
		{5'd7,3'd1}: g = 8'h06; // 7
		{5'd7,3'd2}: g = 8'h0C; // 7
		{5'd7,3'd3}: g = 8'h18; // 7
		{5'd7,3'd4}: g = 8'h30; // 7
		{5'd7,3'd5}: g = 8'h30; // 7
		{5'd7,3'd6}: g = 8'h30; // 7
		{5'd7,3'd7}: g = 8'h00; // 7
		{5'd8,3'd0}: g = 8'h3C; // 8
		{5'd8,3'd1}: g = 8'h66; // 8
		{5'd8,3'd2}: g = 8'h66; // 8
		{5'd8,3'd3}: g = 8'h3C; // 8
		{5'd8,3'd4}: g = 8'h66; // 8
		{5'd8,3'd5}: g = 8'h66; // 8
		{5'd8,3'd6}: g = 8'h3C; // 8
		{5'd8,3'd7}: g = 8'h00; // 8
		{5'd9,3'd0}: g = 8'h3C; // 9
		{5'd9,3'd1}: g = 8'h66; // 9
		{5'd9,3'd2}: g = 8'h66; // 9
		{5'd9,3'd3}: g = 8'h3E; // 9
		{5'd9,3'd4}: g = 8'h06; // 9
		{5'd9,3'd5}: g = 8'h0C; // 9
		{5'd9,3'd6}: g = 8'h38; // 9
		{5'd9,3'd7}: g = 8'h00; // 9
		{5'd10,3'd0}: g = 8'h00; // space
		{5'd10,3'd1}: g = 8'h00; // space
		{5'd10,3'd2}: g = 8'h00; // space
		{5'd10,3'd3}: g = 8'h00; // space
		{5'd10,3'd4}: g = 8'h00; // space
		{5'd10,3'd5}: g = 8'h00; // space
		{5'd10,3'd6}: g = 8'h00; // space
		{5'd10,3'd7}: g = 8'h00; // space
		{5'd11,3'd0}: g = 8'h00; // :
		{5'd11,3'd1}: g = 8'h00; // :
		{5'd11,3'd2}: g = 8'h18; // :
		{5'd11,3'd3}: g = 8'h18; // :
		{5'd11,3'd4}: g = 8'h00; // :
		{5'd11,3'd5}: g = 8'h18; // :
		{5'd11,3'd6}: g = 8'h18; // :
		{5'd11,3'd7}: g = 8'h00; // :
		{5'd12,3'd0}: g = 8'h3C; // A
		{5'd12,3'd1}: g = 8'h66; // A
		{5'd12,3'd2}: g = 8'h66; // A
		{5'd12,3'd3}: g = 8'h7E; // A
		{5'd12,3'd4}: g = 8'h66; // A
		{5'd12,3'd5}: g = 8'h66; // A
		{5'd12,3'd6}: g = 8'h66; // A
		{5'd12,3'd7}: g = 8'h00; // A
		{5'd13,3'd0}: g = 8'h78; // D
		{5'd13,3'd1}: g = 8'h6C; // D
		{5'd13,3'd2}: g = 8'h66; // D
		{5'd13,3'd3}: g = 8'h66; // D
		{5'd13,3'd4}: g = 8'h66; // D
		{5'd13,3'd5}: g = 8'h6C; // D
		{5'd13,3'd6}: g = 8'h78; // D
		{5'd13,3'd7}: g = 8'h00; // D
		{5'd14,3'd0}: g = 8'h7E; // E
		{5'd14,3'd1}: g = 8'h60; // E
		{5'd14,3'd2}: g = 8'h60; // E
		{5'd14,3'd3}: g = 8'h7C; // E
		{5'd14,3'd4}: g = 8'h60; // E
		{5'd14,3'd5}: g = 8'h60; // E
		{5'd14,3'd6}: g = 8'h7E; // E
		{5'd14,3'd7}: g = 8'h00; // E
		{5'd15,3'd0}: g = 8'h7E; // F
		{5'd15,3'd1}: g = 8'h60; // F
		{5'd15,3'd2}: g = 8'h60; // F
		{5'd15,3'd3}: g = 8'h7C; // F
		{5'd15,3'd4}: g = 8'h60; // F
		{5'd15,3'd5}: g = 8'h60; // F
		{5'd15,3'd6}: g = 8'h60; // F
		{5'd15,3'd7}: g = 8'h00; // F
		{5'd16,3'd0}: g = 8'h7E; // I
		{5'd16,3'd1}: g = 8'h18; // I
		{5'd16,3'd2}: g = 8'h18; // I
		{5'd16,3'd3}: g = 8'h18; // I
		{5'd16,3'd4}: g = 8'h18; // I
		{5'd16,3'd5}: g = 8'h18; // I
		{5'd16,3'd6}: g = 8'h7E; // I
		{5'd16,3'd7}: g = 8'h00; // I
		{5'd17,3'd0}: g = 8'h66; // K
		{5'd17,3'd1}: g = 8'h6C; // K
		{5'd17,3'd2}: g = 8'h78; // K
		{5'd17,3'd3}: g = 8'h70; // K
		{5'd17,3'd4}: g = 8'h78; // K
		{5'd17,3'd5}: g = 8'h6C; // K
		{5'd17,3'd6}: g = 8'h66; // K
		{5'd17,3'd7}: g = 8'h00; // K
		{5'd18,3'd0}: g = 8'h60; // L
		{5'd18,3'd1}: g = 8'h60; // L
		{5'd18,3'd2}: g = 8'h60; // L
		{5'd18,3'd3}: g = 8'h60; // L
		{5'd18,3'd4}: g = 8'h60; // L
		{5'd18,3'd5}: g = 8'h60; // L
		{5'd18,3'd6}: g = 8'h7E; // L
		{5'd18,3'd7}: g = 8'h00; // L
		{5'd19,3'd0}: g = 8'h63; // M
		{5'd19,3'd1}: g = 8'h77; // M
		{5'd19,3'd2}: g = 8'h7F; // M
		{5'd19,3'd3}: g = 8'h6B; // M
		{5'd19,3'd4}: g = 8'h6B; // M
		{5'd19,3'd5}: g = 8'h63; // M
		{5'd19,3'd6}: g = 8'h63; // M
		{5'd19,3'd7}: g = 8'h00; // M
		{5'd20,3'd0}: g = 8'h3C; // O
		{5'd20,3'd1}: g = 8'h66; // O
		{5'd20,3'd2}: g = 8'h66; // O
		{5'd20,3'd3}: g = 8'h66; // O
		{5'd20,3'd4}: g = 8'h66; // O
		{5'd20,3'd5}: g = 8'h66; // O
		{5'd20,3'd6}: g = 8'h3C; // O
		{5'd20,3'd7}: g = 8'h00; // O
		{5'd21,3'd0}: g = 8'h7C; // R
		{5'd21,3'd1}: g = 8'h66; // R
		{5'd21,3'd2}: g = 8'h66; // R
		{5'd21,3'd3}: g = 8'h7C; // R
		{5'd21,3'd4}: g = 8'h6C; // R
		{5'd21,3'd5}: g = 8'h66; // R
		{5'd21,3'd6}: g = 8'h66; // R
		{5'd21,3'd7}: g = 8'h00; // R
		{5'd22,3'd0}: g = 8'h3C; // S
		{5'd22,3'd1}: g = 8'h66; // S
		{5'd22,3'd2}: g = 8'h60; // S
		{5'd22,3'd3}: g = 8'h3C; // S
		{5'd22,3'd4}: g = 8'h06; // S
		{5'd22,3'd5}: g = 8'h66; // S
		{5'd22,3'd6}: g = 8'h3C; // S
		{5'd22,3'd7}: g = 8'h00; // S
		{5'd23,3'd0}: g = 8'h7E; // T
		{5'd23,3'd1}: g = 8'h18; // T
		{5'd23,3'd2}: g = 8'h18; // T
		{5'd23,3'd3}: g = 8'h18; // T
		{5'd23,3'd4}: g = 8'h18; // T
		{5'd23,3'd5}: g = 8'h18; // T
		{5'd23,3'd6}: g = 8'h18; // T
		{5'd23,3'd7}: g = 8'h00; // T
		{5'd24,3'd0}: g = 8'h63; // W
		{5'd24,3'd1}: g = 8'h63; // W
		{5'd24,3'd2}: g = 8'h6B; // W
		{5'd24,3'd3}: g = 8'h6B; // W
		{5'd24,3'd4}: g = 8'h7F; // W
		{5'd24,3'd5}: g = 8'h77; // W
		{5'd24,3'd6}: g = 8'h63; // W
		{5'd24,3'd7}: g = 8'h00; // W
		default: g = 8'h00;
		endcase
		glyph = g;
	end
endfunction

// ------------------------------------------------------------ pipeline
wire [10:0] bx = width  - MX[10:0] - BOXW[10:0];
wire [10:0] by = height - MY[10:0] - BOXH[10:0];
wire [10:0] dx = x - bx;
wire [10:0] dy = y - by;
wire        on = (mode == 2'd1) || (mode == 2'd2 && led);

reg        box1, txt1, box2, txt2, box3, pix3;
reg  [4:0] ch1;
reg  [2:0] row1, px1, px2;
reg  [7:0] bits2;

always @(posedge clk) begin
	// 1: where are we
	box1 <= on && !hblank && !vblank && width != 0 && dx < BOXW && dy < BOXH;
	txt1 <= dx >= 11'd8 && dx < (11'd8 + CHARS*16) && dy >= 11'd2 && dy < 11'd10;
	ch1  <= txt((dx - 11'd8) >> 4);
	row1 <= dy - 11'd2;
	px1  <= (dx - 11'd8) >> 1;
	// 2: glyph row
	box2  <= box1;
	txt2  <= txt1;
	bits2 <= glyph(ch1, row1);
	px2   <= px1;
	// 3: pixel
	box3 <= box2;
	pix3 <= txt2 & bits2[3'd7 - px2];
end

assign r_out = box3 ? (pix3 ? 4'hF : 4'h0) : r_in;
assign g_out = box3 ? (pix3 ? 4'hF : 4'h0) : g_in;
assign b_out = box3 ? (pix3 ? 4'h0 : 4'h0) : b_in;   // yellow text on black

endmodule
