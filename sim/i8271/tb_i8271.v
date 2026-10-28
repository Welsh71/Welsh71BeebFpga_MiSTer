// Testbench for rtl/i8271/i8271.v, driven the way Acorn DFS 1.20 drives the 8271:
// command and parameters through &FE80/&FE81, then one NMI per byte through &FE84,
// then the result from &FE81.
//
// Run (OSS CVC):  cp ../../rtl/i8271/i8271.v . && cvc64 +large tb_i8271.v i8271.v && ./cvcsim
//
// The SD card and fdc1772's shared sector buffer are modelled here: a rising edge on
// ext_rd/ext_wr moves one 512-byte block between the buffer and an image array, with
// ext_busy high meanwhile. Drive 0 holds an 80-track .ssd (204,800 bytes) and drive 1
// an 80-track .dsd (409,600 bytes). Every image byte starts as a pattern of its
// position, so a byte read back shows exactly which track, side, sector and offset it
// came from.

`timescale 1ns/1ps
module tb;

// ------------------------------------------------------------------ clocks
reg clk = 0;
always #10.4167 clk = ~clk;             // 48MHz (clock_48)

reg [4:0] div = 0;
always @(posedge clk) div <= (div == 23) ? 5'd0 : div + 5'd1;
wire ce4m   = (div == 0) || (div == 12);  // 4MHz
wire cpu_ce = (div == 23);                // 2MHz CPU cycles

// ------------------------------------------------------------------ DUT
reg        reset = 1;
reg        sel = 0, rw = 1;
reg  [2:0] addr = 0;
reg  [7:0] din = 0;
wire [7:0] dout;
wire       nmi;
reg  [1:0] img_mounted = 0;
reg [31:0] img_size = 0;
wire       ext_drive, ext_rd, ext_wr;
wire [31:0] ext_lba;
reg        ext_busy = 0;
wire [8:0] buf_addr;
wire [7:0] buf_din;
wire       buf_we;
reg  [7:0] buf_q;
wire       led;
wire [23:0] info;

i8271 dut(
	.clk(clk), .ce4m(ce4m), .reset(reset),
	.cpu_ce(cpu_ce), .cpu_sel(sel), .cpu_rw(rw), .cpu_addr(addr), .cpu_din(din), .cpu_dout(dout),
	.nmi(nmi),
	.img_mounted(img_mounted), .img_size(img_size),
	.ext_drive(ext_drive), .ext_lba(ext_lba), .ext_rd(ext_rd), .ext_wr(ext_wr), .ext_busy(ext_busy),
	.buf_addr(buf_addr), .buf_din(buf_din), .buf_we(buf_we), .buf_q(buf_q),
	.drive_led(led), .disk_info(info)
);

// ------------------------------------------------------------------ images, SD, buffer
reg [7:0] img0 [0:204799];
reg [7:0] img1 [0:409599];
reg [7:0] buffer [0:511];

// pattern for a byte at image offset o
function [7:0] pat(input integer o);
	pat = (o[7:0] ^ o[15:8] ^ (o[19:16] << 4)) + 8'h5A;
endfunction

integer i;
initial begin
	for (i = 0; i < 204800; i = i + 1) img0[i] = pat(i);
	for (i = 0; i < 409600; i = i + 1) img1[i] = pat(i) ^ 8'hFF;
end

always @(posedge clk) begin
	if (buf_we) buffer[buf_addr] <= buf_din;
	buf_q <= buffer[buf_addr];
end

reg ext_rd_d = 0, ext_wr_d = 0;
integer sd_n;
integer xfers = 0;
always @(posedge clk) begin
	ext_rd_d <= ext_rd;
	ext_wr_d <= ext_wr;
	if ((ext_rd & ~ext_rd_d) || (ext_wr & ~ext_wr_d)) begin
		xfers = xfers + 1;
		repeat (3) @(posedge clk);
		ext_busy <= 1;
		repeat (300) @(posedge clk);
		for (sd_n = 0; sd_n < 512; sd_n = sd_n + 1) begin
			if (ext_rd) begin
				if (ext_drive) buffer[sd_n] = img1[ext_lba*512 + sd_n];
				else           buffer[sd_n] = img0[ext_lba*512 + sd_n];
			end else begin
				if (ext_drive) img1[ext_lba*512 + sd_n] = buffer[sd_n];
				else           img0[ext_lba*512 + sd_n] = buffer[sd_n];
			end
		end
		ext_busy <= 0;
	end
end

// ------------------------------------------------------------------ CPU bus
reg [7:0] rd;
task bus_write(input [2:0] a, input [7:0] d);
begin
	@(posedge clk); while (div != 2) @(posedge clk);
	sel <= 1; rw <= 0; addr <= a; din <= d;
	@(posedge clk); while (!cpu_ce) @(posedge clk);
	@(posedge clk); sel <= 0; rw <= 1;
end
endtask

task bus_read(input [2:0] a);
begin
	@(posedge clk); while (div != 2) @(posedge clk);
	sel <= 1; rw <= 1; addr <= a;
	@(posedge clk); while (!cpu_ce) @(posedge clk);
	rd = dout;                         // sampled before the edge takes effect
	@(posedge clk); sel <= 0;
end
endtask

// ------------------------------------------------------------------ DFS-style helpers
integer errors = 0;
reg [7:0] got [0:4095];
integer ngot;
reg [7:0] tx [0:4095];
integer ntx;
reg [7:0] res;

task check(input cond, input [8*64-1:0] what);
begin
	if (!cond) begin
		errors = errors + 1;
		$display("FAIL: %0s", what);
	end
end
endtask

// command + parameters (waits for not busy first, like DFS)
task command(input [7:0] c, input integer np,
             input [7:0] p0, input [7:0] p1, input [7:0] p2, input [7:0] p3, input [7:0] p4);
begin
	bus_read(0); while (rd[7]) bus_read(0);
	bus_write(0, c);
	if (np > 0) bus_write(1, p0);
	if (np > 1) bus_write(1, p1);
	if (np > 2) bus_write(1, p2);
	if (np > 3) bus_write(1, p3);
	if (np > 4) bus_write(1, p4);
end
endtask

// service NMIs until the command completes: read or write data bytes, then the result
time t_start;
task transfer;
begin
	ngot = 0;
	forever begin
		@(posedge clk); while (!nmi) @(posedge clk);
		bus_read(0);
		if (rd[2]) begin
			if (rd[4]) ; // not expected
			// data request: a read gives a byte, a write wants one
			if (ntx > 0) begin
				bus_write(4, tx[ngot]);
				ngot = ngot + 1;
				if (ngot == ntx) ntx = -ntx;   // all given
			end else begin
				bus_read(4);
				got[ngot] = rd;
				ngot = ngot + 1;
			end
		end else if (rd[4]) begin
			bus_read(1);
			res = rd;
			disable transfer;
		end
	end
end
endtask

// immediate result (no interrupt): read drive status, read special register
task get_result;
begin
	bus_read(0); while (rd[7]) bus_read(0);
	check(rd[4], "result register full");
	bus_read(1); res = rd;
end
endtask

// offset of track/side/sector in an image
function integer ssd_off(input integer t, input integer s);
	ssd_off = (t * 10 + s) * 256;
endfunction
function integer dsd_off(input integer t, input integer h, input integer s);
	dsd_off = ((t * 2 + h) * 10 + s) * 256;
endfunction

integer k, bad;
time t0, t1;

initial begin
	repeat (50) @(posedge clk);
	reset <= 0;
	repeat (10) @(posedge clk);

	// mount images (hps_io pulses img_mounted with img_size valid)
	img_size <= 204800; img_mounted <= 2'b01; repeat (4) @(posedge clk); img_mounted <= 0;
	img_size <= 409600; img_mounted <= 2'b10; repeat (4) @(posedge clk); img_mounted <= 0;

	// DFS-style reset of the 8271
	bus_write(2, 1); bus_write(2, 0);

	// specify: 12ms steps, 10ms settle, unload 12 revs, load 16ms (as DFS 1.20 sets up)
	command(8'h35, 4, 8'h0D, 8'd12, 8'd10, 8'hC8, 0);
	bus_read(0); check(rd == 8'h00, "specify leaves status clear");
	// mode register (non-DMA), drive control output
	command(8'h3A, 2, 8'h17, 8'hC1, 0, 0, 0);
	command(8'h3A, 2, 8'h23, 8'h00, 0, 0, 0);

	// ---- 1. seek drive 0 to track 5: 5 steps of 12ms + 10ms settle + 16ms load = 86ms
	t0 = $time;
	command(8'h69, 1, 8'd5, 0, 0, 0, 0);
	ntx = 0; transfer;
	t1 = $time;
	check(res == 8'h00, "seek result 0");
	$display("seek 0->5: %0d us (expect ~86000)", (t1 - t0) / 1000);
	check((t1 - t0) > 80_000_000 && (t1 - t0) < 92_000_000, "seek time");

	// ---- 2. read drive 0, track 2, sectors 3-5 (3 x 256 bytes)
	t0 = $time;
	command(8'h53, 3, 8'd2, 8'd3, 8'h23, 0, 0);
	ntx = 0; transfer;
	t1 = $time;
	check(res == 8'h00, "read result 0");
	check(ngot == 768, "read 768 bytes");
	bad = 0;
	for (k = 0; k < 768; k = k + 1) if (got[k] !== pat(ssd_off(2, 3) + k)) bad = bad + 1;
	check(bad == 0, "read data matches image");
	$display("read 3 sectors: %0d bytes, %0d bad, %0d us", ngot, bad, (t1 - t0) / 1000);

	// ---- 3. write drive 0, track 1, sector 9 (odd half of its block); sector 8 must survive
	ntx = 256;
	for (k = 0; k < 256; k = k + 1) tx[k] = k ^ 8'hA5;
	command(8'h4B, 3, 8'd1, 8'd9, 8'h21, 0, 0);
	transfer;
	check(res == 8'h00, "write result 0");
	bad = 0;
	for (k = 0; k < 256; k = k + 1) if (img0[ssd_off(1, 9) + k] !== (k ^ 8'hA5)) bad = bad + 1;
	check(bad == 0, "written sector in image");
	bad = 0;
	for (k = 0; k < 256; k = k + 1) if (img0[ssd_off(1, 8) + k] !== pat(ssd_off(1, 8) + k)) bad = bad + 1;
	check(bad == 0, "neighbouring sector untouched");
	$display("write: %0d bad", bad);

	// read it back through the 8271
	command(8'h53, 3, 8'd1, 8'd9, 8'h21, 0, 0);
	ntx = 0; transfer;
	bad = 0;
	for (k = 0; k < 256; k = k + 1) if (got[k] !== (k ^ 8'hA5)) bad = bad + 1;
	check(res == 8'h00 && ngot == 256 && bad == 0, "read back written sector");

	// ---- 4. side 1 of a single-sided image: sector not found
	command(8'h3A, 2, 8'h23, 8'h20, 0, 0, 0);       // side 1
	command(8'h53, 3, 8'd0, 8'd0, 8'h21, 0, 0);
	ntx = 0; transfer;
	check(res == 8'h18, "side 1 of .ssd: not found");
	$display("ssd side 1: result %02x", res);

	// ---- 5. drive 1 (.dsd), side 1, track 3, sector 7
	command(8'h3A, 2, 8'h23, 8'h20, 0, 0, 0);       // side 1 stays set
	command(8'h93, 3, 8'd3, 8'd7, 8'h21, 0, 0);
	ntx = 0; transfer;
	bad = 0;
	for (k = 0; k < 256; k = k + 1) if (got[k] !== (pat(dsd_off(3, 1, 7) + k) ^ 8'hFF)) bad = bad + 1;
	check(res == 8'h00 && ngot == 256 && bad == 0, "dsd side 1 read");
	$display("dsd side 1: result %02x, %0d bad", res, bad);
	command(8'h3A, 2, 8'h23, 8'h00, 0, 0, 0);       // back to side 0

	// ---- 6. sector 12 does not exist
	command(8'h53, 3, 8'd0, 8'd12, 8'h21, 0, 0);
	ntx = 0; transfer;
	check(res == 8'h18, "sector 12 not found");

	// ---- 7. read ID: 3 IDs from track 4
	command(8'h5B, 3, 8'd4, 8'd0, 8'd3, 0, 0);
	ntx = 0; transfer;
	check(res == 8'h00 && ngot == 12, "read ID 12 bytes");
	check(got[0] == 4 && got[1] == 0 && got[3] == 1, "ID track/head/size");
	check(got[6] == ((got[2] + 1) % 10) && got[10] == ((got[2] + 2) % 10), "IDs in rotation order");
	$display("read ID: %0d %0d %0d %0d / %0d / %0d", got[0], got[1], got[2], got[3], got[6], got[10]);

	// ---- 8. format drive 0, track 10: 10 sectors of 256 bytes
	ntx = 40;
	for (k = 0; k < 10; k = k + 1) begin
		tx[k*4+0] = 10; tx[k*4+1] = 0; tx[k*4+2] = k; tx[k*4+3] = 1;
	end
	command(8'h63, 5, 8'd10, 8'h15, 8'h2A, 8'h00, 8'h10);
	transfer;
	check(res == 8'h00, "format result 0");
	bad = 0;
	for (k = 0; k < 2560; k = k + 1) if (img0[ssd_off(10, 0) + k] !== 8'hE5) bad = bad + 1;
	check(bad == 0, "formatted track is &E5");
	bad = 0;
	for (k = 0; k < 256; k = k + 1) if (img0[ssd_off(11, 0) + k] !== pat(ssd_off(11, 0) + k)) bad = bad + 1;
	check(bad == 0, "next track untouched");
	$display("format: result %02x", res);

	// ---- 9. read drive status: drive 0 selected, not track 0 (head at 10)
	command(8'h6C, 0, 0, 0, 0, 0, 0);
	get_result;
	check(res[2] && !res[1], "drive status: ready 0, not track 0");
	$display("drive status: %02x", res);

	// ---- 10. read special register: track register for surface 0
	command(8'h7D, 1, 8'h12, 0, 0, 0, 0);
	get_result;
	check(res == 10, "track register = 10");

	// ---- 11. no disc in a drive: eject drive 1 and read
	img_size <= 0; img_mounted <= 2'b10; repeat (4) @(posedge clk); img_mounted <= 0;
	command(8'h93, 3, 8'd0, 8'd0, 8'h21, 0, 0);
	ntx = 0; transfer;
	check(res == 8'h18, "empty drive: not found");

	// ---- 12. motor (LED) goes off after the unload time (12 revolutions = 2.4s)
	check(led == 1'b1, "LED on after a command");
	#2500000000;
	check(led == 1'b0, "LED off after unload time");

	$display("SD transfers: %0d", xfers);
	if (errors == 0) $display("PASS: all 8271 tests");
	else             $display("FAILED: %0d errors", errors);
	$finish;
end

// safety net
initial begin
	#20000000000;
	$display("TIMEOUT");
	$finish;
end

endmodule
