// BBC Micro Serial ULA (Ferranti 2C199E / Master SERPROC) for BeebFpga, &FE10-&FE1F
//
// Control register (write only; a read has the same effect as writing &FE):
//   b7    cassette motor relay (1 = on)
//   b6    0 = cassette, 1 = RS423
//   b5:3  receive rate  (RS423 mode)
//   b2:0  transmit rate
// Rate codes give 16MHz/13 divided by 1,16,4,128,2,64,8,256 (19200..75 baud with
// the ACIA's /64). MOS 1.20 writes &85 for tape: motor on, cassette, Tx 19.23kHz.
//
// Cassette receive (after MAME's acorn_serproc):
//   The tape signal (1 bit, already squared) is cut into half-cycles. Two halves
//   adding up to 680us or more are one 1200Hz cycle = a '0' unit; four halves
//   adding up to 930us or less are two 2400Hz cycles = a '1' unit. Each unit
//   sends 16 RxC pulses to the ACIA with RxD at that value, so the receive
//   clock is recovered from the tape (ACIA /16 = 1200 baud, /64 = 300 baud)
//   and tape speed variation is absorbed. DCD goes high after 100 '1' units of
//   leader tone and drops on the first '0' or when the signal stops.
//
// Cassette transmit:
//   When the ACIA's RTS is low in cassette mode, txd is turned into tones:
//   1 = 2400Hz, 0 = 1200Hz, phase-reset at each bit change, timed off the
//   19.23kHz cassette clock (one bit at /16 = two 2400Hz cycles or one 1200Hz).

module serial_ula #(
    parameter integer CLK_HZ   = 48000000,
    parameter integer BASE_DIV = 39            // CLK_HZ / (16MHz/13); 39 at 48MHz
) (
    input  wire       clk,
    input  wire       rst,

    // CPU bus
    input  wire       bus_en,
    input  wire       cs,
    input  wire       rw,
    input  wire [7:0] din,
    output reg  [7:0] ctrl,
    output wire       motor,

    // To / from the ACIA
    output wire       acia_rx_tick,
    output wire       acia_tx_tick,
    output wire       acia_rxd,
    output wire       acia_dcd,
    output wire       acia_cts,
    input  wire       acia_txd,
    input  wire       acia_rts,     // pin level, 0 = active

    // Cassette
    input  wire       cas_in,       // squared tape signal
    output reg        cas_out,      // tone output (square)
    output wire       cas_out_en,   // tone output active

    // RS423 (not connected to anything yet)
    input  wire       rs423_rxd,
    input  wire       rs423_cts,
    output wire       rs423_txd,
    output wire       rs423_rts,

    // Debug / status
    output wire       carrier       // demodulator DCD
);

    // Thresholds in clk cycles
    localparam integer GLITCH  = CLK_HZ / 25000;   // 40us: shorter half-cycles are ignored
    localparam integer TIMEOUT = CLK_HZ / 1250;    // 800us without an edge = no signal

    wire cassette = ~ctrl[6];
    assign motor  = ctrl[7];

    // ---------------- Control register ----------------
    always @(posedge clk) begin
        if (rst)
            ctrl <= 8'h64;
        else if (bus_en && cs)
            ctrl <= rw ? 8'hFE : din;
    end

    // ---------------- Baud generator ----------------
    reg  [5:0] base_cnt;
    reg        base_tick;
    reg  [5:0] cas_cnt;
    reg        cas_tick;
    reg  [7:0] rx_pre, tx_pre;
    reg        rx_rs_tick, tx_rs_tick;

    function [7:0] rate_div_m1;      // divider - 1
        input [2:0] code;
        case (code)
            3'd0: rate_div_m1 = 8'd0;     // /1
            3'd1: rate_div_m1 = 8'd15;    // /16
            3'd2: rate_div_m1 = 8'd3;     // /4
            3'd3: rate_div_m1 = 8'd127;   // /128
            3'd4: rate_div_m1 = 8'd1;     // /2
            3'd5: rate_div_m1 = 8'd63;    // /64
            3'd6: rate_div_m1 = 8'd7;     // /8
            default: rate_div_m1 = 8'd255;// /256
        endcase
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            base_cnt <= 6'd0; base_tick <= 1'b0;
            cas_cnt <= 6'd0;  cas_tick <= 1'b0;
            rx_pre <= 8'd0;   tx_pre <= 8'd0;
            rx_rs_tick <= 1'b0; tx_rs_tick <= 1'b0;
        end else begin
            base_tick  <= 1'b0;
            cas_tick   <= 1'b0;
            rx_rs_tick <= 1'b0;
            tx_rs_tick <= 1'b0;
            if (base_cnt == BASE_DIV - 1) begin
                base_cnt  <= 6'd0;
                base_tick <= 1'b1;
            end else
                base_cnt <= base_cnt + 6'd1;

            if (base_tick) begin
                cas_cnt <= cas_cnt + 6'd1;
                if (cas_cnt == 6'd63)
                    cas_tick <= 1'b1;

                if (rx_pre >= rate_div_m1(ctrl[5:3])) begin
                    rx_pre     <= 8'd0;
                    rx_rs_tick <= 1'b1;
                end else
                    rx_pre <= rx_pre + 8'd1;

                if (tx_pre >= rate_div_m1(ctrl[2:0])) begin
                    tx_pre     <= 8'd0;
                    tx_rs_tick <= 1'b1;
                end else
                    tx_pre <= tx_pre + 8'd1;
            end
        end
    end

    // ---------------- Cassette demodulator ----------------
    // Classifies half-cycles as MAME's Serial ULA does, and recovers the ACIA
    // receive clock from the tape: each decoded 1200-baud unit (one 1200Hz
    // cycle = 0, two 2400Hz cycles = 1) produces a burst of 16 RxC ticks with
    // rxd held at that value. The ACIA's /16 then sees one bit per unit (and
    // /64 one bit per four units at 300 baud), so tape speed doesn't matter.
    localparam integer T0_PAIR = CLK_HZ / 1470;   // 680us: two halves this long = '0'
    localparam integer T1_QUAD = CLK_HZ / 1075;   // 930us: four halves this short = '1'

    reg  [1:0]  sync;
    reg         s_d;
    reg  [16:0] hcnt;               // clks since last accepted edge (saturates)
    reg  [16:0] h0, h1, h2;         // previous half-cycles, h0 newest
    reg  [2:0]  nh;                 // valid halves in the history
    reg         armed;              // seen an edge since the signal started
    reg         dm_rxd, dm_dcd;
    reg  [7:0]  run;                // consecutive '1' units
    reg  [4:0]  burst;              // RxC ticks still to send
    reg         burst_ph;
    reg         cas_rx_tick;

    wire        s       = sync[1];
    wire        edge_ok = (s != s_d) && (hcnt >= GLITCH);
    wire [17:0] pair    = {1'b0, h0} + {1'b0, hcnt};
    wire [18:0] quad    = {2'b0, h2} + {2'b0, h1} + {2'b0, h0} + {2'b0, hcnt};

    always @(posedge clk) begin
        if (rst) begin
            sync <= 2'b00; s_d <= 1'b0;
            hcnt <= 17'd0; h0 <= 17'd0; h1 <= 17'd0; h2 <= 17'd0;
            nh <= 3'd0; armed <= 1'b0;
            dm_rxd <= 1'b1; dm_dcd <= 1'b0; run <= 8'd0;
            burst <= 5'd0; burst_ph <= 1'b0; cas_rx_tick <= 1'b0;
        end else begin
            sync <= {sync[0], cas_in};
            s_d  <= s;

            // RxC burst: 16 ticks, one every other clk
            cas_rx_tick <= 1'b0;
            if (burst != 5'd0) begin
                burst_ph <= ~burst_ph;
                if (burst_ph) begin
                    cas_rx_tick <= 1'b1;
                    burst <= burst - 5'd1;
                end
            end

            if (edge_ok) begin
                hcnt <= 17'd0;
                if (!armed) begin
                    armed <= 1'b1;                    // first edge only starts timing
                end else if (nh >= 3'd1 && pair >= T0_PAIR) begin
                    // '0' unit: one long cycle
                    dm_rxd <= 1'b0; dm_dcd <= 1'b0; run <= 8'd0;
                    burst <= 5'd16; burst_ph <= 1'b0;
                    nh <= 3'd0;
                end else if (nh >= 3'd3 && quad <= T1_QUAD) begin
                    // '1' unit: two short cycles
                    dm_rxd <= 1'b1;
                    if (run != 8'hFF) run <= run + 8'd1;
                    if (run >= 8'd100) dm_dcd <= 1'b1;
                    burst <= 5'd16; burst_ph <= 1'b0;
                    nh <= 3'd0;
                end else begin
                    h2 <= h1; h1 <= h0; h0 <= hcnt;
                    if (nh != 3'd3) nh <= nh + 3'd1;
                end
            end else begin
                if (hcnt != TIMEOUT)
                    hcnt <= hcnt + 17'd1;
                else if (armed) begin
                    // no signal: drop carrier and wait for the tone to restart
                    armed <= 1'b0; nh <= 3'd0;
                    dm_dcd <= 1'b0; run <= 8'd0;
                end
            end
        end
    end

    assign carrier = dm_dcd;

    // ---------------- Cassette modulator ----------------
    reg  [3:0] ph;
    reg        bit_l;
    wire [4:0] cyc_len = bit_l ? 5'd8 : 5'd16;   // cas ticks per tone cycle

    assign cas_out_en = cassette & ~acia_rts;

    always @(posedge clk) begin
        if (rst) begin
            ph <= 4'd0; bit_l <= 1'b1; cas_out <= 1'b0;
        end else if (cas_tick) begin
            if (!cas_out_en) begin
                ph <= 4'd0; bit_l <= acia_txd; cas_out <= 1'b0;
            end else if (acia_txd != bit_l) begin
                bit_l   <= acia_txd;     // bit changed: restart the cycle
                ph      <= 4'd0;
                cas_out <= 1'b1;
            end else begin
                if ({1'b0, ph} + 5'd1 == cyc_len) begin
                    ph      <= 4'd0;
                    cas_out <= 1'b1;
                end else begin
                    ph      <= ph + 4'd1;
                    cas_out <= ({1'b0, ph} + 5'd1) < (cyc_len >> 1);
                end
            end
        end
    end

    // ---------------- Routing ----------------
    assign acia_rx_tick = cassette ? cas_rx_tick : rx_rs_tick;
    assign acia_tx_tick = tx_rs_tick;
    assign acia_rxd     = cassette ? dm_rxd   : rs423_rxd;
    assign acia_dcd     = cassette ? dm_dcd   : 1'b0;
    assign acia_cts     = cassette ? 1'b0     : rs423_cts;
    assign rs423_txd    = cassette ? 1'b1     : acia_txd;
    assign rs423_rts    = cassette ? 1'b1     : acia_rts;

endmodule
