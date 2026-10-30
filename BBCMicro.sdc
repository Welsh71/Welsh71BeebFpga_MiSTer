derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
set_multicycle_path -to {emu|BBCMicro|*} -setup 2
set_multicycle_path -to {emu|BBCMicro|*} -hold 1

set_multicycle_path -to {emu|mixer|*} -setup 2
set_multicycle_path -to {emu|mixer|*} -hold 1

# ext_A/ext_Din are launched on the gated clk_48 (~6.6ns late vs clk_sys) and held
# stable for a whole 12 clk_sys memory slot before the pipeline registers below are
# used, so two clk_sys cycles is the true requirement. ext_nWE -> ram_we_r is NOT
# relaxed and keeps its single-cycle check.
set_multicycle_path -from {emu|BBCMicro|ext_A* emu|BBCMicro|ext_Din*} -to {emu|ram_raddr_r* emu|ram_waddr_r* emu|ram_wdata_r* emu|rom_addr_r*} -setup 2
set_multicycle_path -from {emu|BBCMicro|ext_A* emu|BBCMicro|ext_Din*} -to {emu|ram_raddr_r* emu|ram_waddr_r* emu|ram_wdata_r* emu|rom_addr_r*} -hold 1

# Tape: single-bit asynchronous signals into two-flop synchronisers
# (tape signal clk_sys -> gated clk_48 ULA; cassette motor clk_48 -> clk_sys player)
set_false_path -to [get_keepers {*|serial_ula_inst|sync[0]}]
set_false_path -to [get_keepers {*|tape_player|motor_s[0]}]

# The RAM/ROM outputs (clk_sys) are only sampled into the CPU, video and tube data
# latches (gated clk_48, ~5-6ns late) at fixed slot times, at least two clk_48 cycles
# after the memory address last changed, so the data cannot change near the
# latching edge. TimeQuest assumes it can and flags hold violations that depend on
# placement; remove the hold check on exactly these paths (setup is still checked).
set_false_path -hold -from [get_keepers {emu|*_rtl_*|*}] -to [get_keepers {emu|BBCMicro|vid_mem_data* emu|BBCMicro|cpu_mem_data* emu|BBCMicro|tube_mem_data*}]

# m128 (Model B / Master) only changes while the core is held in reset (reset_req),
# so it is static whenever the core is running.
set_false_path -from [get_keepers {emu|m128}]

# Floppy LBA (set in the gated clk_48 domain) is stable long before the HPS reads it
# through hps_io, and stays put until the transfer is acknowledged.
set_multicycle_path -from [get_keepers {emu|sd_lba*}] -to [get_keepers {emu|hps_io|*}] -setup 2
set_multicycle_path -from [get_keepers {emu|sd_lba*}] -to [get_keepers {emu|hps_io|*}] -hold 1

# VGA_F1 is built from clk_48-domain flags that change once per field.
set_multicycle_path -to [get_keepers {emu|vga_f1_r}] -setup 2
set_multicycle_path -to [get_keepers {emu|vga_f1_r}] -hold 1

# Floppy controller status (gated clk_48) read by hps_io: slow-changing, held while read.
set_multicycle_path -from [get_keepers {emu|BBCMicro|fdc|*}] -to [get_keepers {emu|hps_io|*}] -setup 2
set_multicycle_path -from [get_keepers {emu|BBCMicro|fdc|*}] -to [get_keepers {emu|hps_io|*}] -hold 1

# MMFS SPI lines: the user VIA port B (gated clk_48) only changes once per 1MHz
# CPU cycle, then is re-registered into clk_sys (sdclk_r/sdmosi_r/sdss_r).
set_multicycle_path -to [get_keepers {emu|sdclk_r emu|sdmosi_r emu|sdss_r}] -setup 2
set_multicycle_path -to [get_keepers {emu|sdclk_r emu|sdmosi_r emu|sdss_r}] -hold 1

# On-screen disk status: floppy state (gated clk_48) is latched once per frame,
# display only.
set_false_path -to [get_keepers {emu|disk_osd|inf[*] emu|disk_osd|led}]
# Blanking into disk_osd comes from the gated clk_48 (ticks every other clk_sys edge).
set_multicycle_path -to [get_keepers {emu|disk_osd|hblank emu|disk_osd|vblank}] -setup 2
set_multicycle_path -to [get_keepers {emu|disk_osd|hblank emu|disk_osd|vblank}] -hold 1

# Keyboard and mouse: hps_io's ps2_key/ps2_mouse (clk_sys) are captured on the gated
# clk_48, whose clock arrives late enough that a bit may be caught a clock early. The
# event is detected two clocks after the capture, so that is harmless (see
# mister_keyboard.vhd, sim/keyb). Only the hold check is removed: setup stays bounded
# by the two-cycle rule on emu|BBCMicro|* above.
set_false_path -hold -to [get_keepers {emu|BBCMicro|keyb|key_s[*]}]
set_false_path -hold -to [get_keepers {emu|BBCMicro|mouse_controller|ms_s[*]}]
# inf is static for a whole frame; the track/sector digits (/10, %10) and the command
# decode that follow it may take several clocks.
set_multicycle_path -from [get_keepers {emu|disk_osd|inf[*]}] -setup 4
set_multicycle_path -from [get_keepers {emu|disk_osd|inf[*]}] -hold 3

# Core audio (SN76489/Music 5000, gated clk_48) captured in clk_sys before the
# drive/tape sound mix. clk_48 ticks on every other clk_sys edge.
# (core_?_q* also matches the copies Quartus makes when it retimes them, e.g. _OTERM)
set_multicycle_path -to [get_keepers {emu|core_l_q* emu|core_r_q*}] -setup 2
set_multicycle_path -to [get_keepers {emu|core_l_q* emu|core_r_q*}] -hold 1

# ROM read address: rom_addr_r follows ext_A (gated clk_48), so it changes at most on
# every other clk_sys edge, and the data is latched at the end of a 12-clk memory slot.
set_multicycle_path -from [get_keepers {emu|rom_addr_r*}] -setup 2
set_multicycle_path -from [get_keepers {emu|rom_addr_r*}] -hold 1
