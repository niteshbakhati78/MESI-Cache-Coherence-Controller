# create_project.tcl
# Creates a Vivado project for the MESI Cache Coherence Controller.
# Usage (Vivado Tcl console or batch mode):
#   vivado -mode batch -source scripts/create_project.tcl
# Or from Vivado GUI Tcl console:
#   source scripts/create_project.tcl

# ── Project settings ──────────────────────────────────────────────────────
set proj_name  "mesi_cache_coherence"
set proj_dir   "[file dirname [file dirname [info script]]]"
set part       "xc7a35tcpg236-1"   ;# Artix-7 35T (Basys3 / Arty A7-35)

# ── Create project ────────────────────────────────────────────────────────
create_project $proj_name $proj_dir/$proj_name -part $part -force

# ── Add RTL source files ──────────────────────────────────────────────────
set rtl_files [list \
  $proj_dir/rtl/mesi_pkg.sv           \
  $proj_dir/rtl/mesi_fsm.sv           \
  $proj_dir/rtl/l1_cache_controller.sv \
  $proj_dir/rtl/bus_arbiter.sv        \
  $proj_dir/rtl/l2_cache.sv           \
  $proj_dir/rtl/coherence_system.sv   \
  $proj_dir/rtl/cdc_sync.sv           \
]
add_files -fileset [get_filesets sources_1] $rtl_files

# ── Set package as a global include (SystemVerilog package) ───────────────
set_property file_type {SystemVerilog} [get_files mesi_pkg.sv]

# ── Set top-level module ──────────────────────────────────────────────────
set_property top coherence_system [get_filesets sources_1]

# ── Add simulation files ──────────────────────────────────────────────────
set tb_files [list \
  $proj_dir/tb/tb_mesi_fsm.sv         \
  $proj_dir/tb/tb_l1_cache.sv         \
  $proj_dir/tb/tb_coherence_system.sv \
  $proj_dir/tb/tb_bus_arbiter.sv      \
]
add_files -fileset [get_filesets sim_1] $tb_files

# Add SVA and coverage files to simulation fileset
set sva_files [list \
  $proj_dir/assertions/mesi_sva.sv    \
  $proj_dir/assertions/bus_sva.sv     \
  $proj_dir/assertions/coverage.sv    \
]
add_files -fileset [get_filesets sim_1] $sva_files

# ── Set simulation top (default: coherence system TB) ─────────────────────
set_property top tb_coherence_system [get_filesets sim_1]
set_property top_lib xil_defaultlib  [get_filesets sim_1]

# ── Add constraints ───────────────────────────────────────────────────────
add_files -fileset [get_filesets constrs_1] $proj_dir/constraints/artix7.xdc

# ── Simulation settings ───────────────────────────────────────────────────
# Enable SystemVerilog assertions in xsim
set_property -name {xsim.simulate.xsim.more_options} \
             -value {-assert -sv_seed 1} \
             -objects [get_filesets sim_1]

# Set simulation runtime (enough for all tests)
set_property -name {xsim.simulate.runtime} \
             -value {1ms} \
             -objects [get_filesets sim_1]

# ── Synthesis settings ────────────────────────────────────────────────────
set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]

# ── Done ──────────────────────────────────────────────────────────────────
puts ""
puts "=== Project created: $proj_name ==="
puts "RTL files:  [llength $rtl_files] files"
puts "TB files:   [llength $tb_files] files"
puts "SVA files:  [llength $sva_files] files"
puts ""
puts "Next steps:"
puts "  1. Elaborate:  Flow Navigator → RTL Analysis → Open Elaborated Design"
puts "  2. Simulate:   Flow Navigator → Simulation → Run Simulation"
puts "  3. Synthesize: Flow Navigator → Synthesis → Run Synthesis"
puts ""
puts "Or run batch simulation:  vivado -mode batch -source scripts/run_sim.tcl"
puts "Or run batch synthesis:   vivado -mode batch -source scripts/run_synth.tcl"
