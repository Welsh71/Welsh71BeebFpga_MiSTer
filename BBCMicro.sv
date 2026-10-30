//============================================================================
//  BBCMicro port to MiSTer
//  Copyright (C) 2018-2019 Sorgelig
//  Copyright (C) 2022 Iain Sharp
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
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);


// Uncomment line below to reduce memory requirements by eliminating Co-processor CPU memory and sideways RAM
// This option is required when building the ICEDebugger on the DE10 Nano. Otherwise, leave undefined.
// `define use_small_memory

// ADC_BUS drives the I/O board's audio input for tape loading (ltc2308_tape below)
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = '1;
assign {SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
// assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign DDRAM_CLK = clk_sys;   // DDR3 holds the tape image (tape_ddr)
 
wire tape_motor, tape_adc, tape_adc_act, tape_wbusy, tape_play;
reg  tape_info_req;
wire tape_in_sel, tape_led;
wire [1:0] tape_fmt;
reg  [7:0] tape_info;
wire tape_playing, tape_out, tape_out_en, tape_err, tape_inflating;
wire [15:0] core_audio_l, core_audio_r;
// Drive sounds (drive_sound below)
wire        fdd_step, fdd_seek;
wire  [6:0] fdd_seek_n;
wire        snd_dl;
wire        snd_rd, snd_rvalid, sounds_loaded;
wire [16:0] snd_raddr;
wire  [7:0] snd_rdata;
reg   [3:0] snd_msg;              // "Not a drive sounds file", after a sounds download
reg   [2:0] snd_dl_d;

assign LED_USER  = ioctl_download | (vsd_sel & sd_act) | tape_led;
wire   fdd_led;  // 1770 drive LED: lit while the drive motor runs, as on a real BBC drive
wire [23:0] fdd_info; // 1770 state for the on-screen disk status
assign LED_DISK  = {1'b1,(~vsd_sel & sd_act) | fdd_led};
assign LED_POWER = 0;
assign BUTTONS   = 0;
assign VGA_SCALER= 0;
assign HDMI_FREEZE = 0;
assign VGA_DISABLE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

 assign SDRAM_DQ[15:0] = 'Z;
// assign SDRAM_DQ[0] = HSync;
// assign SDRAM_DQ[1] = VSync;
// assign SDRAM_DQ[2] = HBlank;
// assign SDRAM_DQ[3] = VBlank;
// assign SDRAM_DQ[4] = ce_pix;
// assign SDRAM_DQ[5] = CLK_VIDEO;
// assign SDRAM_DQ[6] = red_vid;


wire [1:0] ar = status[14:13];
video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[16:15])
);

// Configuration bits:
// See https://github.com/MiSTer-devel/Main_MiSTer/wiki/Core-configuration-string
// 02-03   - Scandouble settings
// 04 ( 4) - BBC B or Master
// 05-06   - Co processor
// 07-09   - Default video mode
// A (10) - Mouse as Joystick
// B (11) - Swap joysticks
// C (12) - Autostart
// D-E   - Aspect ratio
// F-G   - Image scaling
// H      - Reserved - MMFS or Floppy
// P-R (25-27) - Master filesystem: MMFSv1, MMFSv2, DFS, MMFSv1&DFS, MMFSv2&DFS
// o2-o4 (34-36) - Model B filesystem: DFS 1.2 (8271), DFS 1770, MMFSv1, MMFSv2,
//                 MMFSv1 & DFS 1.2, MMFSv1 & DFS 1770, MMFSv2 & DFS 1.2, MMFSv2 & DFS 1770
// S (28)- M7 Video opt
// T (29)- Master shadow video mode on boot
// U (30)- Master default FS
// J (19)- Rewind tape (trigger)
// K (20)- Tape input: File / ADC (I/O board audio-in)
// L-M (21-22)- Tape sound: Low / Medium / Loud / Off
// N (23)- Eject tape (trigger)
// o0-o1 (32-33) - On-screen disk status: Off / On / On activity
// o5-o6 (37-38) - Drive sounds: Off / Low / Medium / Loud (default Off)
// o7 (39)       - Tape relay click: Off / On (default Off)
// File index 1 - UEF tape image
// File index 2 - sounds.rom (drive and relay samples from BeebEm), reloaded at every core start
//
// Mask index : 
// 0 - MMFS Active
// 1 - DFS active
// 2 - Master selected
// 3 - Master selected and both MMFS and DFS active
// 4 - Model B selected

`include "build_id.v" 
parameter AUTO_START_OPT = 12;
parameter FILE_SYS_OPT_L = 25;
parameter FILE_SYS_OPT_H = 27;
parameter B_FS_OPT_L = 34;
parameter B_FS_OPT_H = 36;
parameter M7_VIDEO_OPT = 28;
parameter M128_SHADOW_OPT = 29;
parameter M128_FS_OPT = 30;

parameter CONF_STR = {
	"BBCMicro;;",
	"-;",
	"h4o24,Filesystem,DFS 1.2 only,DFS 1770 only,MMFSv1,MMFSv2,MMFSv1 & DFS 1.2,MMFSv1 & DFS 1770,MMFSv2 & DFS 1.2,MMFSv2 & DFS 1770;",
	"h2OPR,Filesystem,MMFSv1,MMFSv2,DFS,MMFSv1&DFS,MMFSv2&DFS;",
	"h0S0,VHDIMGMMB;", // Allow .VHD or .MMB files to be loaded (MMFSv1) or .IMG (MMFS v2)
	"h1S1,SSDDSD;",
	"h1S2,SSDDSD;",
	"OC,Autostart,No,Yes;",
	"o01,Disk Status,Off,On,On Activity;",
	"-;",
	"F1,UEF,Load Tape;",
	"TJ,Rewind Tape;",
	"TN,Eject Tape;",
	"OK,Tape Input,File,ADC;",
	"OLM,Tape Sound,Low,Medium,Loud,Off;",
	"o7,Tape Relay Click,Off,On;",
	"-;",
	"FC2,ROM,Load Drive Sounds;",
	"o56,Drive Sounds,Off,Low,Medium,Loud;",
	"-;",
	"O4,Model,B(MOS6502),Master(R65SC12);",
	"O56,Co-Processor,None,MOS65C02;",
	"O79,Default video mode,0,1,2,3,4,5,6,7;",
	"h2OT,Default video mem.,Shadow,Main;",
	"h3OU,Default Filesystem,MMFS,DFS;",
	"-;",
	"ODE,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O23,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"OFG,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"OS,M7 Analogue Video,576p,576i;",
	"-;",
	"OA,Mouse as Joystick,Yes,No;",
	"OB,Swap Joysticks,No,Yes;",
	"-;",
	"R0,Reset;",
	"JA,Fire;",
	"I,Compressed UEF could not be decompressed,No UEF header - playing as raw bitstream,UEF tape ready,Tape ejected,Not a drive sounds file (sounds.rom);",
	"V,PSMain-",`BUILD_DATE
};

wire model_master = status[4];

// Filesystem choice. The Master keeps its original list (status 25-27, so saved settings
// carry over); the Model B has its own list (status 34-36) that adds the Intel 8271 with
// DFS 1.20, its default. fs_*(master) decodes either list for a given model.
wire [2:0] fs_m = status[FILE_SYS_OPT_H:FILE_SYS_OPT_L];
wire [2:0] fs_b = status[B_FS_OPT_H:B_FS_OPT_L];
function fs_mmfsv1(input master, input [2:0] m, input [2:0] b); fs_mmfsv1 = master ? (m == 0 || m == 3) : (b == 2 || b == 4 || b == 5); endfunction
function fs_mmfsv2(input master, input [2:0] m, input [2:0] b); fs_mmfsv2 = master ? (m == 1 || m == 4) : (b == 3 || b == 6 || b == 7); endfunction
function fs_dfs   (input master, input [2:0] m, input [2:0] b); fs_dfs    = master ? (m >= 2)            : (b != 2 && b != 3);           endfunction
function fs_8271  (input master,                input [2:0] b); fs_8271   = !master && (b == 0 || b == 4 || b == 6);                   endfunction

// Menu visibility follows the model selected in the menu. The machine itself follows the
// model latched at reset (m128): see mmfsv1/mmfsv2/dfs/fdc_8271 below.
wire osd_mmfs = fs_mmfsv1(model_master, fs_m, fs_b) || fs_mmfsv2(model_master, fs_m, fs_b);
wire osd_dfs  = fs_dfs(model_master, fs_m, fs_b);


/////////////////  CLOCKS  ////////////////////////

wire clk_sys; // IES: 96MHz (32 * 3), (24 * 4)
wire clk_48 = clk_sys & ce_48;
wire clk_32 = clk_sys & ce_32;
wire clk_24 = clk_sys & ce_24;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

(* direct_enable=1 *) reg ce_32;
(* direct_enable=1 *) reg ce_48;
(* direct_enable=1 *) reg ce_24;
always @(negedge clk_sys) begin
	reg [1:0] div32;
	reg [0:0] div48;
	reg [1:0] div24;
	
	div48 <= div48 + 1'd1;
	ce_48 <= !div48;
	
	div24 <= div24 + 1'd1;
	ce_24 <= !div24;
	
	div32 <= div32 + 1'd1;
	if(div32 == 2) div32 <= 0;
	ce_32 <= !div32;
	
	
end


/////////////////  HPS  ///////////////////////////
// IES: Hard Processor System

wire [127:0] status;
wire  [1:0] buttons;

wire [15:0] joy1, joy2;
wire  [7:0] joy1_x,joy1_y,joy2_x,joy2_y;

wire [10:0] ps2_key;
wire [24:0] ps2_mouse;

wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [7:0]  ioctl_dout;
wire        forced_scandoubler;
wire [21:0] gamma_bus;

wire [31:0] sd_lba[3];
wire [2:0]  sd_rd;
wire [2:0]  sd_wr;
wire [2:0]  sd_ack;
wire [12:0] sd_buff_addr;
wire [7:0]  sd_buff_dout;
wire [7:0]  sd_buff_din[3];
wire        sd_buff_wr;
wire [2:0]  img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire        sd_ack_conf;

wire [64:0] RTC;

hps_io #(.CONF_STR(CONF_STR),.VDNUM(3),.BLKSZ(2)) hps_io // IES Updated from c244


(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	//.conf_str(CONF_STR),

	.buttons(buttons),
	.status(status),
	.status_menumask({~model_master, (model_master && osd_dfs && osd_mmfs), model_master, osd_dfs, osd_mmfs}),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),

	.RTC(RTC),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(tape_wbusy),
	.info_req(tape_info_req),
	.info(tape_info),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.joystick_0(joy1),
	.joystick_1(joy2),
	.joystick_l_analog_0({joy1_y,joy1_x}),
	.joystick_l_analog_1({joy2_y,joy2_x})
);

/////////////////  RESET  /////////////////////////

wire reset = RESET | status[0] | buttons[1] | (status[AUTO_START_OPT] & img_mounted);

////////////////  MEMORY  /////////////////////////

reg m128 = 0;
always @(posedge clk_sys) if(reset_req) m128 <= model_master;

// Filesystem for the running machine (see fs_* above), so changing the menu never swaps
// ROMs or the disc controller under a running machine.
wire mmfsv1 = fs_mmfsv1(m128, fs_m, fs_b);
wire mmfsv2 = fs_mmfsv2(m128, fs_m, fs_b);
wire mmfs   = mmfsv1 || mmfsv2;
wire dfs    = fs_dfs(m128, fs_m, fs_b);
reg  fdc_8271 = 1'b1;   // Model B: Intel 8271 + DFS 1.20, else WD1770 + DFS 2.26
always @(posedge clk_sys) if(reset_req) fdc_8271 <= fs_8271(model_master, fs_b);

wire        mem_we_n;
wire [18:0] mem_addr;
wire  [7:0] mem_din;

reg  [18:0] rom_addr;
wire [7:0] rom_dout;
reg  [7:0] rom_data;

// Two ROMs: the 16 x 16K image (roms/rom.mif, unchanged since 2022) and DFS 1.20 for the
// 8271 as its own 16K ROM (roms/dnfs.mif), addressed as ROM bank 16. A single 17-bank
// ROM failed to fit: Quartus mis-planned its block RAM and pushed the OSD and HQ2x
// memories into flip-flops.
(* ram_init_file = "roms/rom.mif" *) reg [7:0] rom[16 * 16384];
(* ram_init_file = "roms/dnfs.mif" *) reg [7:0] dnfs_rom[16384];
// ROM is only written while reset is held (ioctl download), so the write port uses ioctl_addr alone.
// Muxing rom_addr in here tied ext_A to every ROM block's write enable and failed timing.
always @(posedge clk_sys) if(!ioctl_index && ioctl_wr && reset) rom[ioctl_addr[17:0]] <= ioctl_dout;
// Read address registered in clk_sys: ext_A changes on gated clk_48 and fans out to ~250
// ROM blocks through the rom_addr lookup. A memory slot lasts 12 clk_sys and data is
// latched at its end, so the extra cycle of read latency is safe.
(* maxfan = 24 *) reg [18:0] rom_addr_r;   // drives every ROM block: let Quartus duplicate it
always @(posedge clk_sys) rom_addr_r <= rom_addr;
reg  [7:0] rom_dout_main, rom_dout_dnfs;
reg        rom_hi;
always @(posedge clk_sys) begin
	rom_dout_main <= rom[rom_addr_r[17:0]];
	rom_dout_dnfs <= dnfs_rom[rom_addr_r[13:0]];
	rom_hi        <= rom_addr_r[18];
end
assign rom_dout = rom_hi ? rom_dout_dnfs : rom_dout_main;


// Beeb ROM Images
// NOTE: Slots 0-3 and 9-15 correspond to the equivalent paged ROMS in the BBC
// Slots 4-7 are presented as RAM and these ROMS are not in the paged ROM space
// The ROM in slot 4 becomes the high ROM used for the OS
// Slot 8 is special. In the BBC B it is split ROM/RAM used for MMFS. In MASTER it is normal paged ROM

// 00 00xx empty     
// 00 01xx empty     
// 00 10xx empty     
// 00 11xx bbcb/Acorn-DFS-2.26.rom (1770), or bbcb/DNFS-1.20.rom (8271, ROM image bank 16)
// 01 00xx bbcb/os12.rom   - High ROM     
// 01 01xx empty     
// 01 10xx empty     
// 01 11xx empty     
// 10 00xx bbcb/swmmfs.rom    - Must be in slot 8 because of split RAM/ROM in that slot     
// 10 01xx empty     
// 10 10xx empty     
// 10 11xx empty     
// 11 00xx empty     
// 11 01xx empty     
// 11 10xx bbcb/rammaster6
// 11 11xx bbcb/basic2.rom       

// Master ROM Images

// 00 00xx empty     
// 00 01xx empty     
// 00 10xx empty  
// 00 11xx m128/mammfs.rom       
// 01 00xx m128/mos.rom    - High ROM      
// 01 01xx empty     
// 01 10xx empty     
// 01 11xx empty     
// 10 00xx empty     
// 10 01xx m128/dfs.rom          
// 10 10xx m128/viewsht.rom      
// 10 11xx m128/edit.rom         
// 11 00xx m128/basic4.rom       
// 11 01xx m128/adfs.rom         
// 11 10xx m128/view.rom         
// 11 11xx m128/terminal.rom      

always_comb begin
	rom_addr[13:0] = mem_addr[13:0];
	case({m128, mem_addr[17:14]})
		'b0_00_11: rom_addr[18:14] = fdc_8271 ? 16 : 4; //bbcb/DNFS-1.20.rom (8271, dnfs_rom) or bbcb/Acorn-DFS-2.26.rom (1770)
		'b0_01_00: rom_addr[18:14] =  0; //bbcb/os12.rom         
		'b0_10_00: rom_addr[18:14] = mmfsv1 ?  1 : 14; //bbcb/swmmfs.rom (v1) or //bbcb/swmmfs.rom (v2) - Must be in slot 8 because of split RAM/ROM in that slot
		'b0_11_10: rom_addr[18:14] =  2; //bbcb/ram_master_v6.rom 
		'b0_11_11: rom_addr[18:14] =  3; //bbcb/basic2.rom           
		'b1_00_11: rom_addr[18:14] = mmfsv1 ?  5 : 15;  //m128/mammfs.rom  (v1) //m128/mammfs.rom (v2)	
		'b1_01_00: rom_addr[18:14] =  6; //m128/mos.rom          
		'b1_10_01: rom_addr[18:14] =  7; //m128/dfs.rom          
		'b1_10_10: rom_addr[18:14] =  8; //m128/viewsht.rom      
		'b1_10_11: rom_addr[18:14] =  9; //m128/edit.rom         
		'b1_11_00: rom_addr[18:14] = 10; //m128/basic4.rom       
		'b1_11_01: rom_addr[18:14] = 11; //m128/adfs.rom         
		'b1_11_10: rom_addr[18:14] = 12; //m128/view.rom         
		'b1_11_11: rom_addr[18:14] = 13; //m128/terminal.rom      
		  default: rom_addr[18:14] =  0;
	endcase
end

always_comb begin
	case({m128, mem_addr[17:14]})
		'b0_01_00,
		'b0_11_10,
		'b0_11_11,	
		'b1_01_00,
		'b1_10_10,
		'b1_10_11,
		'b1_11_00,
		'b1_11_01,
		'b1_11_10,
		'b1_11_11: rom_data = rom_dout;
		'b0_00_11,
		'b1_10_01: rom_data = (dfs) ? rom_dout : 0; // Enable/disable DFS
		'b0_10_00,
		'b1_00_11: rom_data = (mmfs) ? rom_dout : 0; // Enable/disable MMFS
		  default: rom_data = 0;
	endcase
end

reg [7:0] ram_dout;

// RAM bank 12 (SWMMFS workspace at B600-BFFF, Model B only) shares bank 11 (16K shadow
// memory at 4000-7FFF, Master only). The two are never used in the same model, and
// changing model resets the machine, so one 16K bank serves both. This frees 16 M10K
// blocks (used by the DFS 1.20 ROM for the 8271).
function [17:0] ram_index(input [17:0] a);
	ram_index = (a[17:14] == 4'd12) ? {4'd11, a[13:0]} : a;
endfunction

// RAM write port registered in clk_sys. ext_A/ext_nWE/ext_Din come from the gated clk_48
// domain and previously drove the write-enable decode of ~200 M10K blocks combinationally,
// with the write landing on the first clk_sys edge (single-cycle path, failed at 96MHz).
// One extra clk_sys of write latency is invisible to the 2MHz CPU and video.
reg        ram_we_r;
reg [17:0] ram_waddr_r;
reg  [7:0] ram_wdata_r;
always @(posedge clk_sys) begin
	ram_we_r    <= mem_addr[18] & old_we & ~mem_we_n;
	ram_waddr_r <= ram_index(mem_addr[17:0]);
	ram_wdata_r <= mem_din;
end

// Read address registered for the same reason as the ROM (see rom_addr_r).
reg [17:0] ram_raddr_r;
always @(posedge clk_sys) ram_raddr_r <= ram_index(mem_addr[17:0]);


// See definition of use_small_memory for explanation
`ifdef use_small_memory
	reg [7:0] ram[5 * 16384];
	always @(posedge clk_sys) if(ram_we_r & ram_waddr_r[17]) ram[ram_waddr_r[16:0]] <= ram_wdata_r;
	always @(posedge clk_sys) if(ram_raddr_r[17]) ram_dout <= ram[ram_raddr_r[16:0]]; else ram_dout <=0;
`else
	reg [7:0] ram[196608]; // 12 x 16K: bank 12 is folded onto bank 11 by ram_index
	always @(posedge clk_sys) if(ram_we_r) ram[ram_waddr_r] <= ram_wdata_r;
	always @(posedge clk_sys) ram_dout <= ram[ram_raddr_r];
`endif


reg old_we;
always @(posedge clk_sys) old_we <= mem_we_n;

// 16k blocks of RAM (not all RAM in each block is used)
// 00 00xx  Co Processor
// 00 01xx  Co Processor
// 00 10xx  Co Processor
// 00 11xx  Co Processor
// 01 00xx  RAM Slot 4
// 01 01xx  RAM Slot 5
// 01 10xx  RAM Slot 6
// 01 11xx  RAM Slot 7
// 10 00xx  Main memory
// 10 01xx  Main memory
// 10 1000  Filing System RAM (4K, at C000-CFFF) (unused in Beeb Mode)
// 10 1001  Filing System RAM (4K, at D000-DFFF) (unused in Beeb Mode)
// 10 1010  Private RAM (4K, at 8000-8FFF)       (unused in Beeb Mode)
// 10 1011  Shadow memory (4K, at 3000-3FFF)     (unused in Beeb Mode)
// 10 11xx  Shadow memory (16K, at 4000-7FFF)    (unused in Beeb Mode)
// 11 00xx  RAM Slot 8 (B600-BFFF) For SWMMFS - BBC B Only. Stored in bank 10 11xx (see ram_index)
// 11 01xx  unused
// 11 10xx  unused
// 11 11xx  unused


///////////////////////////////////////////////////

wire reset_req = reset;

wire [7:0] joya_x = 8'hFF - {~ax[7],ax[6:0]};
wire [7:0] joya_y = 8'hFF - {~ay[7],ay[6:0]};
wire [7:0] joyb_x = 8'hFF - {~joy2_x[7],joy2_x[6:0]};
wire [7:0] joyb_y = 8'hFF - {~joy2_y[7],joy2_y[6:0]};


wire       ce_pix;

bbc_micro_core BBCMicro(
    .clksys(clk_sys),
	.clock_32(clk_32),
	.clock_48(clk_48),
	.clock_avr(clk_24),

	.hard_reset_n(~reset),
//	.reset_req(reset_req),

    .ps2_mse_clk (),
    .ps2_mse_data(),

	 .mister_key(ps2_key),
	 .mister_mouse(status[10] ? ps2_mouse : 25'd0),

	.video_sel(clk_sel),
	.video_cepix(ce_pix),
//	.video_cerate(ce_rate),
	.video_red(red_vid),
	.video_green(green_vid),
	.video_blue(blue_vid),
	.video_vblank(VBlank),
	.video_hblank(HBlank),
	.video_vsync(VSync),
	.video_hsync(HSync),
	.m7_video_opt(status[M7_VIDEO_OPT]),
	.odd_field(odd_field),

	.audio_l(core_audio_l),
	.audio_r(core_audio_r),

	.ext_nOE(),
	.ext_nWE(mem_we_n),
	.ext_nCS(),
	.ext_A(mem_addr),
	.ext_Dout(mem_addr[18] ? ram_dout : rom_data),
	.ext_Din(mem_din),

	.SDMISO(sdmiso),
	.SDCLK(sdclk),
	.SDMOSI(sdmosi),
	.SDSS(sdss),

	.caps_led(),
	.shift_led(),
	
	.RTC(RTC),

	.keyb_dip({4'b0000, status[AUTO_START_OPT], ~status[9:7]}),
	
	// cmos_options stores extra options that would normally be in CMOS on Master 128
	// Format:
	// b0 = Use shadow memory for default mode (1 = Yes)
	// b4-1 = ROM # for default file system: 3 for MMFS or 9 for DFS
	.cmos_options({(~dfs || (mmfs && dfs && ~status[M128_FS_OPT]))?4'd3:4'd9, ~status[M128_SHADOW_OPT]}),
	
	.ext_keyb_led1(),
	.ext_keyb_led2(),
	.ext_keyb_led3(),
	.ext_keyb_1mhz(),
	.ext_keyb_en_n(),
	.ext_keyb_pa(),
	.ext_keyb_rst_n(),
	.ext_keyb_ca2(),
	.ext_keyb_pa7(),
	
	.ps2config(),

	.joystick1_x(    status[11] ? {joyb_x,joyb_x[7:4]} : {joya_x,joya_x[7:4]}),
	.joystick1_y(    status[11] ? {joyb_y,joyb_y[7:4]} : {joya_y,joya_y[7:4]}),
	.joystick1_fire( status[11] ? ~joy2[4] : ~af),

	.joystick2_x(   ~status[11] ? {joya_x,joya_x[7:4]} : {joyb_x,joyb_x[7:4]}),
	.joystick2_y(   ~status[11] ? {joya_y,joya_y[7:4]} : {joyb_y,joyb_y[7:4]}),
	.joystick2_fire(~status[11] ? ~joy2[4] : ~af),
	
	.avr_reset(reset),
	.avr_RxD(UART_RXD),
	.avr_TxD(UART_TXD),

	.cpu_addr(), // IES: Debugging
	.m128_mode(m128),
	.copro_mode(|status[6:5]),
	
	.fdc_8271       ( fdc_8271       ),
	.img_mounted    ( img_mounted[2:1] ),
	.img_size       ( img_size       ),
	.sd_lba         ( fd_sd_lba      ),
	.sd_rd          ( sd_rd[2:1]       ),
	.sd_wr          ( sd_wr[2:1]       ),
	.sd_ack         ( sd_ack[2:1]      ),
	.sd_buff_addr   ( sd_buff_addr[8:0]   ),
	.sd_dout        ( sd_buff_dout   ),
	.sd_din         ( fd_sd_buff_din ),
	.sd_dout_strobe ( sd_buff_wr ),
	
	.p_spi_ssel(),
	.p_spi_sck(),
	.p_spi_mosi(),
	.p_spi_miso(),
	.p_irq_b(),
	.p_nmi_b(),
	.p_rst_b(),
	.ext_tube_r_nw(),
	.ext_tube_nrst(),
	.ext_tube_ntube(),
	.ext_tube_phi2(),
	.ext_tube_a(),
	.ext_tube_di(),
	.ext_tube_do(),

	.tape_in(tape_in_sel),
	.tape_out(tape_out),
	.tape_out_en(tape_out_en),
	.tape_motor(tape_motor),
	.floppy_led(fdd_led),
	.floppy_info(fdd_info),
	.floppy_step(fdd_step),
	.floppy_seek(fdd_seek),
	.floppy_seek_n(fdd_seek_n),
	.tape_carrier(),

	.test()
);

// Tape input from the I/O board's audio-in (ADC), squared with hysteresis.
// Play a tape, or a tape-image WAV, into it and type *TAPE / CHAIN"".
ltc2308_tape #(.CLK_RATE(96000000)) ltc2308_tape
(
	.reset(reset),
	.clk(clk_sys),
	.ADC_BUS(ADC_BUS),
	.dout(tape_adc),
	.active(tape_adc_act),
	.adc_sync(),
	.adc_data()
);

assign tape_in_sel = status[20] ? tape_adc : tape_play;

// Tape: LED steady while the motor is on, blinking (~4Hz) while the tape is
// actually playing, flicker while decompressing, fast blink (~16Hz) if a
// compressed UEF could not be decompressed.
reg [24:0] tape_blink;
always @(posedge clk_sys) tape_blink <= tape_blink + 1'd1;
assign tape_led = tape_inflating ? tape_blink[21] :
                tape_err     ? tape_blink[22] :
                tape_playing ? tape_blink[24] :
                tape_motor;

// Menu message once the player has identified a newly loaded image
reg [1:0] tape_fmt_d;
reg       tape_ej_d;
reg [3:0] tape_ej_msg;          // "Tape ejected": info set first, request a few clks later
always @(posedge clk_sys) begin
	tape_fmt_d <= tape_fmt;
	tape_ej_d  <= status[23];
	if (status[23] & ~tape_ej_d) tape_ej_msg <= 4'd15;
	else if (tape_ej_msg != 4'd0) tape_ej_msg <= tape_ej_msg - 4'd1;
	// sounds_loaded settles one clk after the download ends; check two clks later
	snd_dl_d <= {snd_dl_d[1:0], snd_dl};
	if (snd_dl_d[2] & ~snd_dl_d[1] & ~sounds_loaded) snd_msg <= 4'd15;
	else if (snd_msg != 4'd0) snd_msg <= snd_msg - 4'd1;
	if (tape_ej_msg != 4'd0)
		tape_info <= 8'd4;          // tape ejected
	else if (snd_msg != 4'd0)
		tape_info <= 8'd5;          // sounds.rom not recognised
	else case (tape_fmt)
		2'd3: tape_info <= 8'd1;    // gzip that failed to decompress
		2'd2: tape_info <= 8'd2;    // no UEF header
		default: tape_info <= 8'd3; // UEF ready
	endcase
	// one clk after tape_info is valid; hps_io latches info on the rising edge
	tape_info_req <= ((tape_fmt != 2'd0) && (tape_fmt_d != 2'd0) && (tape_ej_msg == 4'd0) && (snd_msg == 4'd0)) ||
	                 ((tape_ej_msg != 4'd0) && (tape_ej_msg < 4'd12)) ||
	                 ((snd_msg != 4'd0) && (snd_msg < 4'd12) && (tape_ej_msg == 4'd0));
end

// Tape image: "Load Tape" (file index 1) downloads a UEF into DDR3, and the
// player streams it to the Serial ULA while the cassette motor is on.
// gzip-compressed UEFs (most of them) are decompressed in DDR3 first.
wire        tape_dl = ioctl_download && (ioctl_index[5:0] == 6'd1);
assign      snd_dl  = ioctl_download && (ioctl_index[5:0] == 6'd2);
wire        tape_rd, tape_rvalid, tape_inf_err;
wire [24:0] tape_raddr, tape_size;
wire  [7:0] tape_rdata;

tape_store tape_store
(
	.clk(clk_sys),
	.rst(RESET),
	.eject(status[23]),
	.dl_active(tape_dl),
	.dl_wr(ioctl_wr),
	.dl_addr(ioctl_addr),
	.dl_data(ioctl_dout),
	.dl_wait(tape_wbusy),
	.snd_active(snd_dl),
	.s_rd(snd_rd),
	.s_addr(snd_raddr),
	.s_data(snd_rdata),
	.s_valid(snd_rvalid),
	.p_rd(tape_rd),
	.p_addr(tape_raddr),
	.p_data(tape_rdata),
	.p_valid(tape_rvalid),
	.size(tape_size),
	.inflating(tape_inflating),
	.inflate_err(tape_inf_err),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);

tape_player #(.TICK_DIV(4992)) tape_player      // 96MHz / (16MHz/13/64)
(
	.clk(clk_sys),
	.rst(RESET),
	.motor(tape_motor),
	.rewind(status[19] | status[23] | tape_dl),
	.size(tape_size),
	.mem_rd(tape_rd),
	.mem_addr(tape_raddr),
	.mem_data(tape_rdata),
	.mem_valid(tape_rvalid),
	.cas_out(tape_play),
	.playing(tape_playing),
	.error(tape_err),
	.fmt(tape_fmt),
	.position()
);


wire [31:0] fd_sd_lba;
wire [7:0] fd_sd_buff_din;


always @(posedge clk_48)
begin
	// ajs hack for now
	sd_buff_din[1] <= fd_sd_buff_din;
	sd_lba[1]      <=  fd_sd_lba;
	sd_buff_din[2] <= fd_sd_buff_din;
	sd_lba[2]      <=fd_sd_lba;

end

wire [7:0] audio_sn;

// Drive sounds and cassette relay clicks (BeebEm's samples, from sounds.rom in DDR3).
// The controller signals come from the gated clk_48 domain: register them here.
reg  [1:0] ds_motor_s, ds_step_s, ds_seek_s, ds_relay_s;
reg  [6:0] ds_seek_n;
always @(posedge clk_sys) begin
	ds_motor_s <= {ds_motor_s[0], fdd_led};
	ds_step_s  <= {ds_step_s[0],  fdd_step};
	ds_seek_s  <= {ds_seek_s[0],  fdd_seek};
	ds_relay_s <= {ds_relay_s[0], tape_motor};
	ds_seek_n  <= fdd_seek_n;   // settled long before the toggle reaches ds_seek_s[1]
end

wire signed [17:0] drive_snd;
drive_sound #(.CLK_HZ(96000000)) drive_sound
(
	.clk(clk_sys),
	.rst(RESET),
	.level(status[38:37]),
	.relay_en(status[39]),
	.motor(ds_motor_s[1]),
	.step(ds_step_s[1]),
	.seek_tog(ds_seek_s[1]),
	.seek_n(ds_seek_n),
	.tape_motor(ds_relay_s[1]),
	.dl_active(snd_dl),
	.dl_wr(ioctl_wr),
	.dl_addr(ioctl_addr[16:0]),
	.dl_data(ioctl_dout),
	.mem_rd(snd_rd),
	.mem_addr(snd_raddr),
	.mem_data(snd_rdata),
	.mem_valid(snd_rvalid),
	.loaded(sounds_loaded),
	.audio(drive_snd)
);

// Tape sound: what the Serial ULA is hearing (and any tones it is saving),
// mixed in at a modest level while the motor is on.
reg  [1:0]  tape_snd_s;
always @(posedge clk_sys) tape_snd_s <= {tape_snd_s[0], (tape_in_sel | (tape_out & tape_out_en))};
wire        tape_snd_on = (status[22:21] != 2'd3) & tape_motor;
wire signed [16:0] tape_amp = (status[22:21] == 2'd0) ? 17'sd1024 :     // Low
                              (status[22:21] == 2'd1) ? 17'sd2048 :     // Medium
                                                        17'sd6144;      // Loud
wire signed [16:0] tape_snd = !tape_snd_on ? 17'sd0 : tape_snd_s[1] ? tape_amp : -tape_amp;
// Core audio comes from the gated clk_48 domain (SN76489 and Music 5000 sums are
// combinational after their registers), whose clock tree adds ~6 ns of skew against
// clk_sys. Capture it in its own clk_sys register first (two-cycle path in the SDC:
// clk_48 only ticks on every other clk_sys edge), then mix from registers.
reg  [15:0] core_l_q, core_r_q;
always @(posedge clk_sys) begin
	core_l_q <= core_audio_l;
	core_r_q <= core_audio_r;
end
wire signed [18:0] mix_l = $signed({{3{core_l_q[15]}}, core_l_q}) + tape_snd + drive_snd;
wire signed [18:0] mix_r = $signed({{3{core_r_q[15]}}, core_r_q}) + tape_snd + drive_snd;
wire               sat_l = (mix_l[18:15] != 4'b0000) && (mix_l[18:15] != 4'b1111);
wire               sat_r = (mix_r[18:15] != 4'b0000) && (mix_r[18:15] != 4'b1111);
// registered so the extra adder and saturation stay off the paths into sys/audio_out
reg  [15:0] audio_l_r, audio_r_r;
always @(posedge clk_sys) begin
	audio_l_r <= sat_l ? {mix_l[18], {15{~mix_l[18]}}} : mix_l[15:0];
	audio_r_r <= sat_r ? {mix_r[18], {15{~mix_r[18]}}} : mix_r[15:0];
end
assign AUDIO_L = audio_l_r;
assign AUDIO_R = audio_r_r;

assign AUDIO_MIX = 0;
assign AUDIO_S = 1;


wire [1:0] scale = status[3:2];

wire HSync, VSync, HBlank, VBlank, clk_sel, odd_field;
wire [3:0] red_vid,green_vid,blue_vid;
wire [3:0] red_osd,green_osd,blue_osd;

// On-screen floppy status (track/sector), bottom right of the picture
disk_osd disk_osd
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.hblank_in(HBlank),
	.vblank_in(VBlank),
	.mode(status[33:32]),
	.info(fdd_info),
	.r_in(red_vid), .g_in(green_vid), .b_in(blue_vid),
	.r_out(red_osd), .g_out(green_osd), .b_out(blue_osd)
);

assign CLK_VIDEO = clk_sys;
// GAMMA=0: the core outputs 4 bits per channel (8 colours), so gamma correction has no
// visible effect, and without it the scandoubler and HQ2x run at 4 bits per channel
// (HALF_DEPTH), halving their line buffers. Frees ~15 M10K, needed for the DFS 1.20 ROM.
video_mixer #(640, 1, 0) mixer
(
	// .ce_pix(clock_48 & ce_pix),
	 .ce_pix(ce_pix),
	.freeze_sync(),
	
	.*,

	.hq2x(scale == 1),
	.scandoubler(scale || forced_scandoubler),

	.R(red_osd),
	.G(green_osd),
	.B(blue_osd)
);
// Testing shows that best results for the HDMI output are:
// Mode 0 - 6: Always set VGA_F1 to 0 even when interlaced - therefore and with ~clk_sel
// Mode 7: When using progressive output then set VGA_F1 to 0, when using interlace output set VGA_F1 based on the interlace field
// Registered in clk_sys: odd_field/clk_sel come from the gated clk_48 domain and
// changes once per field (2-cycle multicycle in BBCMicro.sdc).
reg vga_f1_r;
always @(posedge clk_sys) vga_f1_r <= (~clk_sel) & status[M7_VIDEO_OPT] & ~ odd_field;
assign VGA_F1 = vga_f1_r;
assign VGA_SL = scale ? scale - 1'd1 : 2'd0;

//////////////////   SD   ///////////////////

wire sdclk;
wire sdmosi;
wire sdmiso = vsd_sel ? vsdmiso : SD_MISO;
wire sdss;

reg vsd_sel = 0;
always @(posedge clk_sys) if(img_mounted[0]) vsd_sel <= |img_size;

// User VIA SPI outputs are combinational from the gated clk_48 domain. Register them in
// clk_sys so sd_card's SCK edge detector sees clean, timed signals (SPI runs ~1MHz).
reg sdclk_r, sdmosi_r, sdss_r = 1;
always @(posedge clk_sys) begin
	sdclk_r  <= sdclk;
	sdmosi_r <= sdmosi;
	sdss_r   <= sdss;
end

wire vsdmiso;
sd_card #(.WIDE(0)) sd_card // IES Updated from c244
(
	.*,
	
	.img_mounted(img_mounted[0]),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_rd(sd_rd[0]),
	.sd_wr(sd_wr[0]),
	.sd_ack(sd_ack[0]),
	
	.sd_lba(sd_lba[0]),
	.sd_buff_din(sd_buff_din[0]),
	
	.clk_spi(clk_sys),
	.sdhc(1),
	.sck(sdclk_r),
	.ss(sdss_r | ~vsd_sel),
	.mosi(sdmosi_r),
	.miso(vsdmiso)
);

assign SD_CS   = sdss_r   |  vsd_sel;
assign SD_SCK  = sdclk_r  & ~vsd_sel;
assign SD_MOSI = sdmosi_r & ~vsd_sel;

reg sd_act;

always @(posedge clk_sys) begin
	reg old_mosi, old_miso;
	integer timeout = 0;

	old_mosi <= sdmosi_r;
	old_miso <= sdmiso;

	sd_act <= 0;
	if(timeout < 2000000) begin
		timeout <= timeout + 1;
		sd_act <= 1;
	end

	if((old_mosi ^ sdmosi_r) || (old_miso ^ sdmiso)) timeout <= 0;
end


//////////////////   ANALOG AXIS   ///////////////////
reg        emu = 0;
wire [7:0] ax = emu ? mx[7:0] : joy1_x;
wire [7:0] ay = emu ? my[7:0] : joy1_y;
wire [7:0] af = emu ? |ps2_mouse[1:0] : joy1[4];

reg  signed [8:0] mx = 0;
wire signed [8:0] mdx = {ps2_mouse[4],ps2_mouse[4],ps2_mouse[15:9]};
wire signed [8:0] mdx2 = (mdx > 10) ? 9'd10 : (mdx < -10) ? -8'd10 : mdx;
wire signed [8:0] nmx = mx + mdx2;

reg  signed [8:0] my = 0;
wire signed [8:0] mdy = {ps2_mouse[5],ps2_mouse[5],ps2_mouse[23:17]};
wire signed [8:0] mdy2 = (mdy > 10) ? 9'd10 : (mdy < -10) ? -9'd10 : mdy;
wire signed [8:0] nmy = my - mdy2;

always @(posedge clk_sys) begin
	reg old_stb = 0;
	
	old_stb <= ps2_mouse[24];
	if(old_stb != ps2_mouse[24]) begin
		emu <= 1;
		mx <= (nmx < -128) ? -9'd128 : (nmx > 127) ? 9'd127 : nmx;
		my <= (nmy < -128) ? -9'd128 : (nmy > 127) ? 9'd127 : nmy;
	end

	if(joy1 || reset_req || status[10]) begin
		emu <= 0;
		mx <= 0;
		my <= 0;
	end
end

endmodule
