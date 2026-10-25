// Decompressor test: gzip files from make_gz_tests.py are placed in a DDR3
// model, inflated through tape_ddr, and the output is compared with zlib's.
`timescale 1ns/1ps

module tb_inflate;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    localparam [24:0] IN_BASE = 25'h100000;     // 1MB (16MB in the core)

    reg         start = 0;
    reg  [24:0] in_len = 0;
    wire        busy, done, err;
    wire [24:0] out_len;

    wire        i_rd, w_rd, o_wr, o_busy;
    wire [24:0] i_addr, w_addr;
    wire [7:0]  i_data, w_data;
    wire        i_valid, w_valid;
    wire [21:0] o_wa;
    wire [63:0] o_wd;
    wire [7:0]  o_be;

    inflate dut (
        .clk(clk), .rst(rst), .start(start), .in_base(IN_BASE), .in_len(in_len),
        .busy(busy), .done(done), .err(err), .out_len(out_len),
        .in_rd(i_rd), .in_addr(i_addr), .in_data(i_data), .in_valid(i_valid),
        .win_rd(w_rd), .win_addr(w_addr), .win_data(w_data), .win_valid(w_valid),
        .out_wr(o_wr), .out_wa(o_wa), .out_wd(o_wd), .out_be(o_be), .out_busy(o_busy));

    wire        DDRAM_BUSY;
    wire [7:0]  DDRAM_BURSTCNT;
    wire [28:0] DDRAM_ADDR;
    reg  [63:0] DDRAM_DOUT;
    reg         DDRAM_DOUT_READY;
    wire        DDRAM_RD, DDRAM_WE;
    wire [63:0] DDRAM_DIN;
    wire [7:0]  DDRAM_BE;

    tape_ddr tddr (
        .clk(clk), .rst(rst),
        .w0_wr(1'b0), .w0_addr(25'd0), .w0_data(8'd0), .w0_busy(),
        .w1_wr(o_wr), .w1_wa(o_wa), .w1_data(o_wd), .w1_be(o_be), .w1_busy(o_busy),
        .r0_rd(1'b0), .r0_addr(25'd0), .r0_data(), .r0_valid(),
        .r1_rd(i_rd), .r1_addr(i_addr), .r1_data(i_data), .r1_valid(i_valid),
        .r2_rd(w_rd), .r2_addr(w_addr), .r2_data(w_data), .r2_valid(w_valid),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE));

    // ---------------- DDR3 model ----------------
    reg [63:0] ddr [0:262143];          // 2MB
    integer    dseed = 3;
    reg        busy_r = 0;
    assign DDRAM_BUSY = busy_r;
    reg [17:0] rq;
    integer    lat = -1;
    integer    k;
    reg [63:0] wtmp;

    always @(posedge clk) begin
        busy_r <= (($random(dseed) & 3) == 0);
        DDRAM_DOUT_READY <= 1'b0;
        if (!busy_r) begin
            if (DDRAM_WE) begin
                wtmp = ddr[DDRAM_ADDR[17:0]];
                for (k = 0; k < 8; k = k + 1)
                    if (DDRAM_BE[k]) wtmp[k*8 +: 8] = DDRAM_DIN[k*8 +: 8];
                ddr[DDRAM_ADDR[17:0]] = wtmp;
            end
            if (DDRAM_RD) begin
                rq  <= DDRAM_ADDR[17:0];
                lat <= 10 + ($random(dseed) & 15);
            end
        end
        if (lat > 0) lat <= lat - 1;
        if (lat == 0) begin
            DDRAM_DOUT <= ddr[rq];
            DDRAM_DOUT_READY <= 1'b1;
            lat <= -1;
        end
    end

    // ---------------- cases ----------------
    reg [7:0]  gzb [0:262143];  // up to 256KB
    reg [7:0]  raw [0:262143];
    integer    glen, rlen, ncases, c, i, e, nerr;
    reg [8*16:1] fn;
    reg [63:0] w;
    reg [7:0]  cnt [0:0];

    initial begin
        nerr = 0;
        $readmemh("gz_count.hex", cnt);
        ncases = cnt[0];
        repeat (10) @(posedge clk);
        rst = 0;
        for (c = 0; c < ncases; c = c + 1) begin
            for (i = 0; i < 262144; i = i + 1) begin gzb[i] = 8'hxx; raw[i] = 8'hxx; end
            $sformat(fn, "gz_%0d.hex", c);  $readmemh(fn, gzb);
            $sformat(fn, "raw_%0d.hex", c); $readmemh(fn, raw);
            glen = 0; while (gzb[glen] !== 8'hxx) glen = glen + 1;
            rlen = 0; while (raw[rlen] !== 8'hxx) rlen = rlen + 1;

            // output area: junk, so missing writes show up
            for (i = 0; i < 32768; i = i + 1) ddr[i] = 64'hA5A5_5A5A_DEAD_BEEF ^ i;
            // compressed file at IN_BASE
            for (i = 0; i < glen; i = i + 8) begin
                w = 64'd0;
                for (k = 0; k < 8; k = k + 1)
                    if (i + k < glen) w[k*8 +: 8] = gzb[i + k];
                ddr[(IN_BASE >> 3) + (i >> 3)] = w;
            end

            @(negedge clk); in_len = glen; start = 1;
            @(negedge clk); start = 0;
            while (!done) @(negedge clk);

            e = 0;
            if (err) begin $display("  case %0d: decompressor reported an error", c); e = e + 1; end
            else if (out_len != rlen) begin $display("  case %0d: length %0d, expected %0d", c, out_len, rlen); e = e + 1; end
            else
                for (i = 0; i < rlen; i = i + 1)
                    if (ddr[i >> 3][(i & 7)*8 +: 8] !== raw[i]) begin
                        if (e < 4) $display("  case %0d: byte %0d = %02x, expected %02x", c, i,
                                            ddr[i >> 3][(i & 7)*8 +: 8], raw[i]);
                        e = e + 1;
                    end
            $display("case %0d (%0d -> %0d bytes, %0d us): %0s", c, glen, rlen, $time / 1000, e ? "FAIL" : "PASS");
            nerr = nerr + (e != 0);
        end

        // corrupt data must end in an error, not hang
        for (i = 0; i < 64; i = i + 1) ddr[(IN_BASE >> 3) + i] = 64'h1F8B_0800_FFFF_FFFF ^ (i * 64'h0123_4567_89AB);
        ddr[IN_BASE >> 3] = 64'h0000_0000_0008_8B1F;   // valid header, garbage body
        @(negedge clk); in_len = 512; start = 1;
        @(negedge clk); start = 0;
        i = 0;
        while (!done && i < 2000000) begin @(negedge clk); i = i + 1; end
        if (done && err) $display("corrupt stream: PASS (error reported)");
        else if (done)   $display("corrupt stream: PASS (finished, %0d bytes)", out_len);
        else begin $display("corrupt stream: FAIL (hung)"); nerr = nerr + 1; end

        if (nerr == 0) $display("ALL TESTS PASSED");
        else           $display("FAILURES: %0d", nerr);
        $finish;
    end

endmodule
