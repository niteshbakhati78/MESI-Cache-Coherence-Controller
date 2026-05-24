# artix7.xdc — Timing constraints for Xilinx Artix-7 (xc7a35t)
# Target: 50 MHz clock (20 ns period)
# Use these constraints for synthesis and implementation in Vivado.

# ── Primary clock ─────────────────────────────────────────────────────────
# Constrain the top-level clock port of coherence_system.
create_clock -period 20.000 -name clk -waveform {0.000 10.000} [get_ports clk]

# ── Input delays ──────────────────────────────────────────────────────────
# Allow 2 ns input setup margin (signals arrive 2 ns after clock edge).
set_input_delay -clock clk -max 2.000 [all_inputs]
set_input_delay -clock clk -min 0.500 [all_inputs]

# ── Output delays ─────────────────────────────────────────────────────────
# Outputs must settle 2 ns before next clock edge.
set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.500 [all_outputs]

# ── False path on reset ───────────────────────────────────────────────────
# Synchronous active-low reset; not timing-critical from a source perspective.
set_false_path -from [get_ports rst_n]

# ── Clock uncertainty ─────────────────────────────────────────────────────
# Model 200 ps jitter (typical for Artix-7 MMCM output).
set_clock_uncertainty -setup 0.200 [get_clocks clk]
set_clock_uncertainty -hold  0.100 [get_clocks clk]

# ── Target device / package ───────────────────────────────────────────────
# Artix-7 35T — CPG236 package (used on Basys3/Arty boards)
# Uncomment if targeting a board with a specific part:
# set_property PART xc7a35tcpg236-1 [current_project]

# ── Notes ─────────────────────────────────────────────────────────────────
# If synthesis fails timing at 100 MHz:
#   - Try 12 ns (83 MHz): change -period to 12.000
#   - Try 15 ns (67 MHz): change -period to 15.000
# A clean passing report at a lower frequency is preferable to a failing
# report at 100 MHz for a resume/portfolio project.
#
# After implementation, read WNS from:
#   Reports → Timing Summary → Setup → Worst Negative Slack
# Achieved Fmax = 1000 / (clock_period_ns - WNS_ns)  [in MHz]
