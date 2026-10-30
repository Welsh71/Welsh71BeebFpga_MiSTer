// i8271.v
//
// Intel 8271 floppy disc controller for the BBC Micro Model B (Acorn DFS 1.20).
// Copyright (C) 2026 Paul Stewart (Welsh71). Licensed under the GNU GPL v2 or later.
//
// A behavioural model written from the Intel 8271 data sheet, with b-em's i8271.c
// (GPL v2, Tom Walker and the b-em developers) as the reference for how DFS drives it.
// It is not microcode-accurate: it covers the commands DFS 1.20 uses and the timing
// that software can see (step and settle times, 64us per byte, index pulses), working
// on .ssd/.dsd images through the SD port and sector buffer shared with fdc1772.v.
//
// Registers (BBC Micro &FE80-&FE87):
//   &FE80  R status        W command
//   &FE81  R result        W parameter
//   &FE82                  W reset (bit 0)
//   &FE84-&FE87  R/W data (non-DMA transfers, one NMI per byte)
//
// Images: 256-byte sectors, 10 per track, sectors numbered 0-9. A .dsd interleaves the
// two sides track by track; an image is treated as double sided when it is larger than
// 409,500 bytes, matching fdc1772.v.
//
// Plain Verilog-2001 so that it simulates in OSS CVC (see sim/i8271).

module i8271
(
	input             clk,         // clkcpu (clock_48)
	input             ce4m,        // 4MHz clock enable in clk
	input             reset,       // active high

	// CPU bus. Reads are combinational from registers; read side effects and writes
	// happen on cpu_ce (the end of the CPU cycle), when the CPU latches its data.
	input             cpu_ce,
	input             cpu_sel,     // &FE80-&FE87
	input             cpu_rw,
	input       [2:0] cpu_addr,
	input       [7:0] cpu_din,
	output reg  [7:0] cpu_dout,
	output            nmi,         // active high

	// Disc images (VD 0 = drive 0, VD 1 = drive 1)
	input       [1:0] img_mounted,
	input      [31:0] img_size,

	// Shared SD port and sector buffer in fdc1772.v
	output reg        ext_drive,
	output reg [31:0] ext_lba,
	output reg        ext_rd,
	output reg        ext_wr,
	input             ext_busy,    // clksys domain
	output reg  [8:0] buf_addr,
	output reg  [7:0] buf_din,
	output reg        buf_we,
	input       [7:0] buf_q,

	// Front panel
	output            drive_led,
	output reg        seek_tog,    // drive sounds: changes once per head movement
	output reg  [6:0] seek_n,      //   tracks moved by it
	output     [23:0] disk_info    // same layout as fdc1772.v, for disk_osd.v
);

// ------------------------------------------------------------------ status bits
localparam ST_BUSY  = 7;
localparam ST_CMDF  = 6;
localparam ST_PARF  = 5;
localparam ST_RESF  = 4;
localparam ST_INT   = 3;
localparam ST_NDMA  = 2;

// ------------------------------------------------------------------ result codes
localparam R_OK        = 8'h00;
localparam R_NOT_FOUND = 8'h18;

// ------------------------------------------------------------------ timing (4MHz ticks)
localparam BYTE_TICKS  = 9'd255;      // 64us per byte (FM, 125kbit/s)
localparam CRC_TICKS   = 10'd511;     // 128us: the two CRC bytes after the last data byte
localparam MS_TICKS    = 12'd3999;    // 1ms
localparam REV_TICKS   = 20'd799999;  // 200ms per revolution (300rpm)
localparam IDX_TICKS   = 20'd16000;   // 4ms index pulse
localparam SECT_TICKS  = 20'd80000;   // 20ms per sector slot (10 per revolution)

// ------------------------------------------------------------------ image info
reg  [1:0] present = 2'b00;
reg  [1:0] dsided  = 2'b00;
reg  [1:0] img_mounted_d;
always @(posedge clk) begin
	img_mounted_d <= img_mounted;
	if (img_mounted[0] & ~img_mounted_d[0]) begin
		present[0] <= |img_size;
		dsided[0]  <= img_size > 32'd409500;
	end
	if (img_mounted[1] & ~img_mounted_d[1]) begin
		present[1] <= |img_size;
		dsided[1]  <= img_size > 32'd409500;
	end
	// Not cleared by reset: BREAK, or the autostart reset that follows mounting an image,
	// must not make the drives look empty (fdc1772.v keeps this state the same way).
end

// ------------------------------------------------------------------ registers
reg  [7:0] status;
reg  [7:0] result;
reg  [7:0] data_out;
reg  [7:0] data_in;
reg  [5:0] cmd;
reg  [7:0] par0, par1, par2, par3, par4;
reg  [2:0] pcnt, preq;
reg  [7:0] drvout;          // drive control output: [7] select 1, [6] select 0, [5] side
reg  [7:0] curtrk0, curtrk1;
reg  [6:0] phys0, phys1;    // physical head position of each drive
reg  [7:0] step_ms, settle_ms, load_ms;
reg  [3:0] unload_revs;

wire       drv       = drvout[7];          // drive 1 when select 1 is active
wire       side      = drvout[5];
wire [6:0] phys      = drv ? phys1 : phys0;
wire [7:0] curtrk    = drv ? curtrk1 : curtrk0;
wire [6:0] new_phys  = (par0 > 8'd81) ? 7'd81 : par0[6:0];

assign nmi = status[ST_INT];

always @(*) begin
	if (cpu_addr[2])              cpu_dout = data_out;
	else if (cpu_addr[1:0] == 2'd0) cpu_dout = status;
	else if (cpu_addr[1:0] == 2'd1) cpu_dout = result;
	else                          cpu_dout = 8'h00;
end

// ------------------------------------------------------------------ rotation, motor
reg [19:0] rev;
reg        motor;
reg [27:0] unload_cnt;
wire       index = motor && (rev < IDX_TICKS);
wire [3:0] rot_sector = (rev < SECT_TICKS*1) ? 4'd0 : (rev < SECT_TICKS*2) ? 4'd1 :
                        (rev < SECT_TICKS*3) ? 4'd2 : (rev < SECT_TICKS*4) ? 4'd3 :
                        (rev < SECT_TICKS*5) ? 4'd4 : (rev < SECT_TICKS*6) ? 4'd5 :
                        (rev < SECT_TICKS*7) ? 4'd6 : (rev < SECT_TICKS*8) ? 4'd7 :
                        (rev < SECT_TICKS*9) ? 4'd8 : 4'd9;

assign drive_led = motor;

// ------------------------------------------------------------------ SD busy sync
reg [1:0] busy_s;
always @(posedge clk) busy_s <= {busy_s[0], ext_busy};
wire sd_busy = busy_s[1];

// ------------------------------------------------------------------ main state machine
localparam S_IDLE      = 5'd0;
localparam S_DELAY     = 5'd1;   // wait delay_ms, then go to next_state
localparam S_SECTOR    = 5'd2;   // start a sector (bounds check, SD read)
localparam S_SD_WAIT   = 5'd3;   // wait for SD transfer, then go to next_state
localparam S_RD_FETCH  = 5'd4;   // read: address the buffer
localparam S_RD_FETCH2 = 5'd5;
localparam S_RD_OFFER  = 5'd6;   // read: byte to CPU, NMI
localparam S_RD_TAKEN  = 5'd7;   // read: wait for the CPU and the byte time
localparam S_WR_ASK    = 5'd8;   // write: ask the CPU for a byte, NMI
localparam S_WR_WAIT   = 5'd9;   // write: wait for the byte and the byte time
localparam S_WR_FLUSH  = 5'd10;  // write: write the block back to the SD card
localparam S_NEXT      = 5'd11;  // next sector or finish
localparam S_DONE      = 5'd12;  // command complete: result, interrupt
localparam S_ID_OFFER  = 5'd13;  // read ID: byte to CPU
localparam S_ID_TAKEN  = 5'd14;
localparam S_VERIFY    = 5'd15;  // verify: time one sector
localparam S_FMT_ASK   = 5'd16;  // format: ask for an ID byte
localparam S_FMT_WAIT  = 5'd17;
localparam S_FMT_FILL  = 5'd18;  // format: read the block holding the sector
localparam S_SD_START  = 5'd19;  // raise the SD request, then S_SD_WAIT
localparam S_FMT_PUT   = 5'd20;  // format: fill the sector with &E5
localparam S_FMT_NEXT  = 5'd21;  // format: next ID
localparam S_FINISH    = 5'd22;  // CRC time, then result and interrupt

localparam OP_READ   = 3'd0;
localparam OP_WRITE  = 3'd1;
localparam OP_VERIFY = 3'd2;
localparam OP_READID = 3'd3;
localparam OP_FORMAT = 3'd4;
localparam OP_SEEK   = 3'd5;

reg  [4:0] state, next_state, sd_next;
reg  [2:0] op;
reg [15:0] delay_ms;
reg [11:0] ms_sub;
reg  [8:0] byte_tick;
reg  [8:0] nbytes;          // bytes per sector for this command (1..256)
reg  [8:0] bcnt;            // bytes done in this sector
reg  [7:0] sector;
reg  [4:0] nleft;           // sectors (or IDs) left
reg  [1:0] idb;             // byte within a 4-byte ID
reg  [7:0] fmt_id;          // sector number from the format ID
reg  [3:0] id_sector;
reg        half;            // which half of the 512-byte block holds the sector
reg        sd_write;        // the pending SD request is a write
reg  [4:0] sd_hold;
reg        cpu_took;        // CPU has read the data register since the last byte
reg        cpu_gave;        // CPU has written the data register since the last request
reg  [3:0] busy_nib;        // 1770-style command nibble for disk_info
reg  [9:0] fin_tick;

// sector index within the image and its validity
wire [11:0] trk_base  = dsided[drv] ? ({5'd0, par0[6:0]} * 12'd20) : ({5'd0, par0[6:0]} * 12'd10);
wire [11:0] sect_idx  = trk_base + ((dsided[drv] && side) ? 12'd10 : 12'd0) + {4'd0, sector};
wire        sect_ok   = present[drv] && (par0 < 8'd80) && (sector < 8'd10) && (!side || dsided[drv]);

// seek time in ms: steps * step rate, plus settle when the head moved, plus head load
// when the motor was off
wire  [7:0] steps     = (par0 > curtrk) ? (par0 - curtrk) : (curtrk - par0);
wire [15:0] seek_ms   = steps * step_ms + ((steps != 0) ? settle_ms : 8'd0) + (motor ? 8'd0 : load_ms);

// CPU events, taken at the end of the CPU cycle
wire ev   = cpu_ce & cpu_sel;
wire ev_w = ev & ~cpu_rw;
wire ev_r = ev &  cpu_rw;

// Completion goes through S_FINISH: a real 8271 reads the two CRC bytes (128us) after
// the last data byte before it interrupts. That gap also matters to the 6502, which only
// samples NMI once per cycle: if the interrupt dropped (CPU reads the last byte) and rose
// again within a cycle, the CPU would never see the edge and the completion NMI would be
// lost. DFS starts the next track of a multi-track load from that NMI.
task finish(input [7:0] res);
begin
	result   <= res;
	fin_tick <= CRC_TICKS;
	state    <= S_FINISH;
end
endtask

always @(posedge clk) begin
	buf_we <= 1'b0;

	// rotation and motor
	if (ce4m) begin
		if (motor) rev <= (rev == REV_TICKS) ? 20'd0 : rev + 20'd1;
		if (state == S_IDLE && motor) begin
			if (unload_cnt != 0) unload_cnt <= unload_cnt - 28'd1;
			else begin
				motor <= 1'b0;
				drvout[7:6] <= 2'b00;
			end
		end
	end

	// ---------------------------------------------------------- CPU accesses
	if (ev_r && cpu_addr[2]) begin
		status[ST_INT]  <= 1'b0;
		status[ST_NDMA] <= 1'b0;
		cpu_took <= 1'b1;
	end
	if (ev_r && !cpu_addr[2] && cpu_addr[1:0] == 2'd1) begin
		status[ST_RESF] <= 1'b0;
		status[ST_INT]  <= 1'b0;
	end
	if (ev_w && cpu_addr[2]) begin
		data_in  <= cpu_din;
		status[ST_INT]  <= 1'b0;
		status[ST_NDMA] <= 1'b0;
		cpu_gave <= 1'b1;
	end

	// command register
	if (ev_w && !cpu_addr[2] && cpu_addr[1:0] == 2'd0 && !status[ST_BUSY]) begin
		cmd  <= cpu_din[5:0];
		pcnt <= 3'd0;
		if (cpu_din[5:0] < 6'h2C) drvout[7:6] <= cpu_din[7:6];
		status <= 8'h00 | (8'd1 << ST_BUSY);
		case (cpu_din[5:0])
			6'h2C:                                   preq <= 3'd0; // read drive status
			6'h29, 6'h3D:                            preq <= 3'd1; // seek, read special
			6'h0A, 6'h0E, 6'h12, 6'h16, 6'h1E, 6'h3A: preq <= 3'd2;
			6'h0B, 6'h0F, 6'h13, 6'h17, 6'h1F, 6'h1B: preq <= 3'd3;
			6'h35:                                   preq <= 3'd4; // specify
			6'h00, 6'h04, 6'h23:                     preq <= 3'd5; // scan, format
			default:                                 preq <= 3'd0;
		endcase
		// commands with no parameters run straight away (next cycle)
		state <= S_IDLE;
	end

	// parameter register
	if (ev_w && !cpu_addr[2] && cpu_addr[1:0] == 2'd1 && status[ST_BUSY] && pcnt < preq) begin
		case (pcnt)
			3'd0: par0 <= cpu_din;
			3'd1: par1 <= cpu_din;
			3'd2: par2 <= cpu_din;
			3'd3: par3 <= cpu_din;
			default: par4 <= cpu_din;
		endcase
		pcnt <= pcnt + 3'd1;
	end

	// ---------------------------------------------------------- command start
	// Runs once all parameters are in (status busy, no transfer in progress).
	if (state == S_IDLE && status[ST_BUSY] && pcnt == preq && !ev) begin
		pcnt <= 3'd7;  // so it starts only once
		case (cmd)
			6'h2C: begin // read drive status
				result <= 8'h80 | (drvout[7] ? 8'h40 : 8'h00) | (index ? 8'h10 : 8'h00) |
				          (drvout[6] ? 8'h04 : 8'h00) | (phys == 7'd0 ? 8'h02 : 8'h00);
				status <= 8'h00 | (8'd1 << ST_RESF);
			end
			6'h35: begin // specify
				if (par0 == 8'h0D) begin
					step_ms     <= par1;
					settle_ms   <= par2;
					unload_revs <= par3[7:4];
					load_ms     <= {3'd0, par3[3:0], 1'b0};   // 2ms units
				end
				status <= 8'h00;
			end
			6'h3A: begin // write special register
				case (par0)
					8'h12: curtrk0 <= par1;
					8'h1A: curtrk1 <= par1;
					8'h23: drvout  <= par1;
					default: ; // mode, bad tracks, scan registers: accepted and ignored
				endcase
				status <= 8'h00;
			end
			6'h3D: begin // read special register
				case (par0)
					8'h12:   result <= curtrk0;
					8'h1A:   result <= curtrk1;
					8'h23:   result <= drvout;
					default: result <= 8'h00;
				endcase
				status <= 8'h00 | (8'd1 << ST_RESF);
			end
			6'h29, 6'h0A, 6'h0B, 6'h0E, 6'h0F, 6'h12, 6'h13, 6'h16, 6'h17,
			6'h1E, 6'h1F, 6'h1B, 6'h23: begin
				case (cmd)
					6'h29:                      begin op <= OP_SEEK;   busy_nib <= 4'h1; end
					6'h0A, 6'h0B, 6'h0E, 6'h0F: begin op <= OP_WRITE;  busy_nib <= 4'hA; end
					6'h1E, 6'h1F:               begin op <= OP_VERIFY; busy_nib <= 4'h8; end
					6'h1B:                      begin op <= OP_READID; busy_nib <= 4'hE; end
					6'h23:                      begin op <= OP_FORMAT; busy_nib <= 4'hF; end
					default:                    begin op <= OP_READ;   busy_nib <= 4'h8; end
				endcase
				// single-sector commands (bit 0 clear) move one 128-byte sector
				if (cmd[0] == 1'b0 && cmd != 6'h1B && cmd != 6'h29 && cmd != 6'h23) begin
					nleft  <= 5'd1;
					nbytes <= 9'd128;
				end else begin
					nleft  <= par2[4:0];
					nbytes <= (par2[7:5] == 3'd0) ? 9'd128 : 9'd256;
				end
				sector     <= par1;
				result     <= R_OK;
				id_sector  <= rot_sector;
				motor      <= 1'b1;
				// seek: update the track register and the head position
				if (new_phys != phys) begin
					seek_n   <= (new_phys > phys) ? new_phys - phys : phys - new_phys;
					seek_tog <= ~seek_tog;
				end
				if (drv) begin curtrk1 <= par0; phys1 <= (par0 > 8'd81) ? 7'd81 : par0[6:0]; end
				else     begin curtrk0 <= par0; phys0 <= (par0 > 8'd81) ? 7'd81 : par0[6:0]; end
				delay_ms   <= seek_ms;
				ms_sub     <= MS_TICKS;
				next_state <= (cmd == 6'h29) ? S_DONE : S_SECTOR;
				state      <= S_DELAY;
			end
			default: begin // unsupported (scan) or unknown
				result <= R_NOT_FOUND;
				status <= 8'h00 | (8'd1 << ST_RESF) | (8'd1 << ST_INT);
			end
		endcase
	end

	// ---------------------------------------------------------- transfer state machine
	case (state)
		S_IDLE: ;

		S_DELAY:
			if (ce4m) begin
				if (ms_sub != 0) ms_sub <= ms_sub - 12'd1;
				else if (delay_ms != 0) begin
					delay_ms <= delay_ms - 16'd1;
					ms_sub   <= MS_TICKS;
				end else
					state <= next_state;
			end

		S_SECTOR:
			if (op == OP_READID) begin
				// IDs come from the track as it spins past: track, head 0, sector, size 1
				if (!present[drv] || (side && !dsided[drv])) begin
					delay_ms <= 16'd400; ms_sub <= MS_TICKS; next_state <= S_DONE;
					result <= R_NOT_FOUND; state <= S_DELAY;
				end else if (nleft == 0) begin
					finish(R_OK);
				end else begin
					idb       <= 2'd0;
					byte_tick <= BYTE_TICKS;
					state     <= S_ID_TAKEN;
					cpu_took  <= 1'b1;
				end
			end else if (op == OP_FORMAT) begin
				if (!present[drv] || (side && !dsided[drv])) begin
					delay_ms <= 16'd400; ms_sub <= MS_TICKS; next_state <= S_DONE;
					result <= R_NOT_FOUND; state <= S_DELAY;
				end else if (nleft == 0) begin
					finish(R_OK);
				end else begin
					idb       <= 2'd0;
					byte_tick <= BYTE_TICKS;
					state     <= S_FMT_ASK;
				end
			end else if (!sect_ok) begin
				// two revolutions looking for the sector, then "sector not found"
				delay_ms <= 16'd400; ms_sub <= MS_TICKS; next_state <= S_DONE;
				result <= R_NOT_FOUND; state <= S_DELAY;
			end else if (op == OP_VERIFY) begin
				byte_tick <= BYTE_TICKS;
				bcnt      <= 9'd0;
				state     <= S_VERIFY;
			end else begin
				ext_drive <= drv;
				ext_lba   <= {21'd0, sect_idx[11:1]};
				half      <= sect_idx[0];
				sd_write  <= 1'b0;
				sd_next   <= (op == OP_WRITE) ? S_WR_ASK : S_RD_FETCH;
				bcnt      <= 9'd0;
				byte_tick <= BYTE_TICKS;
				cpu_gave  <= 1'b0;
				state     <= S_SD_START;
			end

		S_SD_START: begin
			if (sd_write) ext_wr <= 1'b1; else ext_rd <= 1'b1;
			sd_hold <= 5'd31;
			state   <= S_SD_WAIT;
		end

		S_SD_WAIT:
			if (sd_hold != 0) sd_hold <= sd_hold - 5'd1;
			else if (!sd_busy) begin
				ext_rd <= 1'b0;
				ext_wr <= 1'b0;
				state  <= sd_next;
			end

		// ---- read: one byte per 64us, one NMI per byte
		S_RD_FETCH: begin
			buf_addr <= {half, bcnt[7:0]};
			state    <= S_RD_FETCH2;
		end
		S_RD_FETCH2: state <= S_RD_OFFER;   // buffer read latency
		S_RD_OFFER:
			if (ce4m) begin
				if (byte_tick != 0) byte_tick <= byte_tick - 9'd1;
				else begin
					data_out <= buf_q;
					status   <= 8'h00 | (8'd1 << ST_BUSY) | (8'd1 << ST_INT) | (8'd1 << ST_NDMA);
					cpu_took <= 1'b0;
					bcnt     <= bcnt + 9'd1;
					byte_tick <= BYTE_TICKS;
					state    <= S_RD_TAKEN;
				end
			end
		S_RD_TAKEN:
			if (cpu_took) begin
				if (bcnt == nbytes) state <= S_NEXT;
				else                state <= S_RD_FETCH;
			end

		// ---- write: ask for a byte, store it, write the block when the sector is full
		S_WR_ASK:
			if (ce4m) begin
				if (byte_tick != 0) byte_tick <= byte_tick - 9'd1;
				else begin
					status   <= 8'h00 | (8'd1 << ST_BUSY) | (8'd1 << ST_INT) | (8'd1 << ST_NDMA);
					cpu_gave <= 1'b0;
					byte_tick <= BYTE_TICKS;
					state    <= S_WR_WAIT;
				end
			end
		S_WR_WAIT:
			if (cpu_gave) begin
				buf_addr <= {half, bcnt[7:0]};
				buf_din  <= data_in;
				buf_we   <= 1'b1;
				bcnt     <= bcnt + 9'd1;
				if (bcnt + 9'd1 == nbytes) state <= S_WR_FLUSH;
				else                       state <= S_WR_ASK;
			end
		S_WR_FLUSH: begin
			sd_write <= 1'b1;
			sd_next  <= S_NEXT;
			state    <= S_SD_START;
		end

		// ---- verify: no data transfer, just the time to pass the sector
		S_VERIFY:
			if (ce4m) begin
				if (byte_tick != 0) byte_tick <= byte_tick - 9'd1;
				else begin
					byte_tick <= BYTE_TICKS;
					bcnt      <= bcnt + 9'd1;
					if (bcnt + 9'd1 == nbytes) state <= S_NEXT;
				end
			end

		S_NEXT: begin
			if (nleft <= 5'd1) finish(R_OK);
			else begin
				nleft  <= nleft - 5'd1;
				sector <= sector + 8'd1;
				state  <= S_SECTOR;
			end
		end

		S_DONE: finish(result);

		S_FINISH:
			if (ce4m) begin
				if (fin_tick != 0) fin_tick <= fin_tick - 10'd1;
				else begin
					status     <= 8'h00 | (8'd1 << ST_RESF) | (8'd1 << ST_INT);
					state      <= S_IDLE;
					unload_cnt <= (unload_revs == 4'd0 ? 28'd1 : {24'd0, unload_revs}) * (REV_TICKS + 28'd1);
				end
			end

		// ---- read ID: 4 bytes per ID, one NMI per byte
		S_ID_TAKEN:
			if (cpu_took && ce4m) begin
				if (byte_tick != 0) byte_tick <= byte_tick - 9'd1;
				else begin
					case (idb)
						2'd0: data_out <= par0;
						2'd1: data_out <= 8'h00;
						2'd2: data_out <= {4'd0, id_sector};
						default: data_out <= 8'h01;
					endcase
					status    <= 8'h00 | (8'd1 << ST_BUSY) | (8'd1 << ST_INT) | (8'd1 << ST_NDMA);
					cpu_took  <= 1'b0;
					byte_tick <= BYTE_TICKS;
					idb       <= idb + 2'd1;
					if (idb == 2'd3) begin
						id_sector <= (id_sector == 4'd9) ? 4'd0 : id_sector + 4'd1;
						nleft     <= nleft - 5'd1;
						state     <= S_ID_OFFER;
					end
				end
			end

		// ---- format: collect each 4-byte ID, then fill that sector with &E5
		S_FMT_ASK:
			if (ce4m) begin
				if (byte_tick != 0) byte_tick <= byte_tick - 9'd1;
				else begin
					status   <= 8'h00 | (8'd1 << ST_BUSY) | (8'd1 << ST_INT) | (8'd1 << ST_NDMA);
					cpu_gave <= 1'b0;
					byte_tick <= BYTE_TICKS;
					state    <= S_FMT_WAIT;
				end
			end
		S_FMT_WAIT:
			if (cpu_gave) begin
				idb <= idb + 2'd1;
				if (idb == 2'd2) fmt_id <= data_in;
				if (idb == 2'd3) begin
					sector <= fmt_id;
					state  <= S_FMT_FILL;
				end else
					state <= S_FMT_ASK;
			end
		S_FMT_FILL:
			// read the block, fill the sector, write it back; skip IDs outside the image
			if (sect_ok) begin
				ext_drive <= drv;
				ext_lba   <= {21'd0, sect_idx[11:1]};
				half      <= sect_idx[0];
				sd_write  <= 1'b0;
				sd_next   <= S_FMT_PUT;
				bcnt      <= 9'd0;
				state     <= S_SD_START;
			end else
				state <= S_FMT_NEXT;
		S_FMT_PUT: begin
			buf_addr <= {half, bcnt[7:0]};
			buf_din  <= 8'hE5;
			buf_we   <= 1'b1;
			bcnt     <= bcnt + 9'd1;
			if (bcnt == 9'd255) begin
				sd_write <= 1'b1;
				sd_next  <= S_FMT_NEXT;
				state    <= S_SD_START;
			end
		end
		S_FMT_NEXT: begin
			nleft <= nleft - 5'd1;
			state <= S_SECTOR;
		end

		S_ID_OFFER:
			if (cpu_took) state <= S_SECTOR;

		default: state <= S_IDLE;
	endcase

	// 8271 reset register, or system reset
	if ((ev_w && !cpu_addr[2] && cpu_addr[1:0] == 2'd2 && cpu_din[0]) || reset) begin
		status    <= 8'h00;
		result    <= 8'h00;
		state     <= S_IDLE;
		pcnt      <= 3'd0;
		preq      <= 3'd0;
		cmd       <= 6'h3F;
		curtrk0   <= 8'd0;
		curtrk1   <= 8'd0;
		ext_rd    <= 1'b0;
		ext_wr    <= 1'b0;
		cpu_took  <= 1'b1;
		cpu_gave  <= 1'b0;
	end
	if (reset) begin
		drvout      <= 8'h00;
		phys0       <= 7'd0;
		phys1       <= 7'd0;
		seek_tog    <= 1'b0;
		seek_n      <= 7'd0;
		motor       <= 1'b0;
		rev         <= 20'd0;
		unload_cnt  <= 28'd0;
		step_ms     <= 8'd12;
		settle_ms   <= 8'd10;
		load_ms     <= 8'd16;
		unload_revs <= 4'd12;
		busy_nib    <= 4'd0;
	end
end

// disk_info layout (fdc1772.v): [7:0] sector, [14:8] head track, [18:15] command
// nibble (1770 coding), [19] side (inverted), [20] drive 1, [21] busy, [22] LED,
// [23] a drive is selected
assign disk_info = { motor, motor, status[ST_BUSY], drv, ~side, busy_nib, phys, sector };

endmodule
