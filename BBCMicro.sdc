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
