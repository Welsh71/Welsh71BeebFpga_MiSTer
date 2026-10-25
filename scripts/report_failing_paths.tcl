# Re-run timing analysis on the last compile and write the failing paths to text files.
# Run from the project folder:  quartus_sta -t scripts/report_failing_paths.tcl
# (or double-click scripts\report_failing_paths.bat). No recompile needed.

project_open BBCMicro -revision BBCMicro
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set out output_files

# One line per failing path (worst first): slack, from, to
report_timing -setup -to_clock $clk -npaths 2000 -less_than_slack 0 -detail summary \
    -file $out/fail_setup_summary.txt
# Unique endpoint registers only
report_timing -setup -to_clock $clk -npaths 2000 -less_than_slack 0 -detail summary -pairs_only \
    -file $out/fail_setup_pairs.txt
# Full path detail (every cell and net) for the 15 worst
report_timing -setup -to_clock $clk -npaths 15 -detail full_path \
    -file $out/fail_setup_worst15.txt
# Hold violations
report_timing -hold -to_clock $clk -npaths 50 -less_than_slack 0 -detail full_path \
    -file $out/fail_hold.txt
# Exceptions as actually applied (checks the multicycle constraints)
report_exceptions -file $out/exceptions.txt

delete_timing_netlist
project_close
puts "Done - see output_files/fail_*.txt"
