// ─── Compile filelist ──────────────────────────────────────────────────────────
// Usage (Questa):
//   vlog -sv -f uvm_tb/run.f
//   vsim -c -do "run -all; quit -f" tb_top +UVM_TESTNAME=mesi_directed_test
//
// Usage (Xcelium):
//   xrun -sv -uvm -f uvm_tb/run.f -top tb_top +UVM_TESTNAME=mesi_random_test
//
// Usage (EDA Playground – Riviera-PRO):
//   Paste files in the order below; set top to tb_top; UVM lib is pre-loaded.
// ─────────────────────────────────────────────────────────────────────────────

// UVM library (Questa needs an explicit path; Riviera/Xcelium auto-include it)
// +incdir+$UVM_HOME/src
// $UVM_HOME/src/uvm_pkg.sv

// RTL
../rtl/mesi_fsm.sv

// Testbench
uvm_tb/mesi_if.sv
uvm_tb/mesi_uvm_pkg.sv
uvm_tb/tb_top.sv
