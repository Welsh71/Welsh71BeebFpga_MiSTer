// Testbench: Serial ULA + 6850 ACIA cassette path
//
// Plays BBC tape-format tones (1 = two cycles of 2400Hz, 0 = one cycle of
// 1200Hz per 1200-baud bit; four times as many at 300 baud) into the ULA and
// checks the bytes the ACIA receives, using a CPU model that services the ACIA
// interrupt the way MOS does (read SR, then RDR).
//
// Tests:
//   1. 1200 baud, clean tones
//   2. 1200 baud, 40/60 duty cycle, +-8% jitter, tape 4% fast; 2b tape 10% fast
//   3. 1200 baud, tape 5% slow
//   4. 300 baud (ACIA /64)
//   5. Transmit loopback: ACIA TX -> ULA tones -> ULA RX
//   6. Master reset / register checks
`timescale 1ns/1ps

`ifndef CLK_HZ
 `define CLK_HZ 16000000
`endif
`ifndef BASE_DIV
 `define BASE_DIV 13
`endif

module tb_tape;

    localparam real CLK_PERIOD = 1.0e9 / `CLK_HZ;

    reg clk = 0;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    reg rst = 1;

    // CPU bus: one access completes every 8 clks (2MHz-ish at 16MHz)
    reg [2:0] bcnt = 0;
    always @(posedge clk) bcnt <= bcnt + 1;
    wire bus_en = (bcnt == 3'd7);

    reg       cs_acia = 0, cs_ula = 0, rw = 1, rs = 0;
    reg [7:0] din = 0;
    wire [7:0] acia_do;
    wire       irq;

    wire rx_tick, tx_tick, a_rxd, a_dcd, a_cts, a_txd, a_rts;
    wire motor, cas_out, cas_out_en, carrier;
    wire [7:0] ula_ctrl;

    reg  tape_sig = 0;
    reg  loopback = 0;
    wire cas_in = loopback ? cas_out : tape_sig;

    acia6850 acia (
        .clk(clk), .rst(rst),
        .bus_en(bus_en), .cs(cs_acia), .rw(rw), .rs(rs), .din(din), .dout(acia_do), .irq(irq),
        .rx_tick(rx_tick), .tx_tick(tx_tick), .rxd(a_rxd), .dcd(a_dcd), .cts(a_cts),
        .txd(a_txd), .rts(a_rts)
    );

    serial_ula #(.CLK_HZ(`CLK_HZ), .BASE_DIV(`BASE_DIV)) ula (
        .clk(clk), .rst(rst),
        .bus_en(bus_en), .cs(cs_ula), .rw(rw), .din(din), .ctrl(ula_ctrl), .motor(motor),
        .acia_rx_tick(rx_tick), .acia_tx_tick(tx_tick), .acia_rxd(a_rxd), .acia_dcd(a_dcd),
        .acia_cts(a_cts), .acia_txd(a_txd), .acia_rts(a_rts),
        .cas_in(cas_in), .cas_out(cas_out), .cas_out_en(cas_out_en),
        .rs423_rxd(1'b1), .rs423_cts(1'b0), .rs423_txd(), .rs423_rts(),
        .carrier(carrier)
    );

    // ---------------- CPU bus model ----------------
    task bus_write(input is_ula, input reg_sel, input [7:0] data);
        begin
            @(negedge clk);
            while (bcnt != 3'd7) @(negedge clk);
            cs_acia = !is_ula; cs_ula = is_ula; rw = 0; rs = reg_sel; din = data;
            @(negedge clk);
            cs_acia = 0; cs_ula = 0; rw = 1;
        end
    endtask

    task bus_read(input reg_sel, output [7:0] data);
        begin
            @(negedge clk);
            while (bcnt != 3'd7) @(negedge clk);
            cs_acia = 1; rw = 1; rs = reg_sel;
            #1 data = acia_do;          // sampled before the side effects at posedge
            @(negedge clk);
            cs_acia = 0;
        end
    endtask

    // ---------------- Tone generator ----------------
    real speed  = 1.0;    // >1 = tape running fast
    real duty   = 0.5;    // fraction of each cycle spent high
    real jitter = 0.0;    // +- fraction of each half-cycle
    integer seed = 1;
    integer baud = 1200;

    task half_cycle(input real half_ns, input level);
        real j;
        begin
            j = 1.0 + jitter * (($random(seed) % 1000) / 1000.0);
            tape_sig = level;
            #(half_ns * j / speed);
        end
    endtask

    task tone_cycles(input integer n, input real freq);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                half_cycle(1.0e9 / freq * duty,       1'b1);
                half_cycle(1.0e9 / freq * (1.0-duty), 1'b0);
            end
        end
    endtask

    task tape_bit(input b);
        integer k;
        begin
            k = (baud == 300) ? 4 : 1;
            if (b) tone_cycles(2 * k, 2400.0);
            else   tone_cycles(1 * k, 1200.0);
        end
    endtask

    task tape_byte(input [7:0] v);
        integer i;
        begin
            tape_bit(1'b0);
            for (i = 0; i < 8; i = i + 1) tape_bit(v[i]);
            tape_bit(1'b1);
        end
    endtask

    // ---------------- Test data and checking ----------------
    reg [7:0] sent [0:255];
    reg [7:0] got  [0:255];
    integer   nsent, ngot, ndcd, nerr_total, nfe;
    reg       tape_done;

    task make_block(input integer n);
        integer i;
        begin
            sent[0] = 8'h2A;                      // '*' sync byte, as on a real tape block
            for (i = 1; i < n; i = i + 1)
                sent[i] = (i * 37 + 11) ^ (i >> 1);
            sent[n-1] = 8'h00;
            sent[n-2] = 8'hFF;
            nsent = n;
        end
    endtask

    task play_block(input integer leader_bits);
        integer i;
        begin
            for (i = 0; i < leader_bits; i = i + 1) tape_bit(1'b1);
            for (i = 0; i < nsent; i = i + 1) tape_byte(sent[i]);
            for (i = 0; i < 20; i = i + 1) tape_bit(1'b1);
            tape_sig = 0;
            #(3.0e6);                             // 3ms silence
            tape_done = 1;
        end
    endtask

    // MOS-style interrupt service: read SR, then RDR if needed
    task service_once;
        reg [7:0] sr, d;
        begin
            bus_read(1'b0, sr);
            if (sr[4]) nfe = nfe + 1;
            if (sr[2]) begin
                bus_read(1'b1, d);        // clears the DCD interrupt
                ndcd = ndcd + 1;
                if (sr[0]) begin
                    got[ngot] = d; ngot = ngot + 1;
                end
            end else if (sr[0]) begin
                bus_read(1'b1, d);
                got[ngot] = d; ngot = ngot + 1;
            end
        end
    endtask

    task service_until_done;
        begin
            while (!tape_done) begin
                @(negedge clk);
                if (irq) service_once;
            end
        end
    endtask

    task check(input [8*40-1:0] name);
        integer i, e;
        begin
            e = 0;
            if (ngot != nsent) begin
                $display("  %0s: received %0d bytes, expected %0d", name, ngot, nsent);
                e = e + 1;
            end
            for (i = 0; i < nsent && i < ngot; i = i + 1)
                if (got[i] !== sent[i]) begin
                    if (e < 5) $display("  %0s: byte %0d got %02x expected %02x", name, i, got[i], sent[i]);
                    e = e + 1;
                end
            if (ndcd < 1) begin
                $display("  %0s: no DCD (carrier) interrupt seen", name);
                e = e + 1;
            end
            if (nfe != 0) begin
                $display("  %0s: %0d framing errors", name, nfe);
                e = e + 1;
            end
            $display("%0s: %0s  (%0d bytes, %0d DCD irq)", name, (e == 0) ? "PASS" : "FAIL", ngot, ndcd);
            nerr_total = nerr_total + e;
        end
    endtask

    task reset_dut;
        begin
            rst = 1; tape_sig = 0; loopback = 0;
            repeat (20) @(posedge clk);
            rst = 0;
            repeat (20) @(posedge clk);
            ngot = 0; ndcd = 0; nfe = 0; tape_done = 0;
        end
    endtask

    task setup_rx(input [7:0] acia_cr);
        begin
            bus_write(1, 0, 8'h85);         // ULA: motor on, cassette, Tx 19.23kHz (as MOS)
            bus_write(0, 0, 8'h03);         // ACIA master reset
            bus_write(0, 0, acia_cr);
        end
    endtask

    task rx_test(input [8*40-1:0] name, input integer leader, input integer nbytes, input [7:0] acia_cr);
        begin
            reset_dut;
            setup_rx(acia_cr);
            make_block(nbytes);
            fork
                play_block(leader);
                service_until_done;
            join
            check(name);
        end
    endtask

    // ---------------- Transmit loopback ----------------
    task tx_loopback_test;
        integer i;
        real t_start;
        begin
            reset_dut;
            loopback = 1;
            make_block(24);
            bus_write(1, 0, 8'h85);
            bus_write(0, 0, 8'h03);
            bus_write(0, 0, 8'h95);         // RxIE, RTS low (tones on), 8N1, /16
            // leader: TX idle = continuous 2400Hz tone; send after ~150ms
            i = 0;
            t_start = $realtime;
            while ($realtime - t_start < 150.0e6) begin
                @(negedge clk);
                if (irq) service_once;
            end
            while (i < nsent) begin
                @(negedge clk);
                if (irq) service_once;
                else if (acia.tdre) begin   // poll TDRE between interrupts
                    bus_write(0, 1, sent[i]);
                    i = i + 1;
                end
            end
            t_start = $realtime;
            while ($realtime - t_start < 30.0e6) begin
                @(negedge clk);
                if (irq) service_once;
            end
            check("5. TX loopback 1200 baud");
        end
    endtask

    // ---------------- Register checks ----------------
    task reg_test;
        reg [7:0] sr;
        integer e;
        begin
            e = 0;
            reset_dut;
            bus_read(0, sr);
            if (sr[1] !== 1'b0) begin $display("  TDRE should read 0 in reset, SR=%02x", sr); e = e + 1; end
            bus_write(0, 0, 8'h03);
            bus_write(0, 0, 8'h15);         // 8N1 /16, no interrupts
            bus_read(0, sr);
            if (sr !== 8'h02) begin $display("  SR after reset should be 02, got %02x", sr); e = e + 1; end
            if (a_rts !== 1'b0) begin $display("  RTS should be low with CR6:5=00"); e = e + 1; end
            bus_write(0, 0, 8'h55);         // RTS high
            if (a_rts !== 1'b1) begin $display("  RTS should be high with CR6:5=10"); e = e + 1; end
            bus_write(0, 0, 8'h35);         // TxIE: TDRE set -> irq
            @(negedge clk);
            if (irq !== 1'b1) begin $display("  TX interrupt expected"); e = e + 1; end
            bus_write(0, 0, 8'h15);
            bus_write(1, 0, 8'h45);         // ULA RS423 mode
            if (ula.cassette !== 1'b0 || a_dcd !== 1'b0) begin $display("  RS423 mode not selected"); e = e + 1; end
            bus_write(1, 0, 8'h85);
            if (motor !== 1'b1) begin $display("  motor should be on"); e = e + 1; end
            // reading &FE10 behaves like writing &FE: motor on, RS423
            @(negedge clk); while (bcnt != 3'd7) @(negedge clk);
            cs_ula = 1; rw = 1; @(negedge clk); cs_ula = 0;
            if (ula_ctrl !== 8'hFE) begin $display("  read of FE10 should set ctrl=FE, got %02x", ula_ctrl); e = e + 1; end
            $display("%0s: %0s", "6. Register / reset behaviour", (e == 0) ? "PASS" : "FAIL");
            nerr_total = nerr_total + e;
        end
    endtask

    // ---------------- Main ----------------
    initial begin
        nerr_total = 0;
        $display("Serial ULA + 6850 cassette tests, clk %0d Hz", `CLK_HZ);

        speed = 1.0; duty = 0.5; jitter = 0.0; baud = 1200;
        rx_test("1. 1200 baud, clean", 150, 64, 8'hD5);

        speed = 1.04; duty = 0.4; jitter = 0.08; baud = 1200;
        rx_test("2. 1200 baud, 40/60 duty, 8% jitter, +4%", 150, 64, 8'hD5);

        speed = 1.10; duty = 0.5; jitter = 0.05; baud = 1200;
        rx_test("2b. 1200 baud, tape 10% fast, 5% jitter", 150, 64, 8'hD5);

        speed = 0.95; duty = 0.5; jitter = 0.05; baud = 1200;
        rx_test("3. 1200 baud, tape 5% slow, 5% jitter", 150, 64, 8'hD5);

        speed = 1.0; duty = 0.5; jitter = 0.03; baud = 300;
        rx_test("4. 300 baud (ACIA /64)", 40, 16, 8'hD6);

        speed = 1.0; duty = 0.5; jitter = 0.0; baud = 1200;
        tx_loopback_test;

        reg_test;

        if (nerr_total == 0) $display("ALL TESTS PASSED");
        else                 $display("FAILURES: %0d", nerr_total);
        $finish;
    end

endmodule
