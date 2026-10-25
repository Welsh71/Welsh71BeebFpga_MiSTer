# Tape interface testbench

`tb_tape.v` tests `rtl/tape/serial_ula.v` + `rtl/tape/acia6850.v` together:
BBC tape-format tones in, bytes out through a MOS-style interrupt handler.

1. 1200 baud, clean
2. 1200 baud, 40/60 duty, 8% jitter, tape 4% fast; 2b. tape 10% fast
3. 1200 baud, tape 5% slow
4. 300 baud (ACIA /64)
5. Transmit loopback (ACIA TX -> ULA tones -> ULA RX)
6. Register / master reset / FE10 read side effect

Run with any Verilog-2001 simulator, e.g. Icarus or Open Verilog CVC:

    iverilog -o tb tb_tape.v ../../rtl/tape/*.v && vvp tb
    cvc64 tb_tape.v ../../rtl/tape/*.v && ./cvcsim

Default clock is 16 MHz to run faster; the core's real 48 MHz settings:

    cvc64 +define+CLK_HZ=48000000 +define+BASE_DIV=39 tb_tape.v ../../rtl/tape/*.v

## UEF player end to end

`tb_uef.v` downloads tape images byte by byte (paced like `ioctl_wait`) into
`tape_ddr.v` over a DDR3 model with random BUSY and read latency, plays them
with `tape_player.v` into the Serial ULA and ACIA, and checks every byte:

- A. uncompressed UEF with chunks &0100 &0102 &0104 &0110 &0111 &0112 &0116,
  an info chunk and an unknown chunk (skipped)
- B. 300 baud (&0117)
- C. Main_MiSTer's pre-decoded bitstream (what Main sends the Electron core)
- D. gzipped UEF is refused, not played
- motor off stops the tape; E. rewind and replay

    python3 make_uef_tests.py        # writes img_*.hex / exp_*.hex
    cvc64 tb_uef.v ../../rtl/tape/*.v && ./cvcsim

## Decompressor

`tb_inflate.v` runs `inflate.v` through `tape_ddr.v` on 33 gzip files made by
`make_gz_tests.py` with Python's zlib (stored, fixed and dynamic Huffman,
Z_RLE / Z_HUFFMAN_ONLY / Z_FILTERED, gzip header options, matches up to the
32KB window, 150KB multi-block, empty file, 20 random fuzz files) and compares
the output byte for byte; a corrupt stream must end in an error, not a hang.

    python3 make_gz_tests.py
    cvc64 tb_inflate.v ../../rtl/tape/inflate.v ../../rtl/tape/tape_ddr.v && ./cvcsim

tb_uef.v test D plays a gzipped UEF end to end; test F checks a corrupt one
is refused.
