# Drive sounds testbench

`tb_drive_sound.v` tests `rtl/drive_sound.v` through `rtl/tape/tape_store.v` and
`tape_ddr.v` with a DDR3 model (random BUSY and read latency). It downloads
`sounds.rom`, then raises each trigger and checks the mixed output sample by sample
against the raw samples:

- a non-sounds file is rejected; no sound without a file
- a tape image still downloads and reads back alongside the sounds
- motor on (motor loop + head load), motor off (head unload)
- 8271: one-track step, five-track seek (loop length 5 x 24.15 ms)
- 1770: a lone step pulse, and a run of steps (seek loop until 35 ms after the last)
- Low / Medium / Loud levels, Off silencing a running motor
- cassette relay clicks only when enabled

Run (OSS CVC; takes several minutes):

    python ../../scripts/make_sounds_rom.py "C:/Program Files (x86)/BeebEm" sounds.rom
    python mkhex.py sounds.rom
    cvc64 tb_drive_sound.v ../../rtl/drive_sound.v ../../rtl/tape/tape_store.v ../../rtl/tape/tape_ddr.v ../../rtl/tape/inflate.v
    ./cvcsim

The testbench clock is 7.056 MHz (160 clocks per 44.1 kHz sample) to shorten the
run; all of drive_sound's timings scale with CLK_HZ.
