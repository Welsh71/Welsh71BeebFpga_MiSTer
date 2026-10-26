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
