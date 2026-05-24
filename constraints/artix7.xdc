# artix7.xdc — Timing constraints for Xilinx Artix-7 (xc7a35t)
# Target: 50 MHz clock (20 ns period)

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

