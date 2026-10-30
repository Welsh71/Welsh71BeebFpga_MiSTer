// Disc drive and cassette relay sounds for BeebFpga, using BeebEm's samples
//
// The samples come from sounds.rom (scripts/make_sounds_rom.py), which the menu loads
// into DDR3 next to the tape image. Its 64-byte header is picked up here as it
// downloads; the samples are read back from DDR3 through mem_*.
//
// Sample numbers follow BeebEm (Sound.h):
//   0 RelayOn  1 RelayOff  2 DriveMotor (loop)  3 HeadLoad  4 HeadUnload
//   5 HeadSeek (loop)  6 HeadStep
// and so do the triggers (Disc8271.cpp, Disc1770.cpp):
//   motor on   -> motor loop + head load       motor off -> stop motor/seek, head unload
//   seek of n tracks (8271): n = 1 head step, n > 1 seek loop for n x 24.15 ms
//   step pulses (1770): a lone step plays the step sound; steps closer together
//                       than STEP_GAP play the seek loop until they stop
//   cassette motor relay on/off -> relay click
//
// All seven samples are 8-bit unsigned at 44.1 kHz. Each sample period every playing
// voice is read once and summed. Inputs must already be in clk's domain; seek_tog
// changes once per 8271 seek and seek_n must be stable for two clocks before it does.

module drive_sound #(
    parameter integer CLK_HZ = 96000000
) (
    input  wire              clk,
    input  wire              rst,

    input  wire        [1:0] level,     // 0 off, 1 low, 2 medium, 3 loud
    input  wire              relay_en,  // cassette relay clicks

    input  wire              motor,     // drive motor / head loaded
    input  wire              step,      // 1770 step pulse
    input  wire              seek_tog,  // 8271 seek
    input  wire        [6:0] seek_n,    // tracks moved by that seek
    input  wire              tape_motor,

    // sounds.rom download (header capture)
    input  wire              dl_active,
    input  wire              dl_wr,
    input  wire       [16:0] dl_addr,
    input  wire        [7:0] dl_data,

    // sample reads (byte offset within sounds.rom)
    output reg               mem_rd,
    output reg        [16:0] mem_addr,
    input  wire        [7:0] mem_data,
    input  wire              mem_valid,

    output wire              loaded,
    output reg  signed [17:0] audio
);

    localparam integer TICK      = (CLK_HZ + 22050) / 44100;
    localparam integer SEEK_TRK  = CLK_HZ / 1000 * 2415 / 100;     // 24.15 ms per track
    localparam integer STEP_GAP  = CLK_HZ / 1000 * 35;              // 35 ms

    // ------------------------------------------------------------ header
    reg  [31:0] magic;
    reg   [7:0] version;
    reg  [16:0] off [0:6];
    reg  [16:0] len [0:6];
    reg         dl_seen;

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            magic <= 32'd0; version <= 8'd0; dl_seen <= 1'b0;
        end else if (dl_active && dl_wr && dl_addr < 17'd64) begin
            dl_seen <= 1'b1;
            case (dl_addr[5:0])
                6'd0: magic[7:0]   <= dl_data;
                6'd1: magic[15:8]  <= dl_data;
                6'd2: magic[23:16] <= dl_data;
                6'd3: magic[31:24] <= dl_data;
                6'd4: version      <= dl_data;
                default: ;
            endcase
            for (k = 0; k < 7; k = k + 1) begin
                if (dl_addr[5:0] == 8 + 8*k)     off[k][7:0]  <= dl_data;
                if (dl_addr[5:0] == 8 + 8*k + 1) off[k][15:8] <= dl_data;
                if (dl_addr[5:0] == 8 + 8*k + 2) off[k][16]   <= dl_data[0];
                if (dl_addr[5:0] == 8 + 8*k + 4) len[k][7:0]  <= dl_data;
                if (dl_addr[5:0] == 8 + 8*k + 5) len[k][15:8] <= dl_data;
                if (dl_addr[5:0] == 8 + 8*k + 6) len[k][16]   <= dl_data[0];
            end
        end
    end

    assign loaded = dl_seen && !dl_active && magic == 32'h444E5342 && version == 8'd1; // "BSND"

    // ------------------------------------------------------------ events
    reg         motor_d, step_d, seek_d, tape_d;
    reg  [28:0] seek_timer;
    reg  [28:0] seek_len;       // seek_n x 24.15 ms, registered (seek_n settles well before seek_tog)
    reg  [22:0] step_win;
    wire        drive_on = loaded && level != 2'd0;
    wire        relay_on = loaded && relay_en;

    // per-voice state
    reg   [6:0] on, loop;
    reg  [16:0] pos [0:6];
    reg   [6:0] start;          // start (or restart) a voice this cycle
    reg   [6:0] stop;

    always @(*) begin
        start = 7'd0;
        stop  = 7'd0;
        if (drive_on) begin
            if (motor && !motor_d)  start = start | 7'b0001100;            // motor loop, head load
            if (!motor && motor_d) begin
                start = start | 7'b0010000;                                 // head unload
                stop  = stop  | 7'b0100100;                                 // motor, seek
            end
            if (seek_tog != seek_d) begin
                if (seek_n == 7'd1)     start = start | 7'b1000000;        // step
                else if (seek_n != 7'd0) start = start | 7'b0100000;       // seek loop
            end
            if (step && !step_d) begin
                if (step_win != 23'd0) begin
                    if (!on[5]) start = start | 7'b0100000;
                end else
                    start = start | 7'b1000000;
            end
            if (seek_timer == 29'd1) stop = stop | 7'b0100000;
        end else
            stop = stop | 7'b1111100;
        if (relay_on) begin
            if (tape_motor && !tape_d)  start = start | 7'b0000001;
            if (!tape_motor && tape_d)  start = start | 7'b0000010;
        end else
            stop = stop | 7'b0000011;
    end

    always @(posedge clk) begin
        motor_d <= motor;
        step_d  <= step;
        seek_d  <= seek_tog;
        tape_d  <= tape_motor;
        seek_len <= seek_n * SEEK_TRK;
        if (rst) begin
            seek_timer <= 29'd0;
            step_win   <= 23'd0;
        end else begin
            if (seek_timer != 29'd0) seek_timer <= seek_timer - 29'd1;
            if (step_win   != 23'd0) step_win   <= step_win - 23'd1;
            if (seek_tog != seek_d && seek_n > 7'd1) seek_timer <= seek_len;
            if (step && !step_d) begin
                step_win <= STEP_GAP;
                if (step_win != 23'd0) seek_timer <= STEP_GAP;
            end
            if (!motor && motor_d) seek_timer <= 29'd0;
        end
    end

    // ------------------------------------------------------------ mixer
    reg  [11:0] tick;
    reg   [2:0] v;              // voice being read
    reg         busy, wait_d;
    reg  signed [17:0] acc;

    wire signed [8:0] s = $signed({1'b0, mem_data}) - 9'sd128;
    // drive voices follow the level setting; relay clicks are fixed at medium
    wire  [2:0] sh = (v < 3'd2) ? 3'd6 : (level == 2'd1) ? 3'd5 : (level == 2'd2) ? 3'd6 : 3'd7;
    wire signed [17:0] s_scaled = $signed({{9{s[8]}}, s}) <<< sh;

    integer i;
    always @(posedge clk) begin
        mem_rd <= 1'b0;
        if (rst) begin
            tick <= 12'd0; busy <= 1'b0; wait_d <= 1'b0; on <= 7'd0; loop <= 7'd0;
            audio <= 18'sd0; acc <= 18'sd0; v <= 3'd0;
        end else begin
            tick <= (tick == TICK - 1) ? 12'd0 : tick + 12'd1;

            if (!busy) begin
                if (tick == 12'd0) begin
                    busy <= 1'b1; v <= 3'd0; acc <= 18'sd0; wait_d <= 1'b0;
                end
            end else if (wait_d) begin
                if (mem_valid) begin
                    wait_d <= 1'b0;
                    acc    <= acc + s_scaled;
                    if (pos[v] + 17'd1 >= len[v]) begin
                        pos[v] <= 17'd0;
                        if (!loop[v]) on[v] <= 1'b0;
                    end else
                        pos[v] <= pos[v] + 17'd1;
                    if (v == 3'd6) begin busy <= 1'b0; audio <= acc + s_scaled; end
                    else v <= v + 3'd1;
                end
            end else if (on[v] && len[v] != 17'd0) begin
                mem_rd   <= 1'b1;
                mem_addr <= off[v] + pos[v];
                wait_d   <= 1'b1;
            end else begin
                if (v == 3'd6) begin busy <= 1'b0; audio <= acc; end
                else v <= v + 3'd1;
            end

            // events win over the mixer's own update
            for (i = 0; i < 7; i = i + 1) begin
                if (stop[i])  on[i] <= 1'b0;
                if (start[i]) begin
                    on[i]   <= 1'b1;
                    pos[i]  <= 17'd0;
                    loop[i] <= (i == 2) || (i == 5);
                end
            end
        end
    end

endmodule
