// MC6850 ACIA for BeebFpga (BBC Micro &FE08-&FE0F)
//
// Behaviour follows the Motorola datasheet and MAME's 6850acia.cpp:
//  - CR1:0 counter divide 1/16/64, 11 = master reset (chip powers up in reset)
//  - CR4:2 word select, CR6:5 transmitter control (RTS / TxIE / break), CR7 RxIE
//  - DCD high inhibits and resets the receiver; a rising DCD sets SR2 and a
//    pending interrupt, cleared by reading SR then RDR
//  - Overrun: a character arriving while RDRF is set is lost; OVRN is reported
//    on the next RDR read
//  - TDRE reads 0 while in master reset or while CTS is high
//
// All timing is by clock enables on one clock. bus_en must pulse for exactly
// one clk at the end of each CPU access (the core's cpu_clken), so read side
// effects happen once. rx_tick / tx_tick are the RxC / TxC clock edges.

module acia6850 (
    input  wire       clk,
    input  wire       rst,        // synchronous, active high

    // CPU bus
    input  wire       bus_en,     // access completes this clk
    input  wire       cs,
    input  wire       rw,         // 1 = read
    input  wire       rs,         // register select (A0)
    input  wire [7:0] din,
    output wire [7:0] dout,
    output wire       irq,        // active high

    // Serial side (pin levels)
    input  wire       rx_tick,
    input  wire       tx_tick,
    input  wire       rxd,
    input  wire       dcd,        // 1 = DCD pin high (carrier lost / inhibit)
    input  wire       cts,        // 1 = CTS pin high (transmit inhibited)
    output reg        txd,
    output reg        rts         // pin level, 1 = high (inactive)
);

    localparam DCD_NONE = 2'd0, DCD_RD_STATUS = 2'd1, DCD_RD_DATA = 2'd2;
    localparam ST_START = 2'd0, ST_DATA = 2'd1, ST_STOP = 2'd2;

    reg  [7:0] cr;
    reg  [7:0] tdr, rdr;
    reg        rdrf, tdre, fe, pe, ovrn, sr_dcd;
    reg  [1:0] dcd_irq;
    reg        overrun_pending;
    reg        first_mr;

    // Receiver
    reg  [1:0] rx_state;
    reg  [6:0] rx_cnt;
    reg  [3:0] rx_bits;
    reg  [7:0] rx_shift;
    reg        rx_par;

    // Transmitter
    reg  [1:0] tx_state;
    reg  [6:0] tx_cnt;
    reg  [3:0] tx_bits;
    reg  [7:0] tx_shift;
    reg        tx_par;

    // Decoded control register
    wire       in_reset = (cr[1:0] == 2'b11);
    wire [6:0] divide   = (cr[1:0] == 2'b00) ? 7'd1  :
                          (cr[1:0] == 2'b01) ? 7'd16 : 7'd64;
    wire [6:0] half_div = divide >> 1;
    wire [2:0] ws       = cr[4:2];
    wire [3:0] nbits    = ws[2] ? 4'd8 : 4'd7;
    wire       par_en   = !(ws == 3'b100 || ws == 3'b101);
    wire       par_odd  = ws[0];
    wire [1:0] nstop    = (ws == 3'b000 || ws == 3'b001 || ws == 3'b100) ? 2'd2 : 2'd1;
    wire       tie      = (cr[6:5] == 2'b01);
    wire       brk      = (cr[6:5] == 2'b11);
    wire       rie      = cr[7];

    wire tdre_rd  = tdre & ~in_reset & ~cts;
    wire rx_irq   = rie & ~in_reset & (rdrf | (dcd_irq != DCD_NONE));
    wire tx_irq   = tie & ~in_reset & tdre & ~cts;
    assign irq    = rx_irq | tx_irq;

    wire [7:0] status = {irq, pe, ovrn, fe, cts, sr_dcd, tdre_rd, rdrf};
    assign dout = rs ? rdr : status;

    wire wr_cr  = bus_en & cs & ~rw & ~rs;
    wire wr_tdr = bus_en & cs & ~rw &  rs;
    wire rd_sr  = bus_en & cs &  rw & ~rs;
    wire rd_rdr = bus_en & cs &  rw &  rs;

    // Working copies so bus side effects and serial events in the same clk
    // combine correctly (bus first, then serial).
    reg        n_rdrf, n_tdre, n_fe, n_pe, n_ovrn, n_sr_dcd, n_ovr_pend;
    reg  [1:0] n_dcd_irq;
    reg  [6:0] nc;
    reg        bitv;

    always @(posedge clk) begin
        if (rst) begin
            cr <= 8'h03;  tdr <= 8'h00;  rdr <= 8'h00;
            rdrf <= 1'b0; tdre <= 1'b1;  fe <= 1'b0; pe <= 1'b0; ovrn <= 1'b0;
            sr_dcd <= 1'b0; dcd_irq <= DCD_NONE; overrun_pending <= 1'b0;
            first_mr <= 1'b1;
            rx_state <= ST_START; rx_cnt <= 7'd0; rx_bits <= 4'd0; rx_shift <= 8'd0; rx_par <= 1'b0;
            tx_state <= ST_START; tx_cnt <= 7'd0; tx_bits <= 4'd0; tx_shift <= 8'd0; tx_par <= 1'b0;
            txd <= 1'b1;  rts <= 1'b1;
        end else begin
            n_rdrf = rdrf; n_tdre = tdre; n_fe = fe; n_pe = pe; n_ovrn = ovrn;
            n_sr_dcd = sr_dcd; n_ovr_pend = overrun_pending; n_dcd_irq = dcd_irq;

            // ---------------- CPU side ----------------
            if (rd_sr && dcd_irq == DCD_RD_STATUS)
                n_dcd_irq = DCD_RD_DATA;

            if (rd_rdr) begin
                if (overrun_pending) begin
                    n_ovrn = 1'b1;
                    n_ovr_pend = 1'b0;
                end else begin
                    n_ovrn = 1'b0;
                    n_rdrf = 1'b0;
                end
                if (dcd_irq == DCD_RD_DATA)
                    n_dcd_irq = DCD_NONE;
            end

            if (wr_tdr && !in_reset) begin
                tdr    <= din;
                n_tdre = 1'b0;
            end

            if (wr_cr) begin
                cr <= din;
                if (din[1:0] == 2'b11) begin
                    // Master reset
                    n_dcd_irq  = DCD_NONE;
                    n_ovr_pend = 1'b0;
                    rx_state <= ST_START; rx_cnt <= 7'd0;
                    tx_state <= ST_START; tx_cnt <= 7'd0;
                    txd <= 1'b1;
                    n_tdre = 1'b1;
                    n_rdrf = 1'b0; n_fe = 1'b0; n_pe = 1'b0; n_ovrn = 1'b0;
                    n_sr_dcd = dcd;
                    if (first_mr) begin
                        rts <= 1'b1;
                        first_mr <= 1'b0;
                    end else
                        rts <= (din[6:5] == 2'b10);
                end else
                    rts <= (din[6:5] == 2'b10);
            end

            // ---------------- Receiver ----------------
            if (rx_tick && !in_reset && !wr_cr) begin
                if (dcd) begin
                    if (!sr_dcd) begin
                        n_sr_dcd  = 1'b1;
                        n_dcd_irq = DCD_RD_STATUS;
                    end
                    rx_state <= ST_START;
                    rx_cnt   <= 7'd0;
                end else begin
                    if (n_dcd_irq == DCD_NONE)
                        n_sr_dcd = 1'b0;
                    nc = rx_cnt + 7'd1;
                    case (rx_state)
                    ST_START:
                        if (!rxd) begin
                            if (nc >= half_div) begin
                                rx_state <= ST_DATA;
                                rx_cnt   <= 7'd0;
                                rx_shift <= 8'd0;
                                rx_bits  <= 4'd0;
                                rx_par   <= 1'b0;
                            end else
                                rx_cnt <= nc;
                        end else
                            rx_cnt <= 7'd0;
                    ST_DATA:
                        if (nc == divide) begin
                            rx_cnt <= 7'd0;
                            if (rx_bits < 4'd8)
                                rx_shift[rx_bits[2:0]] <= rxd;
                            rx_bits <= rx_bits + 4'd1;
                            bitv = rx_par ^ rxd;
                            rx_par <= bitv;
                            if ((rx_bits + 4'd1 == nbits && !par_en) ||
                                (rx_bits + 4'd1 == nbits + 4'd1 && par_en)) begin
                                if (n_rdrf) begin
                                    n_ovr_pend = 1'b1;
                                end else begin
                                    n_pe = par_en & (par_odd ? ~bitv : bitv);
                                    // Assemble the final character including this bit
                                    if (nbits == 4'd8 && !par_en)
                                        rdr <= {rxd, rx_shift[6:0]};
                                    else if (nbits == 4'd8)
                                        rdr <= rx_shift;          // last bit was parity
                                    else if (!par_en)
                                        rdr <= {1'b0, rxd, rx_shift[5:0]};
                                    else
                                        rdr <= {1'b0, rx_shift[6:0]};
                                    n_rdrf = 1'b1;
                                end
                                rx_state <= ST_STOP;
                            end
                        end else
                            rx_cnt <= nc;
                    default: // ST_STOP
                        if (nc == divide) begin
                            rx_cnt   <= 7'd0;
                            n_fe     = ~rxd;
                            rx_state <= ST_START;
                        end else
                            rx_cnt <= nc;
                    endcase
                end
            end

            // ---------------- Transmitter ----------------
            if (tx_tick && !in_reset && !wr_cr) begin
                nc = tx_cnt + 7'd1;
                case (tx_state)
                ST_START: begin
                    tx_cnt <= 7'd0;
                    if (!n_tdre && !cts) begin
                        tx_state <= ST_DATA;
                        tx_shift <= wr_tdr ? din : tdr;
                        tx_bits  <= 4'd0;
                        tx_par   <= 1'b0;
                        n_tdre   = 1'b1;
                        txd      <= 1'b0;
                    end else
                        txd <= ~brk;
                end
                ST_DATA:
                    if (nc == divide) begin
                        tx_cnt <= 7'd0;
                        if (tx_bits < nbits) begin
                            txd     <= tx_shift[tx_bits[2:0]];
                            tx_par  <= tx_par ^ tx_shift[tx_bits[2:0]];
                            tx_bits <= tx_bits + 4'd1;
                        end else if (tx_bits == nbits && par_en) begin
                            txd     <= par_odd ? ~tx_par : tx_par;
                            tx_bits <= tx_bits + 4'd1;
                        end else begin
                            tx_state <= ST_STOP;
                            tx_bits  <= 4'd0;
                            txd      <= 1'b1;
                        end
                    end else
                        tx_cnt <= nc;
                default: // ST_STOP
                    if (nc == divide) begin
                        tx_cnt  <= 7'd0;
                        tx_bits <= tx_bits + 4'd1;
                        if (tx_bits + 4'd1 == {2'b00, nstop})
                            tx_state <= ST_START;
                    end else
                        tx_cnt <= nc;
                endcase
            end

            rdrf <= n_rdrf; tdre <= n_tdre; fe <= n_fe; pe <= n_pe; ovrn <= n_ovrn;
            sr_dcd <= n_sr_dcd; overrun_pending <= n_ovr_pend; dcd_irq <= n_dcd_irq;
        end
    end

endmodule
