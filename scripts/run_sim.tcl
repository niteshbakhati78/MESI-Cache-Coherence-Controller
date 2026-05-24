# run_sim.tcl
# Batch simulation script for MESI Cache Coherence Controller.
# Compiles all RTL + TB, runs xsim, and reports pass/fail.
#
# Usage:
#   vivado -mode batch -source scripts/run_sim.tcl
#   vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_l1_cache
#   vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_coherence_system
#   vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_mesi_fsm

# ── Configuration ─────────────────────────────────────────────────────────
set proj_dir  [file dirname [file dirname [info script]]]
set proj_name "mesi_cache_coherence"
set part      "xc7a35tcpg236-1"
set work_lib  "xil_defaultlib"

# Default top: tb_coherence_system (system test)
set top_tb "tb_coherence_system"
if {[llength $argv] > 0} {
  set top_tb [lindex $argv 0]
}
puts "=== Running simulation: $top_tb ==="

# ── Open (or create) project ──────────────────────────────────────────────
set proj_file "$proj_dir/$proj_name/$proj_name.xpr"
if {[file exists $proj_file]} {
  open_project $proj_file
} else {
  puts "Project not found. Creating..."
  source $proj_dir/scripts/create_project.tcl
}

# ── Set simulation top ────────────────────────────────────────────────────
set_property top $top_tb [get_filesets sim_1]
set_property top_lib $work_lib [get_filesets sim_1]

# ── Enable assertions ─────────────────────────────────────────────────────
set_property -name {xsim.simulate.xsim.more_options} \
             -value {-assert -sv_seed 1 -log simulation.log} \
             -objects [get_filesets sim_1]

# Set runtime
set_property -name {xsim.simulate.runtime} \
             -value {1ms} \
             -objects [get_filesets sim_1]

# ── Dump waveforms (optional — uncomment to generate VCD) ─────────────────
# set_property -name {xsim.simulate.log_all_signals} -value {true} \
#              -objects [get_filesets sim_1]

# ── Run simulation ────────────────────────────────────────────────────────
launch_simulation

# ── Wait for completion and check for failures ────────────────────────────
run all
close_sim

puts ""
puts "=== Simulation complete: $top_tb ==="
puts "Check the Tcl console output above for PASS/FAIL messages."
puts "Waveform database saved in $proj_name/$proj_name.sim/"
