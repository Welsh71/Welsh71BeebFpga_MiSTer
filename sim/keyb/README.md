# Keyboard and mouse event capture

`hps_io` changes `ps2_key` / `ps2_mouse` (data and event toggle together) in clk_sys,
while `misterkeyboard` and `quadrature_controller` run on the gated clk_48, whose clock
arrives ~6.7 ns late. In hardware any bit can therefore be captured a clock earlier or
later than the others. Both modules capture the whole word first and detect the toggle
two clocks later, so every ordering decodes correctly.

The testbenches send each event with the toggle and data arriving together, toggle a
clock early, data a clock early, mid-cycle, and split across an edge:

- `tb_keyb.vhd`: press and release of nine keys in every ordering, plus two events four
  clocks apart; checks the key matrix, and that no other key changes (93 checks).
- `tb_mouse.vhd`: buttons, and X/Y quadrature edge counts and phase for each sign.

With the original code (toggle compared live) both fail: stuck or wrong keys, stale
buttons and reversed movement.

Run (GHDL 4.x):

    ghdl -a --std=08 ../../rtl/mister_keyboard.vhd tb_keyb.vhd
    ghdl -e --std=08 tb_keyb && ghdl -r --std=08 tb_keyb

    ghdl -a --std=08 -fsynopsys ../../rtl/mouse/quadrature_fsm.vhd ../../rtl/mouse/mister_quadrature_controller.vhd tb_mouse.vhd
    ghdl -e --std=08 -fsynopsys tb_mouse && ghdl -r --std=08 -fsynopsys tb_mouse
