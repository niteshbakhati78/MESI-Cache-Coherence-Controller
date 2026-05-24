# run_synth.tcl
# Batch synthesis + implementation script.
# Produces synth_report.txt and timing_report.txt in synth/.
#
# Usage:
#   vivado -mode batch -source scripts/run_synth.tcl

# ── Configuration ─────────────────────────────────────────────────────────
set proj_dir  [file dirname [file dirname [info script]]]
set proj_name "mesi_cache_coherence"
set synth_out "$proj_dir/synth"

# ── Open (or create) project ──────────────────────────────────────────────
set proj_file "$proj_dir/$proj_name/$proj_name.xpr"
if {[file exists $proj_file]} {
  open_project $proj_file
} else {
  puts "Project not found. Creating..."
  source $proj_dir/scripts/create_project.tcl
}

# ── Set synthesis top ─────────────────────────────────────────────────────
set_property top coherence_system [get_filesets sources_1]

# ── Run synthesis ─────────────────────────────────────────────────────────
puts "=== Running synthesis ==="
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  puts "ERROR: Synthesis failed!"
  exit 1
}

# ── Generate synthesis reports ────────────────────────────────────────────
file mkdir $synth_out
open_run synth_1 -name netlist_1

report_utilization   -file "$synth_out/synth_report.txt"
report_timing_summary -file "$synth_out/timing_report.txt" -max_paths 10
report_clock_utilization -file "$synth_out/clock_report.txt"

puts "=== Synthesis complete ==="
puts "Utilization report: $synth_out/synth_report.txt"
puts "Timing report:      $synth_out/timing_report.txt"

# ── Optional: Run implementation for accurate post-route timing ───────────
puts "=== Running implementation (post-route timing) ==="
launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] == "100%"} {
  open_run impl_1
  report_timing_summary -file "$synth_out/timing_report_impl.txt" \
                        -max_paths 10 -report_unconstrained
  puts "Post-implementation timing: $synth_out/timing_report_impl.txt"
} else {
  puts "WARNING: Implementation did not complete"
}

# ── Print key metrics to console ──────────────────────────────────────────
puts ""
puts "=== KEY METRICS (read from reports) ==="
puts "Open $synth_out/synth_report.txt  → find 'Slice LUTs' and 'Slice Registers'"
puts "Open $synth_out/timing_report.txt → find 'WNS' and 'TNS' for timing closure"
puts ""
puts "Fmax = 1000 / (clock_period_ns - WNS_ns)"
puts "Example: period=10ns, WNS=+1.5ns → Fmax = 1000/(10-1.5) = 117.6 MHz"
puts ""
puts "Record these numbers in verif/results/results.md"
