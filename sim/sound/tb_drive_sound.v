// Drive sounds testbench: rtl/drive_sound.v through rtl/tape/tape_store.v + tape_ddr.v
//
// sounds.rom is downloaded byte by byte (paced by dl_wait, like ioctl_wait) into a
// DDR3 model with random BUSY and read latency. Each test raises a trigger and checks
// the mixer's output sample by sample against the raw samples in the file.
//
//   python ../../scripts/make_sounds_rom.py <BeebEm folder> sounds.rom
//   python mkhex.py sounds.rom                      (writes rom.hex, rom_len.hex)
//   cvc64 tb_drive_sound.v ../../rtl/drive_sound.v ../../rtl/tape/tape_store.v \
//         ../../rtl/tape/tape_ddr.v ../../rtl/tape/inflate.v && ./cvcsim
//
// The clock is 7.056 MHz (160 clocks per 44.1 kHz sample) to keep the run short;
// all of drive_sound's timings scale with CLK_HZ.

`timescale 1ns/1ps
module tb;
    localparam integer CLK_HZ = 7056000;

    reg clk = 0, rst = 1;
    always #71 clk = ~clk;

    // ---------------- DUT ----------------
    reg         snd_dl = 0, tape_dl = 0, dl_wr = 0;
    reg  [24:0] dl_addr = 0;
    reg   [7:0] dl_data = 0;
    wire        dl_wait;
    wire        s_rd, s_valid;
    wire [16:0] s_addr;
    wire  [7:0] s_data;
    reg         p_rd = 0;
    reg  [24:0] p_addr = 0;
    wire  [7:0] p_data;
    wire        p_valid;
    wire [24:0] tsize;

    reg   [1:0] level = 2;
    reg         relay_en = 0, motor = 0, step = 0, seek_tog = 0, tape_motor = 0;
    reg   [6:0] seek_n = 0;
    wire        loaded;
    wire signed [17:0] audio;

    wire        DDRAM_BUSY;
    wire  [7:0] DDRAM_BURSTCNT;
    wire [28:0] DDRAM_ADDR;
    reg  [63:0] DDRAM_DOUT;
    reg         DDRAM_DOUT_READY;
    wire        DDRAM_RD, DDRAM_WE;
    wire [63:0] DDRAM_DIN;
    wire  [7:0] DDRAM_BE;

    tape_store ts (
        .clk(clk), .rst(rst), .eject(1'b0),
        .dl_active(tape_dl), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait),
        .snd_active(snd_dl), .s_rd(s_rd), .s_addr(s_addr), .s_data(s_data), .s_valid(s_valid),
        .p_rd(p_rd), .p_addr(p_addr), .p_data(p_data), .p_valid(p_valid),
        .size(tsize), .inflating(), .inflate_err(),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE));

    drive_sound #(.CLK_HZ(CLK_HZ)) ds (
        .clk(clk), .rst(rst), .level(level), .relay_en(relay_en),
        .motor(motor), .step(step), .seek_tog(seek_tog), .seek_n(seek_n), .tape_motor(tape_motor),
        .dl_active(snd_dl), .dl_wr(dl_wr), .dl_addr(dl_addr[16:0]), .dl_data(dl_data),
        .mem_rd(s_rd), .mem_addr(s_addr), .mem_data(s_data), .mem_valid(s_valid),
        .loaded(loaded), .audio(audio));

    // ---------------- DDR3 model (sparse: low 2MB and the top 128KB) ----------------
    reg [63:0] lo [0:262143];
    reg [63:0] hi [0:16383];
    integer    dseed = 7;
    reg        busy_r = 0;
    assign DDRAM_BUSY = busy_r;
    reg [21:0] rq;
    integer    lat = -1, k;
    reg [63:0] wtmp;
    function [63:0] rdw; input [21:0] a;
        rdw = (a >= 22'h3FC000) ? hi[a - 22'h3FC000] : lo[a[17:0]];
    endfunction
    always @(posedge clk) begin
        busy_r <= (($random(dseed) & 3) == 0);
        DDRAM_DOUT_READY <= 1'b0;
        if (!busy_r) begin
            if (DDRAM_WE) begin
                if (DDRAM_ADDR[21:0] < 22'h3FC000 && DDRAM_ADDR[21:18] != 4'd0 && DDRAM_ADDR[21:18] != 4'h8 &&
                    DDRAM_ADDR[21:18] != 4'h2)
                    ; // outside the model
                wtmp = rdw(DDRAM_ADDR[21:0]);
                for (k = 0; k < 8; k = k + 1)
                    if (DDRAM_BE[k]) wtmp[k*8 +: 8] = DDRAM_DIN[k*8 +: 8];
                if (DDRAM_ADDR[21:0] >= 22'h3FC000) hi[DDRAM_ADDR[21:0] - 22'h3FC000] = wtmp;
                else lo[DDRAM_ADDR[17:0]] = wtmp;
            end
            if (DDRAM_RD) begin
                rq  <= DDRAM_ADDR[21:0];
                lat <= 10 + ($random(dseed) & 15);
            end
        end
        if (lat > 0) lat <= lat - 1;
        if (lat == 0) begin
            DDRAM_DOUT <= rdw(rq);
            DDRAM_DOUT_READY <= 1'b1;
            lat <= -1;
        end
    end

    // ---------------- sounds.rom ----------------
    reg  [7:0] rom [0:131071];
    reg [31:0] rlen [0:0];
    integer    romlen;
    function integer soff; input integer n;
        soff = rom[8+8*n] | (rom[9+8*n] << 8) | (rom[10+8*n] << 16);
    endfunction
    function integer slen; input integer n;
        slen = rom[12+8*n] | (rom[13+8*n] << 8) | (rom[14+8*n] << 16);
    endfunction
    function integer smp; input integer n; input integer i;   // signed sample
        smp = rom[soff(n) + i] - 128;
    endfunction

    // one mixed output per sample period
    reg  busy_d = 0;
    wire mixed = busy_d && !ds.busy;
    always @(posedge clk) busy_d <= ds.busy;

    task next_mix(output integer v);
        begin
            @(posedge clk); while (!mixed) @(posedge clk);
            v = audio;
        end
    endtask

    integer nerr = 0;
    integer ntests = 0;

    // compare the next n outputs with sum of up to two samples (a from ia, b from ib), << sh
    task expect_seq(input [8*24:1] name, input integer n, input integer a, input integer b,
                    input integer sh, input integer loop_a);
        integer i, v, e, ea, bad;
        begin
            bad = 0;
            for (i = 0; i < n; i = i + 1) begin
                next_mix(v);
                ea = (a < 0) ? 0 : smp(a, loop_a ? (i % slen(a)) : i);
                e  = (ea + ((b < 0 || i >= slen(b)) ? 0 : smp(b, i))) * (1 << sh);
                if (v !== e) begin
                    if (bad < 5) $display("  %0s: sample %0d got %0d expected %0d", name, i, v, e);
                    bad = bad + 1;
                end
            end
            ntests = ntests + 1;
            if (bad) begin nerr = nerr + 1; $display("FAIL %0s (%0d bad)", name, bad); end
            else $display("ok   %0s (%0d samples)", name, n);
        end
    endtask

    task expect_silence(input [8*24:1] name, input integer n);
        integer i, v, bad;
        begin
            bad = 0;
            for (i = 0; i < n; i = i + 1) begin next_mix(v); if (v != 0) bad = bad + 1; end
            ntests = ntests + 1;
            if (bad) begin nerr = nerr + 1; $display("FAIL %0s (%0d non-zero)", name, bad); end
            else $display("ok   %0s", name);
        end
    endtask

    // 8271 seek: count first, then the toggle (the core registers the count first too)
    task seek(input integer n);
        begin
            seek_n <= n; repeat (4) @(posedge clk); seek_tog <= ~seek_tog;
        end
    endtask

    task download(input integer is_snd, input integer n, input integer junk);
        integer i;
        begin
            @(posedge clk); snd_dl <= is_snd; tape_dl <= !is_snd;
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                dl_addr <= i;
                dl_data <= junk ? (i * 37) : is_snd ? rom[i] : (i * 13 + 5);
                dl_wr   <= 1'b1;
                @(posedge clk); dl_wr <= 1'b0;
                @(posedge clk); while (dl_wait) @(posedge clk);
            end
            repeat (4) @(posedge clk);
            snd_dl <= 0; tape_dl <= 0;
            repeat (4) @(posedge clk);
        end
    endtask

    // when the seek loop stops: count outputs until silence (motor is off)
    task seek_length(input [8*24:1] name, input integer expect_n);
        integer i, v, last;
        begin
            last = 0;
            for (i = 0; i < expect_n + 2000; i = i + 1) begin
                next_mix(v);
                if (v != 0) last = i;
            end
            ntests = ntests + 1;
            if (last < expect_n - 60 || last > expect_n + 5) begin
                nerr = nerr + 1; $display("FAIL %0s: sound for %0d samples, expected about %0d", name, last + 1, expect_n);
            end else $display("ok   %0s (%0d samples, expected about %0d)", name, last + 1, expect_n);
        end
    endtask

    integer i, v, ok_t;
    initial begin
        $readmemh("rom.hex", rom);
        $readmemh("rom_len.hex", rlen);
        romlen = rlen[0];
        repeat (10) @(posedge clk);
        rst = 0;

        // ---- header check: junk must not be accepted
        download(1, 200, 1);
        ntests = ntests + 1;
        if (loaded) begin nerr = nerr + 1; $display("FAIL junk file accepted"); end
        else $display("ok   junk file rejected");
        motor <= 1;
        expect_silence("no sounds without a file", 300);
        motor <= 0;
        repeat (2) next_mix(v);

        // ---- the real file
        download(1, romlen, 0);
        ntests = ntests + 1;
        if (!loaded) begin nerr = nerr + 1; $display("FAIL sounds.rom not accepted"); end
        else $display("ok   sounds.rom accepted (%0d bytes)", romlen);

        // ---- a tape image still downloads and reads back correctly
        download(0, 3000, 0);
        ok_t = 1;
        for (i = 0; i < 3000; i = i + 1) begin
            @(posedge clk); p_addr <= i; p_rd <= 1; @(posedge clk); p_rd <= 0;
            while (!p_valid) @(posedge clk);
            if (p_data !== ((i * 13 + 5) & 255)) ok_t = 0;
        end
        ntests = ntests + 1;
        if (!ok_t || tsize != 3000) begin nerr = nerr + 1; $display("FAIL tape image read back"); end
        else $display("ok   tape image alongside sounds");

        // ---- motor on: motor loop + head load (medium = << 6)
        level <= 2;
        next_mix(v);
        motor <= 1;
        expect_seq("motor on", 45000, 2, 3, 6, 1);   // > 1 motor loop
        // ---- motor off: head unload, motor stops
        motor <= 0;
        expect_seq("motor off", 4446, -1, 4, 6, 0);
        expect_silence("silent after unload", 200);

        // ---- 8271 seek of one track: head step
        seek(1);
        expect_seq("8271 step", 2251, -1, 6, 6, 0);
        expect_silence("silent after step", 100);

        // ---- 8271 seek of 5 tracks: seek loop for 5 x 24.15 ms
        seek(5);
        expect_seq("8271 seek start", 2000, 5, -1, 6, 1);
        seek_length("8271 seek length", 5325 - 2000);

        // ---- 1770: lone step pulse
        step <= 1; repeat (20) @(posedge clk); step <= 0;
        expect_seq("1770 lone step", 2251, -1, 6, 6, 0);
        expect_silence("silent after lone step", 1000);

        // ---- 1770: six steps 12 ms apart: step sound, then seek loop until 35 ms after
        for (i = 0; i < 6; i = i + 1) begin
            step <= 1; repeat (20) @(posedge clk); step <= 0;
            repeat (CLK_HZ / 1000 * 12) @(posedge clk);
        end
        // last pulse was 12 ms ago; the loop should stop 35 ms after it (~23 ms = 1014 samples)
        seek_length("1770 seek stops", 1014);

        // ---- levels: loud (<< 7) and low (<< 5)
        level <= 3; seek(1);
        expect_seq("loud", 2251, -1, 6, 7, 0);
        level <= 1; seek(1);
        expect_seq("low", 2251, -1, 6, 5, 0);

        // ---- off: nothing, and turning off silences a running motor
        level <= 2; motor <= 1;
        repeat (100) next_mix(v);
        level <= 0;
        next_mix(v);
        expect_silence("level off stops sound", 500);
        motor <= 0;
        repeat (5) next_mix(v);
        motor <= 1;
        expect_silence("level off, motor on", 500);
        motor <= 0;
        repeat (5) next_mix(v);

        // ---- cassette relay clicks (fixed << 6), only when enabled
        tape_motor <= 1;
        expect_silence("relay off", 400);
        tape_motor <= 0;
        repeat (5) next_mix(v);
        relay_en <= 1;
        tape_motor <= 1;
        expect_seq("relay on click", 297, -1, 0, 6, 0);
        expect_silence("after relay on", 100);
        tape_motor <= 0;
        expect_seq("relay off click", 400, -1, 1, 6, 0);

        $display("%0d tests, %0d failed", ntests, nerr);
        $display(nerr ? "FAILED" : "PASSED");
        $finish;
    end
endmodule
