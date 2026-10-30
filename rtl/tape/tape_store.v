// Tape image store for BeebFpga: download, optional gunzip, playback reads
//
//  * A menu download is written to DDR3 at STAGE (+16MB in the core).
//  * If it starts 1F 8B (gzip), it is decompressed to DDR3 offset 0 and the
//    player reads the result from there; otherwise the player reads the
//    download directly. Most UEFs from the archive sites are gzipped.
//  * If decompression fails, the player is given the original file, which
//    it recognises as gzip and refuses (so the menu can say so).
//
// size is 0 while downloading or decompressing, then the playable length;
// the player starts when it becomes non-zero. eject forgets the image (size 0,
// and a decompression still running is ignored) until the next download.
//
// The drive sounds file (sounds.rom, menu index 2) is stored at SND_BASE, the top
// 128KB of the window, and read back through s_*. A tape image is limited to
// SND_BASE - STAGE bytes (just under 16MB) so the two never overlap.

module tape_store #(
    parameter [24:0] STAGE    = 25'h1000000,
    parameter [24:0] SND_BASE = 25'h1FE0000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        eject,

    // download
    input  wire        dl_active,
    input  wire        dl_wr,
    input  wire [24:0] dl_addr,
    input  wire  [7:0] dl_data,
    output wire        dl_wait,

    // drive sounds download (same dl_wr/dl_addr/dl_data) and reads
    input  wire        snd_active,
    input  wire        s_rd,
    input  wire [16:0] s_addr,
    output wire  [7:0] s_data,
    output wire        s_valid,

    // player
    input  wire        p_rd,
    input  wire [24:0] p_addr,
    output wire  [7:0] p_data,
    output wire        p_valid,

    output reg  [24:0] size,
    output wire        inflating,
    output reg         inflate_err,

    // DDRAM
    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output wire        DDRAM_RD,
    output wire [63:0] DDRAM_DIN,
    output wire  [7:0] DDRAM_BE,
    output wire        DDRAM_WE
);

    reg  [24:0] len;
    reg  [7:0]  b0, b1;
    reg         dl_d;
    reg  [24:0] base;
    reg         ejected;
    reg         inf_start;

    wire        inf_busy, inf_done, inf_err;
    wire [24:0] inf_len;
    wire        i_rd, w_rd, o_wr, o_busy, i_valid, w_valid;
    wire [24:0] i_addr, w_addr;
    wire [7:0]  i_data, w_data;
    wire [21:0] o_wa;
    wire [63:0] o_wd;
    wire [7:0]  o_be;

    assign inflating = inf_busy | inf_start;

    always @(posedge clk) begin
        inf_start <= 1'b0;
        dl_d <= dl_active;
        if (rst) begin
            size <= 25'd0; base <= STAGE; len <= 25'd0; inflate_err <= 1'b0; ejected <= 1'b0;
        end else if (eject) begin
            size <= 25'd0; inflate_err <= 1'b0; ejected <= 1'b1;
        end else begin
            if (dl_active) begin
                size <= 25'd0;
                inflate_err <= 1'b0;
                ejected <= 1'b0;
                if (dl_wr) begin
                    len <= dl_addr + 25'd1;
                    if (dl_addr == 25'd0) b0 <= dl_data;
                    if (dl_addr == 25'd1) b1 <= dl_data;
                end
            end else if (dl_d) begin
                // download finished
                if (len >= 25'd18 && b0 == 8'h1F && b1 == 8'h8B)
                    inf_start <= 1'b1;
                else begin
                    base <= STAGE; size <= len;
                end
            end
            if (inf_done && !ejected) begin
                if (inf_err || inf_len == 25'd0) begin
                    inflate_err <= 1'b1; base <= STAGE; size <= len;
                end else begin
                    base <= 25'd0; size <= inf_len;
                end
            end
        end
    end

    inflate inflate (
        .clk(clk), .rst(rst), .start(inf_start), .in_base(STAGE), .in_len(len),
        .busy(inf_busy), .done(inf_done), .err(inf_err), .out_len(inf_len),
        .in_rd(i_rd), .in_addr(i_addr), .in_data(i_data), .in_valid(i_valid),
        .win_rd(w_rd), .win_addr(w_addr), .win_data(w_data), .win_valid(w_valid),
        .out_wr(o_wr), .out_wa(o_wa), .out_wd(o_wd), .out_be(o_be), .out_busy(o_busy));

    tape_ddr ddr (
        .clk(clk), .rst(rst),
        .w0_wr(dl_wr & ((dl_active & (dl_addr < SND_BASE - STAGE)) | (snd_active & (dl_addr < 25'h20000)))),
        .w0_addr(snd_active ? SND_BASE + dl_addr : STAGE + dl_addr), .w0_data(dl_data), .w0_busy(dl_wait),
        .w1_wr(o_wr), .w1_wa(o_wa), .w1_data(o_wd), .w1_be(o_be), .w1_busy(o_busy),
        .r0_rd(p_rd), .r0_addr(base + p_addr), .r0_data(p_data), .r0_valid(p_valid),
        .r1_rd(i_rd), .r1_addr(i_addr), .r1_data(i_data), .r1_valid(i_valid),
        .r2_rd(w_rd), .r2_addr(w_addr), .r2_data(w_data), .r2_valid(w_valid),
        .r3_rd(s_rd), .r3_addr(SND_BASE + {8'd0, s_addr}), .r3_data(s_data), .r3_valid(s_valid),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE));

endmodule
