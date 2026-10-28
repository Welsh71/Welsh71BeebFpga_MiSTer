`timescale 1ns/1ps
module tb;
  reg clk=0; always #5.2 clk=~clk;
  // 16MHz pixels: ce_pix high 2 of every 6 clk_sys (as from the clk_48 domain)
  reg [2:0] ph=0; always @(posedge clk) ph <= (ph==5)?0:ph+1;
  wire ce = (ph<2);
  integer hc=0, vc=0;
  reg hb=1, vb=1;
  integer HT, HA, VT, VA;
  reg [23:0] info;
  reg [1:0] mode;
  wire [3:0] r,g,b;
  disk_osd dut(.clk(clk),.ce_pix(ce),.hblank_in(hb),.vblank_in(vb),.mode(mode),.info(info),
               .r_in(4'h3),.g_in(4'h3),.b_in(4'h3),.r_out(r),.g_out(g),.b_out(b));
  // advance the raster on the rising edge of ce (like the core)
  reg ce_d=0;
  always @(posedge clk) begin
    ce_d <= ce;
    if (ce && !ce_d) begin
      hc = hc + 1; if (hc == HT) begin hc = 0; vc = vc + 1; if (vc == VT) vc = 0; end
      hb <= !(hc >= 100 && hc < 100+HA);
      vb <= !(vc >= 20 && vc < 20+VA);
    end
  end
  // capture what the mixer would see: the second clk of ce high
  reg [7:0] scr [0:300][0:700];
  integer px, py, frames=0;
  reg vb_d=1;
  always @(posedge clk) if (ce && ce_d) begin
    if (!hb && !vb) begin
      px = hc-100-1; py = vc-20;
      if (px>=0 && px<700 && py>=0 && py<300) scr[py][px] = (r==4'hF) ? "#" : (r==4'h0 ? "." : " ");
    end
    vb_d <= vb; if (vb && !vb_d) frames = frames + 1;
  end
  task show(input integer x0, input integer y0, input integer w, input integer h);
    integer i,j; reg [8*400:1] line;
    begin
      for (j=y0;j<y0+h;j=j+1) begin
        $write("%3d ",j);
        for (i=x0;i<x0+w;i=i+1) $write("%s", scr[j][i]);
        $write("\n");
      end
    end
  endtask
  task run(input integer n); begin : rn integer f0; f0=frames; while (frames < f0+n) @(posedge clk); end endtask
  integer i,j;
  initial begin
    HT=1024; HA=640; VT=312; VA=256;
    // drive 0 side 1 (floppy_side=0) -> DFS drive 2, track 27, sector 5, cmd F (format), busy, led, any
    info = {1'b1,1'b1,1'b1,1'b0,1'b0,4'hF,7'd27,8'd5};
    mode = 2;
    for (j=0;j<300;j=j+1) for (i=0;i<700;i=i+1) scr[j][i]=" ";
    run(4);
    $display("mode 2, motor on, format: bottom-right of a 640x256 picture");
    show(280, 230, 360, 26);
    // read sector, drive 1 side 0, motor off -> with mode 2 box must disappear
    info = {1'b1,1'b0,1'b1,1'b1,1'b1,4'h8,7'd79,8'd9};
    for (j=0;j<300;j=j+1) for (i=0;i<700;i=i+1) scr[j][i]=" ";
    run(3);
    $display("mode 2, motor off (no box expected, '.' or '#' would be overlay)");
    show(280, 236, 360, 14);
    mode = 1;
    for (j=0;j<300;j=j+1) for (i=0;i<700;i=i+1) scr[j][i]=" ";
    run(3);
    $display("mode 1 (always on), motor off -> IDLE, drive 1 track 79 sector 09");
    show(280, 236, 360, 14);
    // mode 7 sized picture (480 wide), read sector busy
    HA=480; info = {1'b1,1'b1,1'b1,1'b0,1'b1,4'h8,7'd3,8'd0};
    for (j=0;j<300;j=j+1) for (i=0;i<700;i=i+1) scr[j][i]=" ";
    run(4);
    $display("480 wide (mode 7), read, drive 0 track 03 sector 00");
    show(120, 236, 364, 14);
    $finish;
  end
endmodule
