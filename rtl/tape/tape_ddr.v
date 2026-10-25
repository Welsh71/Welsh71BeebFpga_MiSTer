// Tape image storage in DDR3 (MiSTer DDRAM port) for BeebFpga
//
// DDR3 is used because the core's block RAM is full, and every MiSTer has it.
// Region: byte address 0x30000000 + addr (the area MiSTer leaves for cores);
// addresses here are byte offsets within a 32MB window.
//
// Ports (one request outstanding per port; requests are strobes):
//   w0  byte writes          - menu download
//   w1  64-bit word writes   - decompressor output (with byte enables)
//   r0  byte reads           - tape player
//   r1  byte reads           - decompressor input
//   r2  byte reads           - decompressor history window
// Each read port has its own one-word cache, so sequential reading costs one
// DDR3 access per eight bytes. Every write updates any cache holding that
// word, so readers never see stale data. Writes are served before reads.

module tape_ddr (
    input  wire        clk,
    input  wire        rst,

    input  wire        w0_wr,
    input  wire [24:0] w0_addr,
    input  wire  [7:0] w0_data,
    output wire        w0_busy,

    input  wire        w1_wr,
    input  wire [21:0] w1_wa,
    input  wire [63:0] w1_data,
    input  wire  [7:0] w1_be,
    output wire        w1_busy,

    input  wire        r0_rd,
    input  wire [24:0] r0_addr,
    output reg   [7:0] r0_data,
    output reg         r0_valid,

    input  wire        r1_rd,
    input  wire [24:0] r1_addr,
    output reg   [7:0] r1_data,
    output reg         r1_valid,

    input  wire        r2_rd,
    input  wire [24:0] r2_addr,
    output reg   [7:0] r2_data,
    output reg         r2_valid,

    // DDRAM
    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output reg         DDRAM_RD,
    output reg  [63:0] DDRAM_DIN,
    output reg   [7:0] DDRAM_BE,
    output reg         DDRAM_WE
);

    localparam S_IDLE = 2'd0, S_WRITE = 2'd1, S_READ = 2'd2, S_WAIT = 2'd3;

    reg  [1:0]  state;
    reg  [21:0] word_addr;
    reg  [1:0]  fill;               // which cache a read fills

    reg         p0w, p1w;
    reg  [24:0] a0w;
    reg  [7:0]  d0w;
    reg  [21:0] a1w;
    reg  [63:0] d1w;
    reg  [7:0]  b1w;

    reg  [2:0]  pr;                 // pending reads
    reg  [24:0] ra0, ra1, ra2;

    reg  [63:0] c0, c1, c2;
    reg  [21:0] t0, t1, t2;
    reg  [2:0]  cok;

    assign DDRAM_BURSTCNT = 8'd1;
    assign DDRAM_ADDR     = {4'b0011, 3'b000, word_addr};
    // busy until the write has been accepted by DDR3
    assign w0_busy        = p0w | (state == S_WRITE);
    assign w1_busy        = p1w | (state == S_WRITE);

    function [63:0] merge;
        input [63:0] old;
        input [63:0] nw;
        input [7:0]  be;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                merge[i*8 +: 8] = be[i] ? nw[i*8 +: 8] : old[i*8 +: 8];
        end
    endfunction

    wire hit0 = cok[0] && t0 == ra0[24:3];
    wire hit1 = cok[1] && t1 == ra1[24:3];
    wire hit2 = cok[2] && t2 == ra2[24:3];

    always @(posedge clk) begin
        r0_valid <= 1'b0;
        r1_valid <= 1'b0;
        r2_valid <= 1'b0;
        if (rst) begin
            state <= S_IDLE; DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0;
            p0w <= 1'b0; p1w <= 1'b0; pr <= 3'd0; cok <= 3'd0;
        end else begin
            if (w0_wr) begin p0w <= 1'b1; a0w <= w0_addr; d0w <= w0_data; end
            if (w1_wr) begin p1w <= 1'b1; a1w <= w1_wa; d1w <= w1_data; b1w <= w1_be; end
            if (r0_rd) begin pr[0] <= 1'b1; ra0 <= r0_addr; end
            if (r1_rd) begin pr[1] <= 1'b1; ra1 <= r1_addr; end
            if (r2_rd) begin pr[2] <= 1'b1; ra2 <= r2_addr; end

            case (state)
            S_IDLE:
                if (p0w || p1w) begin
                    // one write; keep the caches coherent
                    if (p0w) begin
                        p0w       <= 1'b0;
                        word_addr <= a0w[24:3];
                        DDRAM_DIN <= {8{d0w}};
                        DDRAM_BE  <= 8'd1 << a0w[2:0];
                        if (cok[0] && t0 == a0w[24:3]) c0 <= merge(c0, {8{d0w}}, 8'd1 << a0w[2:0]);
                        if (cok[1] && t1 == a0w[24:3]) c1 <= merge(c1, {8{d0w}}, 8'd1 << a0w[2:0]);
                        if (cok[2] && t2 == a0w[24:3]) c2 <= merge(c2, {8{d0w}}, 8'd1 << a0w[2:0]);
                    end else begin
                        p1w       <= 1'b0;
                        word_addr <= a1w;
                        DDRAM_DIN <= d1w;
                        DDRAM_BE  <= b1w;
                        if (cok[0] && t0 == a1w) c0 <= merge(c0, d1w, b1w);
                        if (cok[1] && t1 == a1w) c1 <= merge(c1, d1w, b1w);
                        if (cok[2] && t2 == a1w) c2 <= merge(c2, d1w, b1w);
                    end
                    DDRAM_WE <= 1'b1;
                    state    <= S_WRITE;
                end else if (pr[2]) begin
                    if (hit2) begin
                        pr[2] <= 1'b0; r2_data <= c2[ra2[2:0]*8 +: 8]; r2_valid <= 1'b1;
                    end else begin
                        word_addr <= ra2[24:3]; fill <= 2'd2; DDRAM_RD <= 1'b1; state <= S_READ;
                    end
                end else if (pr[1]) begin
                    if (hit1) begin
                        pr[1] <= 1'b0; r1_data <= c1[ra1[2:0]*8 +: 8]; r1_valid <= 1'b1;
                    end else begin
                        word_addr <= ra1[24:3]; fill <= 2'd1; DDRAM_RD <= 1'b1; state <= S_READ;
                    end
                end else if (pr[0]) begin
                    if (hit0) begin
                        pr[0] <= 1'b0; r0_data <= c0[ra0[2:0]*8 +: 8]; r0_valid <= 1'b1;
                    end else begin
                        word_addr <= ra0[24:3]; fill <= 2'd0; DDRAM_RD <= 1'b1; state <= S_READ;
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
                    case (fill)
                        2'd0: begin c0 <= DDRAM_DOUT; t0 <= word_addr; end
                        2'd1: begin c1 <= DDRAM_DOUT; t1 <= word_addr; end
                        default: begin c2 <= DDRAM_DOUT; t2 <= word_addr; end
                    endcase
                    cok[fill] <= 1'b1;
                    state <= S_IDLE;            // the pending read now hits
                end
            endcase
        end
    end

endmodule
