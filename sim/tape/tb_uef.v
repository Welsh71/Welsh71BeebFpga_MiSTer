// End-to-end tape test: image download -> tape_ddr -> DDR3 model ->
// tape_player -> Serial ULA -> 6850 ACIA -> MOS-style interrupt handler.
// Images and expected bytes come from make_uef_tests.py.
`timescale 1ns/1ps

module tb_uef;

    localparam integer CLK_HZ   = 16000000;
    localparam integer BASE_DIV = 13;          // 16MHz / (16MHz/13)
    localparam integer TICK_DIV = 832;         // 16MHz / 19230.77Hz
    localparam real    CLK_PERIOD = 1.0e9 / CLK_HZ;

    reg clk = 0;
    always #(CLK_PERIOD/2.0) clk = ~clk;
    reg rst = 1;

    // ---------------- CPU bus ----------------
    reg [2:0] bcnt = 0;
    always @(posedge clk) bcnt <= bcnt + 1;
    wire bus_en = (bcnt == 3'd7);
    reg       cs_acia = 0, cs_ula = 0, rw = 1, rs = 0;
    reg [7:0] din = 0;
    wire [7:0] acia_do;
    wire irq;

    wire rx_tick, tx_tick, a_rxd, a_dcd, a_cts, a_txd, a_rts, motor;
    wire cas;

    acia6850 acia (
        .clk(clk), .rst(rst), .bus_en(bus_en), .cs(cs_acia), .rw(rw), .rs(rs), .din(din),
        .dout(acia_do), .irq(irq), .rx_tick(rx_tick), .tx_tick(tx_tick), .rxd(a_rxd),
        .dcd(a_dcd), .cts(a_cts), .txd(a_txd), .rts(a_rts));

    serial_ula #(.CLK_HZ(CLK_HZ), .BASE_DIV(BASE_DIV)) ula (
        .clk(clk), .rst(rst), .bus_en(bus_en), .cs(cs_ula), .rw(rw), .din(din), .ctrl(),
        .motor(motor), .acia_rx_tick(rx_tick), .acia_tx_tick(tx_tick), .acia_rxd(a_rxd),
        .acia_dcd(a_dcd), .acia_cts(a_cts), .acia_txd(a_txd), .acia_rts(a_rts),
        .cas_in(cas), .cas_out(), .cas_out_en(), .rs423_rxd(1'b1), .rs423_cts(1'b0),
        .rs423_txd(), .rs423_rts(), .carrier());

    // ---------------- Storage + player ----------------
    reg         dl_wr = 0;
    reg  [24:0] dl_addr = 0;
    reg  [7:0]  dl_data = 0;
    wire        dl_wait;
    reg  [24:0] tape_size = 0;
    reg         rewind = 0;

    wire        p_rd, p_valid, p_err, p_playing;
    wire [1:0]  p_fmt;
    wire [24:0] p_addr;
    wire [7:0]  p_data;

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
        .wr(dl_wr), .waddr(dl_addr), .wdata(dl_data), .wbusy(dl_wait),
        .rd(p_rd), .raddr(p_addr), .rdata(p_data), .rvalid(p_valid),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE));

    tape_player #(.TICK_DIV(TICK_DIV)) player (
        .clk(clk), .rst(rst), .motor(motor), .rewind(rewind), .size(tape_size),
        .mem_rd(p_rd), .mem_addr(p_addr), .mem_data(p_data), .mem_valid(p_valid),
        .cas_out(cas), .playing(p_playing), .error(p_err), .fmt(p_fmt), .position());

    // ---------------- DDR3 model ----------------
    // Random BUSY, 12-30 clk read latency, checks the address window.
    reg [63:0] ddr [0:65535];
    integer    dseed = 7;
    reg        busy_r = 0;
    assign DDRAM_BUSY = busy_r;
    reg [15:0] rd_q_addr;
    integer    rd_lat = -1;
    integer    k;
    reg [63:0] wtmp;

    always @(posedge clk) begin
        busy_r <= (($random(dseed) & 3) == 0);
        DDRAM_DOUT_READY <= 1'b0;
        if (!busy_r) begin
            if (DDRAM_WE) begin
                if (DDRAM_ADDR[28:25] !== 4'b0011) $display("DDR write outside window %h", DDRAM_ADDR);
                wtmp = ddr[DDRAM_ADDR[15:0]];
                for (k = 0; k < 8; k = k + 1)
                    if (DDRAM_BE[k]) wtmp[k*8 +: 8] = DDRAM_DIN[k*8 +: 8];
                ddr[DDRAM_ADDR[15:0]] = wtmp;
            end
            if (DDRAM_RD) begin
                if (DDRAM_ADDR[28:25] !== 4'b0011) $display("DDR read outside window %h", DDRAM_ADDR);
                rd_q_addr <= DDRAM_ADDR[15:0];
                rd_lat    <= 12 + (($random(dseed) & 15));
            end
        end
        if (rd_lat > 0) rd_lat <= rd_lat - 1;
        if (rd_lat == 0) begin
            DDRAM_DOUT <= ddr[rd_q_addr];
            DDRAM_DOUT_READY <= 1'b1;
            rd_lat <= -1;
        end
    end

    // ---------------- Images ----------------
    reg [7:0] img [0:65535];
    reg [7:0] expv [0:1023];
    integer   img_len, exp_len;

    task load_files(input [8*16-1:0] imgf, input [8*16-1:0] expf);
        integer i;
        begin
            for (i = 0; i < 65536; i = i + 1) img[i] = 8'hxx;
            for (i = 0; i < 1024; i = i + 1)  expv[i] = 8'hxx;
            $readmemh(imgf, img);
            $readmemh(expf, expv);
            img_len = 0; while (img[img_len] !== 8'hxx) img_len = img_len + 1;
            exp_len = 0; while (expv[exp_len] !== 8'hxx) exp_len = exp_len + 1;
        end
    endtask

    // download like hps_io: one byte per strobe, wait while ioctl_wait is high
    task download;
        integer i;
        begin
            for (i = 0; i < img_len; i = i + 1) begin
                @(negedge clk);
                while (dl_wait) @(negedge clk);
                dl_wr = 1; dl_addr = i; dl_data = img[i];
                @(negedge clk);
                dl_wr = 0;
                @(negedge clk);
            end
            repeat (50) @(negedge clk);
            tape_size = img_len;
            rewind = 1; @(negedge clk); rewind = 0;
        end
    endtask

    // ---------------- CPU model ----------------
    task bus_write(input is_ula, input reg_sel, input [7:0] data);
        begin
            @(negedge clk); while (bcnt != 3'd7) @(negedge clk);
            cs_acia = !is_ula; cs_ula = is_ula; rw = 0; rs = reg_sel; din = data;
            @(negedge clk); cs_acia = 0; cs_ula = 0; rw = 1;
        end
    endtask

    task bus_read(input reg_sel, output [7:0] data);
        begin
            @(negedge clk); while (bcnt != 3'd7) @(negedge clk);
            cs_acia = 1; rw = 1; rs = reg_sel;
            #1 data = acia_do;
            @(negedge clk); cs_acia = 0;
        end
    endtask

    reg [7:0] got [0:1023];
    integer   ngot, ndcd, nfe, nerr_total;

    task service_once;
        reg [7:0] sr, d;
        begin
            bus_read(1'b0, sr);
            if (sr[4]) nfe = nfe + 1;
            if (sr[2]) ndcd = ndcd + 1;
            if (sr[0] || sr[2]) begin
                bus_read(1'b1, d);
                if (sr[0]) begin got[ngot] = d; ngot = ngot + 1; end
            end
        end
    endtask

    // play until the player has run out of data and the line has gone quiet
    task play(input [7:0] acia_cr);
        real t0;
        begin
            ngot = 0; ndcd = 0; nfe = 0;
            bus_write(1, 0, 8'h85);        // motor on, cassette (as MOS)
            bus_write(0, 0, 8'h03);
            bus_write(0, 0, acia_cr);
            t0 = $realtime;
            while ((player.ps != 5'd14 && player.ps != 5'd15) || player.e_busy) begin
                @(negedge clk);
                if (irq) service_once;
                if ($realtime - t0 > 20.0e9) begin
                    $display("  timeout: player stuck in state %0d", player.ps);
                    disable play;
                end
            end
            t0 = $realtime;
            while ($realtime - t0 < 30.0e6) begin
                @(negedge clk);
                if (irq) service_once;
            end
            bus_write(1, 0, 8'h05);        // motor off
        end
    endtask

    task check(input [8*48-1:0] name);
        integer i, e;
        begin
            e = 0;
            if (ngot != exp_len) begin
                $display("  %0s: received %0d bytes, expected %0d", name, ngot, exp_len);
                e = e + 1;
            end
            for (i = 0; i < exp_len && i < ngot; i = i + 1)
                if (got[i] !== expv[i]) begin
                    if (e < 6) $display("  %0s: byte %0d got %02x expected %02x", name, i, got[i], expv[i]);
                    e = e + 1;
                end
            if (nfe != 0) begin
                $display("  %0s: %0d framing errors", name, nfe); e = e + 1;
            end
            $display("%0s: %0s  (%0d bytes, %0d DCD irq)", name, (e == 0) ? "PASS" : "FAIL", ngot, ndcd);
            nerr_total = nerr_total + e;
        end
    endtask

    task reset_all;
        begin
            rst = 1; tape_size = 0;
            repeat (20) @(posedge clk);
            rst = 0;
            repeat (20) @(posedge clk);
        end
    endtask

    // motor must gate playback
    task motor_gate_test;
        integer p0;
        begin
            load_files("img_b.hex", "exp_b.hex");
            reset_all;
            download;
            bus_write(1, 0, 8'h05);            // motor off
            repeat (200000) @(negedge clk);
            // the parser may read ahead, but no tone may play
            if (cas !== 1'b0 || player.e_ph !== 4'd0 || player.e_left !== 24'd1000) begin
                $display("  motor off: tone advanced (cas %b ph %0d left %0d)", cas, player.e_ph, player.e_left);
                $display("Motor gating: FAIL"); nerr_total = nerr_total + 1;
            end else
                $display("Motor gating: PASS");
        end
    endtask

    initial begin
        nerr_total = 0;
        $display("UEF player end-to-end tests (DDR3 model, %0d Hz)", CLK_HZ);

        load_files("img_a.hex", "exp_a.hex");
        reset_all; download;
        repeat (3000) @(negedge clk);
        if (p_fmt !== 2'd1) begin $display("  fmt after UEF load = %0d, expected 1", p_fmt); nerr_total = nerr_total + 1; end
        play(8'hD5);
        check("A. UEF 1200 baud, all chunk types");

        load_files("img_b.hex", "exp_b.hex");
        reset_all; download; play(8'hD6);
        check("B. UEF 300 baud (0117)");

        load_files("img_c.hex", "exp_c.hex");
        reset_all; download;
        repeat (3000) @(negedge clk);
        if (p_fmt !== 2'd2) begin $display("  fmt after bitstream load = %0d, expected 2", p_fmt); nerr_total = nerr_total + 1; end
        play(8'hD5);
        check("C. Main_MiSTer bitstream");

        load_files("img_d.hex", "exp_b.hex");
        reset_all; download;
        repeat (2000) @(negedge clk);
        if (p_err === 1'b1 && player.e_busy === 1'b0 && p_fmt === 2'd3) $display("D. gzip UEF refused: PASS");
        else begin $display("D. gzip UEF refused: FAIL (err=%b)", p_err); nerr_total = nerr_total + 1; end

        motor_gate_test;

        // rewind and replay image A without re-downloading
        load_files("img_a.hex", "exp_a.hex");
        reset_all; download; play(8'hD5);
        rewind = 1; @(negedge clk); rewind = 0;
        play(8'hD5);
        check("E. Rewind and replay");

        if (nerr_total == 0) $display("ALL TESTS PASSED");
        else                 $display("FAILURES: %0d", nerr_total);
        $finish;
    end

endmodule
