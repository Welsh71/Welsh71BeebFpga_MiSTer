// gzip / DEFLATE decompressor for BeebFpga tape images
//
// Decompresses a gzip file held in DDR3 (in_base .. in_base+in_len-1) into
// DDR3 starting at byte 0, so compressed UEFs can be played. Written for
// small area rather than speed, and uses no block RAM (the core has none
// left): Huffman tables are in logic, and the 32KB history window is read
// back from the output already written to DDR3.
//
// Follows RFC 1951/1952 and the structure of Mark Adler's puff.c:
//  * gzip header with optional FEXTRA / FNAME / FCOMMENT / FHCRC
//  * stored, fixed-Huffman and dynamic-Huffman blocks
//  * canonical Huffman decoding one bit at a time from per-length counts and
//    a symbol table sorted by code
// CRC32 and ISIZE in the trailer are not checked.
//
// Output goes out as 64-bit word writes with byte enables (write combining).
// The word being built and the last word written are forwarded to window
// reads, so short-distance copies never wait for DDR3.

module inflate (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [24:0] in_base,
    input  wire [24:0] in_len,
    output reg         busy,
    output reg         done,          // finished (check err)
    output reg         err,
    output reg  [24:0] out_len,

    // compressed input, one byte at a time
    output reg         in_rd,
    output reg  [24:0] in_addr,
    input  wire  [7:0] in_data,
    input  wire        in_valid,

    // window (history) reads
    output reg         win_rd,
    output reg  [24:0] win_addr,
    input  wire  [7:0] win_data,
    input  wire        win_valid,

    // output, 64-bit words
    output reg         out_wr,
    output reg  [21:0] out_wa,
    output reg  [63:0] out_wd,
    output reg   [7:0] out_be,
    input  wire        out_busy
);

    // ------------------------------------------------------------------
    // Tables
    // ------------------------------------------------------------------
    localparam T_L = 2'd0, T_D = 2'd1, T_C = 2'd2;

    (* ramstyle = "logic" *) reg [3:0] lens  [0:319];  // lit/len then distance code lengths
    (* ramstyle = "logic" *) reg [3:0] clens [0:18];   // code-length code lengths
    (* ramstyle = "logic" *) reg [8:0] symL  [0:287];
    (* ramstyle = "logic" *) reg [4:0] symD  [0:31];
    (* ramstyle = "logic" *) reg [4:0] symC  [0:18];
    reg [8:0] cntL [0:15];
    reg [8:0] cntD [0:15];
    reg [8:0] cntC [0:15];
    reg [8:0] offs [0:15];

    function [4:0] cl_order;
        input [4:0] i;
        case (i)
            5'd0: cl_order = 16; 5'd1: cl_order = 17; 5'd2: cl_order = 18; 5'd3: cl_order = 0;
            5'd4: cl_order = 8;  5'd5: cl_order = 7;  5'd6: cl_order = 9;  5'd7: cl_order = 6;
            5'd8: cl_order = 10; 5'd9: cl_order = 5;  5'd10: cl_order = 11; 5'd11: cl_order = 4;
            5'd12: cl_order = 12; 5'd13: cl_order = 3; 5'd14: cl_order = 13; 5'd15: cl_order = 2;
            5'd16: cl_order = 14; 5'd17: cl_order = 1; default: cl_order = 15;
        endcase
    endfunction

    function [8:0] len_base;      // symbol 257..285 -> 0..28
        input [4:0] i;
        case (i)
            5'd0: len_base = 3;   5'd1: len_base = 4;   5'd2: len_base = 5;   5'd3: len_base = 6;
            5'd4: len_base = 7;   5'd5: len_base = 8;   5'd6: len_base = 9;   5'd7: len_base = 10;
            5'd8: len_base = 11;  5'd9: len_base = 13;  5'd10: len_base = 15; 5'd11: len_base = 17;
            5'd12: len_base = 19; 5'd13: len_base = 23; 5'd14: len_base = 27; 5'd15: len_base = 31;
            5'd16: len_base = 35; 5'd17: len_base = 43; 5'd18: len_base = 51; 5'd19: len_base = 59;
            5'd20: len_base = 67; 5'd21: len_base = 83; 5'd22: len_base = 99; 5'd23: len_base = 115;
            5'd24: len_base = 131; 5'd25: len_base = 163; 5'd26: len_base = 195; 5'd27: len_base = 227;
            default: len_base = 258;
        endcase
    endfunction

    function [2:0] len_extra;
        input [4:0] i;
        if (i < 8 || i == 28) len_extra = 0;
        else                  len_extra = (i - 4) >> 2;
    endfunction

    function [14:0] dist_base;    // 0..29
        input [4:0] i;
        case (i)
            5'd0: dist_base = 1;     5'd1: dist_base = 2;     5'd2: dist_base = 3;     5'd3: dist_base = 4;
            5'd4: dist_base = 5;     5'd5: dist_base = 7;     5'd6: dist_base = 9;     5'd7: dist_base = 13;
            5'd8: dist_base = 17;    5'd9: dist_base = 25;    5'd10: dist_base = 33;   5'd11: dist_base = 49;
            5'd12: dist_base = 65;   5'd13: dist_base = 97;   5'd14: dist_base = 129;  5'd15: dist_base = 193;
            5'd16: dist_base = 257;  5'd17: dist_base = 385;  5'd18: dist_base = 513;  5'd19: dist_base = 769;
            5'd20: dist_base = 1025; 5'd21: dist_base = 1537; 5'd22: dist_base = 2049; 5'd23: dist_base = 3073;
            5'd24: dist_base = 4097; 5'd25: dist_base = 6145; 5'd26: dist_base = 8193; 5'd27: dist_base = 12289;
            5'd28: dist_base = 16385; default: dist_base = 24577;
        endcase
    endfunction

    function [3:0] dist_extra;
        input [4:0] i;
        if (i < 4) dist_extra = 0;
        else       dist_extra = (i - 2) >> 1;
    endfunction

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    localparam
        S_IDLE    = 6'd0,  S_GZ      = 6'd1,  S_GZ_XLEN = 6'd2,  S_GZ_SKIP = 6'd3,
        S_GZ_STR  = 6'd4,  S_GZ_HCRC = 6'd5,  S_BLK     = 6'd6,  S_ST_ALGN = 6'd7,
        S_ST_LEN  = 6'd8,  S_ST_COPY = 6'd9,  S_FIX     = 6'd10, S_DYN     = 6'd11,
        S_DYN_CL  = 6'd12, S_DYN_LEN = 6'd13, S_DYN_REP = 6'd14, S_DYN_RX  = 6'd15,
        S_SYM     = 6'd16, S_LEN_X   = 6'd17, S_DIST    = 6'd18, S_DIST_X  = 6'd19,
        S_COPY    = 6'd20, S_WIN     = 6'd21, S_OUT     = 6'd22, S_FIN     = 6'd23,
        S_FIN2    = 6'd24, S_DONE    = 6'd25, S_ERR     = 6'd26,
        S_DEC     = 6'd27, S_DEC_SYM = 6'd28,
        S_B_CNT   = 6'd29, S_B_OFF   = 6'd30, S_B_SYM   = 6'd31, S_B_CLR   = 6'd32,
        S_AFTER_C = 6'd33, S_AFTER_L = 6'd34, S_AFTER_D = 6'd35, S_FIX_D   = 6'd36,
        S_ST_COPY2 = 6'd37, S_COPY0   = 6'd38;

    reg  [5:0]  st, ret, dret, bret, oret;

    // bit reader
    reg  [31:0] bb;
    reg  [5:0]  bc;
    reg  [24:0] ipos, iend;
    reg         ipend;

    // gzip header
    reg  [3:0]  gi;
    reg  [7:0]  gflg;
    reg  [15:0] gskip;
    reg  [1:0]  gstr;          // FNAME / FCOMMENT still to skip

    // blocks
    reg         bfinal;
    reg  [8:0]  hlit;
    reg  [5:0]  hdist;
    reg  [4:0]  hclen;
    reg  [8:0]  li;            // index into lens / clens
    reg  [3:0]  prevlen;
    reg  [7:0]  rep;
    reg  [3:0]  repval;
    reg  [15:0] stlen;

    // Huffman decode
    reg  [1:0]  tsel;
    reg  [15:0] code, first, index;
    reg  [3:0]  dlen;
    reg  [8:0]  sym_idx;
    reg  [8:0]  dsym;

    // table build
    reg  [8:0]  bi, bn;
    reg  [3:0]  bl;
    reg  [3:0]  lreg;          // registered code length (build pipeline)
    reg  [8:0]  oreg;          // registered offset
    reg  [1:0]  bph;           // build pipeline phase

    // match
    reg  [8:0]  mlen;
    reg  [15:0] mdist;

    // output
    reg  [24:0] opos;
    reg  [63:0] cur_w, prev_w;
    reg  [21:0] cur_wa, prev_wa;
    reg  [7:0]  cur_be;
    reg         prev_ok;
    reg  [7:0]  ob;
    reg         wait_win;
    reg  [2:0]  starve;        // clks spent waiting for bits that can't arrive

    // ------------------------------------------------------------------
    // Combinational helpers
    // ------------------------------------------------------------------
    // Table-build length read, pipelined for timing: lidx tracks
    // (T_D ? hlit : 0) + bi as a register, and the read is registered
    // into len_at, so it is valid one clk after bi/lidx change.
    reg  [8:0]  lidx;
    reg  [3:0]  len_at;
    always @(posedge clk)
        len_at <= (tsel == T_C) ? clens[lidx[4:0]] : lens[lidx];

    reg  [8:0]  cnt_at;
    always @(*) begin
        case (tsel)
            T_C:     cnt_at = cntC[dlen];
            T_D:     cnt_at = cntD[dlen];
            default: cnt_at = cntL[dlen];
        endcase
    end

    reg  [8:0]  cnt_bl;        // count for table build at length bl
    always @(*) begin
        case (tsel)
            T_C:     cnt_bl = cntC[bl];
            T_D:     cnt_bl = cntD[bl];
            default: cnt_bl = cntL[bl];
        endcase
    end

    wire [15:0] ncode   = code | {15'd0, bb[0]};
    wire [15:0] cdiff   = ncode - first;
    // Copy source and "flush the output word" are registered so the 25-bit
    // output position never feeds the state machine directly (timing at 96MHz).
    reg  [24:0] wsrc;          // opos - mdist, set in S_COPY0
    reg         copy_bad;      // distance reaches before the start of the output
    reg         need_flush;    // cur_w belongs to another word than opos
    always @(posedge clk)
        need_flush <= (cur_be != 8'd0) && (opos[24:3] != cur_wa);

    // bits consumed this clk (applied at the end of the always block)
    reg  [5:0]  cons;
    integer     k;

    always @(posedge clk) begin
        in_rd  <= 1'b0;
        win_rd <= 1'b0;
        out_wr <= 1'b0;
        done   <= 1'b0;
        cons    = 6'd0;

        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; err <= 1'b0; ipend <= 1'b0;
        end else begin
            case (st)
            // ---------------- start ----------------
            S_IDLE:
                if (start) begin
                    busy <= 1'b1; err <= 1'b0;
                    ipos <= in_base; iend <= in_base + in_len; ipend <= 1'b0;
                    bb <= 32'd0; bc <= 6'd0;
                    gi <= 4'd0; opos <= 25'd0; cur_be <= 8'd0; prev_ok <= 1'b0;
                    st <= S_GZ;
                end

            // ---------------- gzip header ----------------
            S_GZ:
                if (bc >= 6'd8) begin
                    cons = 6'd8;
                    gi <= gi + 4'd1;
                    case (gi)
                        4'd0: if (bb[7:0] != 8'h1F) st <= S_ERR;
                        4'd1: if (bb[7:0] != 8'h8B) st <= S_ERR;
                        4'd2: if (bb[7:0] != 8'h08) st <= S_ERR;
                        4'd3: gflg <= bb[7:0];
                        4'd9: begin
                            gstr <= {gflg[4], gflg[3]};
                            st <= gflg[2] ? S_GZ_XLEN : S_GZ_STR;
                        end
                        default: ;
                    endcase
                end
            S_GZ_XLEN:
                if (bc >= 6'd16) begin
                    cons = 6'd16; gskip <= bb[15:0]; st <= S_GZ_SKIP;
                end
            S_GZ_SKIP:
                if (gskip == 16'd0)
                    st <= S_GZ_STR;
                else if (bc >= 6'd8) begin
                    cons = 6'd8; gskip <= gskip - 16'd1;
                end
            S_GZ_STR:                       // skip zero-terminated name, then comment
                if (gstr == 2'b00)
                    st <= gflg[1] ? S_GZ_HCRC : S_BLK;
                else if (bc >= 6'd8) begin
                    cons = 6'd8;
                    if (bb[7:0] == 8'd0)
                        gstr <= gstr[0] ? {gstr[1], 1'b0} : 2'b00;
                end
            S_GZ_HCRC:
                if (bc >= 6'd16) begin cons = 6'd16; st <= S_BLK; end

            // ---------------- block header ----------------
            S_BLK:
                if (bc >= 6'd3) begin
                    cons = 6'd3;
                    bfinal <= bb[0];
                    case (bb[2:1])
                        2'd0: st <= S_ST_ALGN;
                        2'd1: begin li <= 9'd0; st <= S_FIX; end
                        2'd2: st <= S_DYN;
                        default: st <= S_ERR;
                    endcase
                end

            // ---------------- stored ----------------
            S_ST_ALGN: begin
                cons = {3'd0, bc[2:0]};
                st <= S_ST_LEN;
            end
            S_ST_LEN:
                if (bc >= 6'd32) begin
                    cons = 6'd32;
                    if (bb[15:0] != ~bb[31:16]) st <= S_ERR;
                    else begin stlen <= bb[15:0]; st <= S_ST_COPY; end
                end
            S_ST_COPY:
                if (stlen == 16'd0)
                    st <= bfinal ? S_FIN : S_BLK;
                else if (bc >= 6'd8) begin
                    cons = 6'd8;
                    ob <= bb[7:0]; stlen <= stlen - 16'd1;
                    oret <= S_ST_COPY; st <= S_OUT;
                end

            // ---------------- fixed Huffman ----------------
            S_FIX: begin
                lens[li] <= (li < 9'd144) ? 4'd8 : (li < 9'd256) ? 4'd9 :
                            (li < 9'd280) ? 4'd7 : (li < 9'd288) ? 4'd8 : 4'd5;
                if (li == 9'd317) begin
                    hlit <= 9'd288; hdist <= 6'd30;
                    tsel <= T_L; bn <= 9'd288; bret <= S_FIX_D; st <= S_B_CLR;
                end else
                    li <= li + 9'd1;
            end
            S_FIX_D: begin
                tsel <= T_D; bn <= 9'd30; bret <= S_SYM; st <= S_B_CLR;
            end

            // ---------------- dynamic Huffman ----------------
            S_DYN:
                if (bc >= 6'd14) begin
                    cons = 6'd14;
                    hlit  <= {4'd0, bb[4:0]} + 9'd257;
                    hdist <= {1'b0, bb[9:5]} + 6'd1;
                    hclen <= {1'b0, bb[13:10]} + 5'd4;
                    for (k = 0; k < 19; k = k + 1) clens[k] <= 4'd0;
                    li <= 9'd0;
                    st <= S_DYN_CL;
                end
            S_DYN_CL:
                if (li[4:0] == hclen) begin
                    if (hlit > 9'd286 || hdist > 6'd30) st <= S_ERR;
                    else begin
                        tsel <= T_C; bn <= 9'd19; bret <= S_AFTER_C; st <= S_B_CLR;
                    end
                end else if (bc >= 6'd3) begin
                    cons = 6'd3;
                    clens[cl_order(li[4:0])] <= {1'b0, bb[2:0]};
                    li <= li + 9'd1;
                end
            S_AFTER_C: begin
                li <= 9'd0; prevlen <= 4'd0; st <= S_DYN_LEN;
            end
            S_DYN_LEN:
                if (li == hlit + {3'd0, hdist}) begin
                    if (lens[256] == 4'd0) st <= S_ERR;        // no end-of-block code
                    else begin
                        tsel <= T_L; bn <= hlit; bret <= S_AFTER_L; st <= S_B_CLR;
                    end
                end else begin
                    tsel <= T_C; dret <= S_DYN_RX; st <= S_DEC;
                    code <= 16'd0; first <= 16'd0; index <= 16'd0; dlen <= 4'd1;
                end
            S_DYN_RX:                       // dsym = code-length symbol
                if (dsym < 9'd16) begin
                    lens[li] <= dsym[3:0]; prevlen <= dsym[3:0];
                    li <= li + 9'd1; st <= S_DYN_LEN;
                end else if (dsym == 9'd16) begin
                    if (li == 9'd0) st <= S_ERR;
                    else if (bc >= 6'd2) begin
                        cons = 6'd2; rep <= 8'd3 + {6'd0, bb[1:0]}; repval <= prevlen; st <= S_DYN_REP;
                    end
                end else if (dsym == 9'd17) begin
                    if (bc >= 6'd3) begin
                        cons = 6'd3; rep <= 8'd3 + {5'd0, bb[2:0]}; repval <= 4'd0; prevlen <= 4'd0; st <= S_DYN_REP;
                    end
                end else begin
                    if (bc >= 6'd7) begin
                        cons = 6'd7; rep <= 8'd11 + {1'b0, bb[6:0]}; repval <= 4'd0; prevlen <= 4'd0; st <= S_DYN_REP;
                    end
                end
            S_DYN_REP:
                if (rep == 8'd0)
                    st <= S_DYN_LEN;
                else if (li == hlit + {3'd0, hdist})
                    st <= S_ERR;                              // repeat runs past the end
                else begin
                    lens[li] <= repval; li <= li + 9'd1; rep <= rep - 8'd1;
                end
            S_AFTER_L: begin
                tsel <= T_D; bn <= {3'd0, hdist}; bret <= S_SYM; st <= S_B_CLR;
            end

            // ---------------- table build ----------------
            S_B_CLR: begin
                for (k = 0; k < 16; k = k + 1)
                    case (tsel)
                        T_C: cntC[k] <= 9'd0;
                        T_D: cntD[k] <= 9'd0;
                        default: cntL[k] <= 9'd0;
                    endcase
                bi <= 9'd0; lidx <= (tsel == T_D) ? hlit : 9'd0; bph <= 2'd0; st <= S_B_CNT;
            end
            // count codes of each length: read length, then increment
            S_B_CNT:
                if (bph == 2'd0) begin
                    if (bi == bn) begin
                        offs[1] <= 9'd0; bl <= 4'd1; st <= S_B_OFF;
                    end else begin
                        bph <= 2'd3;                 // wait for len_at
                    end
                end else if (bph == 2'd3) begin
                    lreg <= len_at; bph <= 2'd1;
                end else begin
                    case (tsel)
                        T_C: cntC[lreg] <= cntC[lreg] + 9'd1;
                        T_D: cntD[lreg] <= cntD[lreg] + 9'd1;
                        default: cntL[lreg] <= cntL[lreg] + 9'd1;
                    endcase
                    bi <= bi + 9'd1; lidx <= lidx + 9'd1; bph <= 2'd0;
                end
            S_B_OFF:
                if (bl == 4'd15) begin
                    bi <= 9'd0; lidx <= (tsel == T_D) ? hlit : 9'd0; bph <= 2'd0; st <= S_B_SYM;
                end else begin
                    offs[bl + 4'd1] <= offs[bl] + cnt_bl;
                    bl <= bl + 4'd1;
                end
            // place each symbol in code order: read length, read offset, write
            S_B_SYM:
                case (bph)
                2'd0:
                    if (bi == bn)
                        st <= bret;
                    else
                        bph <= 2'd3;                 // wait for len_at
                2'd3: begin
                    lreg <= len_at; bph <= 2'd1;
                end
                2'd1:
                    if (lreg == 4'd0) begin
                        bi <= bi + 9'd1; lidx <= lidx + 9'd1; bph <= 2'd0;
                    end else begin
                        oreg <= offs[lreg]; bph <= 2'd2;
                    end
                2'd2: begin
                    case (tsel)
                        T_C: symC[oreg[4:0]] <= bi[4:0];
                        T_D: symD[oreg[4:0]] <= bi[4:0];
                        default: symL[oreg] <= bi;
                    endcase
                    offs[lreg] <= oreg + 9'd1;
                    bi <= bi + 9'd1; lidx <= lidx + 9'd1; bph <= 2'd0;
                end
                endcase

            // ---------------- Huffman decode (one bit per clk) ----------------
            S_DEC:
                if (bc >= 6'd1) begin
                    cons = 6'd1;
                    if (cdiff < {7'd0, cnt_at}) begin
                        sym_idx <= index[8:0] + cdiff[8:0];
                        st <= S_DEC_SYM;
                    end else if (dlen == 4'd15)
                        st <= S_ERR;                              // invalid code
                    else begin
                        index <= index + {7'd0, cnt_at};
                        first <= (first + {7'd0, cnt_at}) << 1;
                        code  <= ncode << 1;
                        dlen  <= dlen + 4'd1;
                    end
                end
            S_DEC_SYM: begin
                case (tsel)
                    T_C: dsym <= {4'd0, symC[sym_idx[4:0]]};
                    T_D: dsym <= {4'd0, symD[sym_idx[4:0]]};
                    default: dsym <= symL[sym_idx];
                endcase
                st <= dret;
            end

            // ---------------- symbols ----------------
            S_SYM: begin
                tsel <= T_L; dret <= S_LEN_X; st <= S_DEC;
                code <= 16'd0; first <= 16'd0; index <= 16'd0; dlen <= 4'd1;
            end
            S_LEN_X:                        // dsym = literal/length symbol
                if (dsym < 9'd256) begin
                    ob <= dsym[7:0]; oret <= S_SYM; st <= S_OUT;
                end else if (dsym == 9'd256)
                    st <= bfinal ? S_FIN : S_BLK;
                else if (dsym > 9'd285)
                    st <= S_ERR;
                else begin
                    // (dsym-257) is dsym[4:0]-1 for 257..285
                    if (bc >= {3'd0, len_extra(dsym[4:0] - 5'd1)}) begin
                        cons = {3'd0, len_extra(dsym[4:0] - 5'd1)};
                        mlen <= len_base(dsym[4:0] - 5'd1) +
                                (bb[8:0] & ((9'd1 << len_extra(dsym[4:0] - 5'd1)) - 9'd1));
                        tsel <= T_D; dret <= S_DIST; st <= S_DEC;
                        code <= 16'd0; first <= 16'd0; index <= 16'd0; dlen <= 4'd1;
                    end
                end
            S_DIST:                         // dsym = distance symbol
                if (dsym > 9'd29)
                    st <= S_ERR;
                else
                    st <= S_DIST_X;
            S_DIST_X: begin
                // up to 13 extra bits
                if (bc >= {2'd0, dist_extra(dsym[4:0])}) begin
                    cons = {2'd0, dist_extra(dsym[4:0])};
                    mdist <= {1'b0, dist_base(dsym[4:0])} +
                             (bb[15:0] & ((16'd1 << dist_extra(dsym[4:0])) - 16'd1));
                    st <= S_COPY0;
                end
            end
            S_COPY0: begin                  // register the copy source and range check
                wsrc     <= opos - {9'd0, mdist};
                copy_bad <= (mdist == 16'd0) || ({9'd0, mdist} > opos);
                st <= S_COPY;
            end
            S_COPY:
                if (copy_bad)
                    st <= S_ERR;                              // reaches before the start
                else if (mlen == 9'd0)
                    st <= S_SYM;
                else
                    st <= S_WIN;
            S_WIN:                          // fetch one byte from the window
                if (wsrc[24:3] == cur_wa && cur_be[wsrc[2:0]]) begin
                    ob <= cur_w[wsrc[2:0]*8 +: 8];
                    mlen <= mlen - 9'd1; oret <= S_COPY0; st <= S_OUT;
                end else if (prev_ok && wsrc[24:3] == prev_wa) begin
                    ob <= prev_w[wsrc[2:0]*8 +: 8];
                    mlen <= mlen - 9'd1; oret <= S_COPY0; st <= S_OUT;
                end else if (win_valid) begin
                    ob <= win_data;
                    mlen <= mlen - 9'd1; oret <= S_COPY0; st <= S_OUT;
                end else if (!win_rd && !wait_win) begin
                    win_rd <= 1'b1; win_addr <= wsrc;
                end

            // ---------------- output one byte ----------------
            S_OUT:
                if (need_flush) begin
                    if (!out_busy && !out_wr) begin
                        out_wr <= 1'b1; out_wa <= cur_wa; out_wd <= cur_w; out_be <= cur_be;
                        prev_w <= cur_w; prev_wa <= cur_wa; prev_ok <= 1'b1;
                        cur_be <= 8'd0;
                    end
                end else begin
                    cur_w[opos[2:0]*8 +: 8] <= ob;
                    cur_be <= cur_be | (8'd1 << opos[2:0]);
                    cur_wa <= opos[24:3];
                    opos <= opos + 25'd1;
                    st <= oret;
                end

            // ---------------- finish ----------------
            S_FIN:
                if (cur_be == 8'd0)
                    st <= S_FIN2;
                else if (!out_busy && !out_wr) begin
                    out_wr <= 1'b1; out_wa <= cur_wa; out_wd <= cur_w; out_be <= cur_be;
                    cur_be <= 8'd0;
                end
            S_FIN2:
                if (!out_busy && !out_wr) begin
                    out_len <= opos; done <= 1'b1; busy <= 1'b0; st <= S_IDLE;
                end
            S_ERR: begin
                err <= 1'b1; done <= 1'b1; busy <= 1'b0; out_len <= 25'd0; st <= S_IDLE;
            end
            default: st <= S_ERR;
            endcase

            // ---------------- truncated input ----------------
            // A state that reads bits but consumed none while the input is
            // exhausted can never continue: report an error instead of hanging.
            if (busy && cons == 6'd0 && ipos >= iend && !ipend && !in_rd &&
                (st == S_GZ || st == S_GZ_XLEN || st == S_GZ_SKIP || st == S_GZ_STR ||
                 st == S_GZ_HCRC || st == S_BLK || st == S_ST_LEN || st == S_ST_COPY ||
                 st == S_DYN || st == S_DYN_CL || st == S_DYN_RX || st == S_DEC ||
                 st == S_LEN_X || st == S_DIST_X)) begin
                if (starve == 3'd7) st <= S_ERR;
                else starve <= starve + 3'd1;
            end else
                starve <= 3'd0;

            // ---------------- bit reader ----------------
            // consume, then append an arriving byte, then request the next one
            begin : bitrd
                reg [31:0] nb;
                reg [5:0]  nc;
                nb = bb >> cons;
                nc = bc - cons;
                if (in_valid && ipend) begin
                    nb = nb | ({24'd0, in_data} << nc);
                    nc = nc + 6'd8;
                    ipend <= 1'b0;
                end
                if (st == S_IDLE && !start) begin
                    nb = 32'd0; nc = 6'd0;
                end
                bb <= nb;
                bc <= nc;
                if (busy && !ipend && !(in_valid && ipend) && nc <= 6'd24 && ipos < iend && !in_rd) begin
                    in_rd   <= 1'b1;
                    in_addr <= ipos;
                    ipos    <= ipos + 25'd1;
                    ipend   <= 1'b1;
                end
                if (st == S_IDLE && start) begin
                    ipos <= in_base; ipend <= 1'b0;
                end
            end
        end
    end

    // a window read is outstanding from when it is issued until win_valid
    always @(posedge clk) begin
        if (rst) wait_win <= 1'b0;
        else if (win_rd) wait_win <= 1'b1;
        else if (win_valid) wait_win <= 1'b0;
    end

endmodule
