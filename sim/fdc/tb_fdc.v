// Run (OSS CVC): python3 v2001.py ../../rtl/fdc1772/fdc1772.v fdc_sim.v && python3 zinit.py fdc_sim.v &&
//   sed -i "/blk2\.i = 0;/d" fdc_sim.v && cp ../../rtl/fdc1772/floppy.v floppy_sim.v && python3 zinit.py floppy_sim.v &&
//   cvc64 +large tb_fdc.v fdc_sim.v floppy_sim.v && ./cvcsim
// (v2001.py/zinit.py make a sim-only Verilog-2001 copy that CVC accepts, with power-up zeros.)
// Testbench for the fdc1772 Write Track (&F0) handshake, driven the way
// Acorn DFS 2.26 drives it: an NMI on every rising DRQ/INTRQ, an NMI handler
// that only transfers when (status & &5F) == &03, and a foreground loop that
// polls the status register for busy to go high and then low.
`timescale 1ns/1ps
module tb;
  reg clk = 0; always #62.5 clk = ~clk;          // 8 MHz cpu clock
  reg en = 0;  always @(posedge clk) en <= ~en;  // 4 MHz clk8m_en

  reg  [1:0] floppy_drive = 2'b11;
  reg        floppy_reset = 0;
  reg  [1:0] img_mounted = 0, img_wp = 0;
  reg [31:0] img_size = 0;
  reg  [1:0] cpu_addr = 0; reg cpu_sel = 0, cpu_rw = 1; reg [7:0] cpu_din = 0;
  wire [7:0] cpu_dout; wire irq, drq, led, step, ready;
  wire [31:0] sd_lba; wire [1:0] sd_rd, sd_wr; reg sd_ack = 0;
  reg [8:0] sd_buff_addr = 0; reg [7:0] sd_dout = 0; reg sd_dout_strobe = 0; wire [7:0] sd_din;

  fdc1772 dut(.clksys(clk), .clkcpu(clk), .clk8m_en(en),
    .floppy_drive(floppy_drive), .floppy_side(1'b1), .floppy_reset(floppy_reset),
    .floppy_step(step), .floppy_motor(1'b1), .floppy_ready(ready),
    .irq(irq), .drq(drq), .cpu_addr(cpu_addr), .cpu_sel(cpu_sel), .cpu_rw(cpu_rw),
    .cpu_din(cpu_din), .cpu_dout(cpu_dout),
    .img_mounted(img_mounted), .img_wp(img_wp), .img_size(img_size),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_dout(sd_dout), .sd_din(sd_din),
    .sd_dout_strobe(sd_dout_strobe), .drive_led(led));

  // ---- SD card model: answers reads with a pattern derived from the LBA ----
  integer sdreads = 0, sdwrites = 0;
  always @(posedge clk) if ((|sd_rd || |sd_wr) && !sd_ack) begin : sdm
    integer i; reg isrd;
    isrd = |sd_rd;
    repeat (400) @(posedge clk);
    sd_ack <= 1;
    for (i = 0; i < 512; i = i + 1) begin
      @(posedge clk); sd_buff_addr <= i; sd_dout <= (sd_lba[7:0] * 8'd7) ^ i[7:0] ^ {7'd0, i[8]};
      sd_dout_strobe <= isrd;
      @(posedge clk); sd_dout_strobe <= 0;
    end
    @(posedge clk); sd_ack <= 0;
    if (isrd) sdreads = sdreads + 1; else sdwrites = sdwrites + 1;
  end

  // ---- 6502 bus cycles (2 MHz: 4 cpu clocks with select high) ----
  task wr(input [1:0] a, input [7:0] d);
    begin @(posedge clk); cpu_addr <= a; cpu_din <= d; cpu_rw <= 0; cpu_sel <= 1;
      repeat (4) @(posedge clk); cpu_sel <= 0; cpu_rw <= 1; repeat (4) @(posedge clk); end
  endtask
  task rd(input [1:0] a, output [7:0] d);
    begin @(posedge clk); cpu_addr <= a; cpu_rw <= 1; cpu_sel <= 1;
      repeat (3) @(posedge clk); d = cpu_dout; @(posedge clk); cpu_sel <= 0; repeat (4) @(posedge clk); end
  endtask
  task us(input integer n); repeat (n*8) @(posedge clk); endtask

  // ---- NMI: falling edge of NMI = rising edge of (irq | drq) ----
  reg nmi_d = 0, nmi_pend = 0;
  always @(posedge clk) begin nmi_d <= irq | drq; if ((irq | drq) && !nmi_d) nmi_pend <= 1; end

  // NMI handler behaviour
  integer mode;           // 0 = service every byte, 1 = ignore DRQ, 2 = skip one byte
  integer skip_at;
  integer nbytes, nreads; reg [7:0] rbuf [0:511];
  reg [7:0] nmi_st, done_st; reg nmi_done;
  task service;
    reg [7:0] st, d;
    begin
      if (nmi_pend) begin
        nmi_pend = 0;
        us(4);                                   // NMI entry + PHA
        rd(0, st); nmi_st = st;
        if ((st & 8'h5F) == 8'h03) begin
          if (mode == 3) begin rd(3, d); rbuf[nreads] = d; nreads = nreads + 1; end
          else if (mode == 1) ;                  // ignore
          else if (mode == 2 && nbytes == skip_at) nbytes = nbytes + 1;
          else begin wr(3, nbytes[7:0]); nbytes = nbytes + 1; end
        end else begin
          done_st = st & 8'hFC; nmi_done = 1;
        end
      end
    end
  endtask

  // foreground: issue a command the way &8E55/&8E9F does and wait for it
  real t0, t1; reg [7:0] st; integer guard;
  task command(input [7:0] c, input integer poll);
    begin
      nbytes = 0; nreads = 0; nmi_done = 0;
      wr(0, c); t0 = $realtime;
      if (poll) begin
        guard = 0; st = 0;
        while (!st[0] && guard < 20000) begin service; rd(0, st); guard = guard + 1; end
        if (!st[0]) $display("   (busy never seen)");
        guard = 0;
        while (st[0] && guard < 2000000) begin service; rd(0, st); guard = guard + 1; end
        repeat (40) service;   // let the completion NMI run
      end else begin
        guard = 0;
        while (!nmi_done && guard < 3000000) begin service; us(1); guard = guard + 1; end
        rd(0, st);
      end
      t1 = $realtime;
    end
  endtask

  integer errors = 0;
  task check(input cond, input [8*64-1:0] msg);
    begin if (cond) $display("   ok   %0s", msg); else begin $display("   FAIL %0s", msg); errors = errors + 1; end end
  endtask

  integer i, drqs_after; reg ok; reg [7:0] exp;
  initial begin
    mode = 0; skip_at = -1;
    repeat (20) @(posedge clk); floppy_reset = 1;
    img_size = 204800; img_mounted = 2'b01; repeat (4) @(posedge clk); img_mounted = 0;
    floppy_drive = 2'b10;                       // drive 0

    $display("Restore (spin-up)");
    command(8'h00, 0);
    check(!st[0] && st[2], "restore done, track 0");
    check(led, "drive LED lit while the motor runs");

    $display("A: write track, DFS-style service of every byte");
    mode = 0; command(8'hF0, 1);
    $display("   bytes=%0d  time=%0.1f ms  status=%02x", nbytes, (t1-t0)/1e6, st);
    check((st & 8'h5C) == 0, "no lost data / errors (status & &5C == 0)");
    check(nbytes >= 3125 && nbytes <= 3128, "one track of FM bytes (3125 + first byte)");
    check((t1-t0) > 200e6 && (t1-t0) < 420e6, "takes between one and two revolutions");
    check(!drq, "DRQ clear afterwards");

    $display("B: write track, DRQ never serviced");
    mode = 1; command(8'hF0, 1);
    $display("   time=%0.3f ms  status=%02x", (t1-t0)/1e6, st);
    check(st[2], "lost data set");
    check((t1-t0) < 2e6, "terminates after ~3 byte times");
    check(!drq, "DRQ clear afterwards");

    $display("C: write track, one byte missed in the middle");
    mode = 2; skip_at = 1000; command(8'hF0, 1);
    $display("   bytes=%0d  time=%0.1f ms  status=%02x", nbytes, (t1-t0)/1e6, st);
    check(st[2], "lost data set");
    check((t1-t0) > 200e6, "still runs to the next index");
    mode = 0; skip_at = -1;

    $display("D: force interrupt during write track");
    nbytes = 0; nmi_done = 0;
    wr(0, 8'hF0);
    for (i = 0; i < 20000; i = i + 1) begin service; us(4); end   // ~80+ ms
    wr(0, 8'hD0); us(20); rd(0, st);
    check(!st[0], "not busy after &D0");
    drqs_after = 0; nmi_pend = 0;
    for (i = 0; i < 2000; i = i + 1) begin if (drq) drqs_after = drqs_after + 1; us(1); end
    check(drqs_after == 0, "no DRQ after force interrupt");

    $display("E: read sector still works (track 0 sector 3)");
    mode = 3; wr(2, 8'h03); command(8'h80, 0);
    ok = 1;
    for (i = 0; i < 256; i = i + 1) begin
      exp = (8'd1 * 8'd7) ^ i[7:0] ^ 8'd1;      // sector 3 = upper half of LBA 1
      if (rbuf[i] !== exp) ok = 0;
    end
    $display("   reads=%0d status=%02x", nreads, done_st);
    check(nreads == 256 && ok && (done_st & 8'h5C) == 0, "256 correct bytes, no errors");
    mode = 0;

    $display("F: write protected image");
    img_wp = 2'b01; command(8'hF0, 1);
    $display("   time=%0.3f ms  status=%02x", (t1-t0)/1e6, st);
    check(st[6], "write protect reported");
    check(!st[0], "not busy afterwards");
    check(nbytes <= 1, "no data requested");
    img_wp = 0;

    $display("G: LED goes out after the motor times out");
    us(2500000);
    check(!led, "drive LED off after 10 idle revolutions");

    $display("sd reads=%0d writes=%0d", sdreads, sdwrites);
    if (errors) $display("*** %0d FAILURES ***", errors); else $display("ALL PASSED");
    $finish;
  end
endmodule
