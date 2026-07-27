// UVM top-level module for mesi_fsm.
// Instantiates DUT + interface, registers the virtual interface in config_db,
// then hands control to UVM via run_test().
// Select test at runtime with: +UVM_TESTNAME=mesi_random_test
//                          or: +UVM_TESTNAME=mesi_directed_test
`timescale 1ns/1ps
`include "uvm_macros.svh"

import uvm_pkg::*;
import mesi_uvm_pkg::*;

module tb_top;

  logic clk;
  logic rst_n;

  // 10 ns / 100 MHz clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Reset: assert for 5 cycles, then release
  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  end

  // Interface
  mesi_if dut_if (.clk(clk), .rst_n(rst_n));

  // DUT
  mesi_fsm #(.ONE_HOT(1'b0)) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .cpu_rd     (dut_if.cpu_rd),
    .cpu_wr     (dut_if.cpu_wr),
    .cpu_hit    (dut_if.cpu_hit),
    .snoop_valid(dut_if.snoop_valid),
    .snoop_op   (dut_if.snoop_op),
    .shared_seen(dut_if.shared_seen),
    .state_q    (dut_if.state_q),
    .bus_req    (dut_if.bus_req),
    .bus_op     (dut_if.bus_op),
    .wb_en      (dut_if.wb_en)
  );

  // Push virtual interface into config_db and start UVM
  initial begin
    uvm_config_db #(mesi_vif)::set(null, "uvm_test_top.*", "vif", dut_if);
    run_test();
  end

  // Optional: waveform dump for EDA Playground / Questasim
  initial begin
    $dumpfile("mesi_uvm.vcd");
    $dumpvars(0, tb_top);
  end

endmodule
