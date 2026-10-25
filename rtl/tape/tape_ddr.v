// Tape image storage in DDR3 (MiSTer DDRAM port) for BeebFpga
//
// The tape file is written a byte at a time while it downloads from the menu
// and read back sequentially by the player. DDR3 is used because the core's
// block RAM is full, and every MiSTer has it (no SDRAM module needed).
//
// Region: byte address 0x30000000 + addr (the area MiSTer leaves for cores).
// Writes are single 64-bit beats with one byte enabled. Reads fetch a 64-bit
// word into a one-word cache, so sequential playback costs one DDR read per
// eight bytes. Tape data rates are tiny, so no bursts are needed.

module tape_ddr (
    input  wire        clk,
    input  wire        rst,

    // Download side
    input  wire        wr,          // one-clk strobe
    input  wire [24:0] waddr,
    input  wire  [7:0] wdata,
    output wire        wbusy,       // to ioctl_wait

    // Player side
    input  wire        rd,          // one-clk strobe
    input  wire [24:0] raddr,
    output reg   [7:0] rdata,
    output reg         rvalid,      // one-clk pulse with rdata

    // DDRAM
    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output reg         DDRAM_RD,
    output wire [63:0] DDRAM_DIN,
    output wire  [7:0] DDRAM_BE,
    output reg         DDRAM_WE
);

    localparam S_IDLE = 2'd0, S_WRITE = 2'd1, S_READ = 2'd2, S_WAIT = 2'd3;

    reg  [1:0]  state;
    reg  [21:0] word_addr;          // 64-bit word within the 32MB window
    reg  [7:0]  w_byte;
    reg  [2:0]  w_lane;

    reg         wr_pend;
    reg  [24:0] wr_a;
    reg  [7:0]  wr_d;
    reg         rd_pend;
    reg  [24:0] rd_a;

    reg  [63:0] cache;
    reg  [21:0] cache_tag;
    reg         cache_ok;

    assign DDRAM_BURSTCNT = 8'd1;
    assign DDRAM_ADDR     = {4'b0011, 3'b000, word_addr};
    assign DDRAM_DIN      = {8{w_byte}};
    assign DDRAM_BE       = 8'd1 << w_lane;
    assign wbusy          = wr_pend | (state == S_WRITE);

    function [7:0] lane;
        input [63:0] w;
        input [2:0]  i;
        lane = w[i*8 +: 8];
    endfunction

    always @(posedge clk) begin
        rvalid <= 1'b0;
        if (rst) begin
            state <= S_IDLE; DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0;
            wr_pend <= 1'b0; rd_pend <= 1'b0; cache_ok <= 1'b0;
        end else begin
            if (wr) begin wr_pend <= 1'b1; wr_a <= waddr; wr_d <= wdata; end
            if (rd) begin rd_pend <= 1'b1; rd_a <= raddr; end

            case (state)
            S_IDLE:
                if (wr_pend) begin
                    wr_pend   <= 1'b0;
                    word_addr <= wr_a[24:3];
                    w_lane    <= wr_a[2:0];
                    w_byte    <= wr_d;
                    DDRAM_WE  <= 1'b1;
                    state     <= S_WRITE;
                    // keep the cache coherent
                    if (cache_ok && cache_tag == wr_a[24:3])
                        cache[wr_a[2:0]*8 +: 8] <= wr_d;
                end else if (rd_pend) begin
                    if (cache_ok && cache_tag == rd_a[24:3]) begin
                        rd_pend <= 1'b0;
                        rdata   <= lane(cache, rd_a[2:0]);
                        rvalid  <= 1'b1;
                    end else begin
                        word_addr <= rd_a[24:3];
                        DDRAM_RD  <= 1'b1;
                        state     <= S_READ;
                    end
                end
            S_WRITE:
                if (!DDRAM_BUSY) begin
                    DDRAM_WE <= 1'b0;
                    state    <= S_IDLE;
                end
            S_READ:
                if (!DDRAM_BUSY) begin
                    DDRAM_RD <= 1'b0;
                    state    <= S_WAIT;
                end
            default: // S_WAIT
                if (DDRAM_DOUT_READY) begin
                    cache     <= DDRAM_DOUT;
                    cache_tag <= word_addr;
                    cache_ok  <= 1'b1;
                    state     <= S_IDLE;     // the pending read now hits
                end
            endcase
        end
    end

endmodule
