// DUT interface for mesi_fsm.
// Clocking blocks enforce setup/hold discipline:
//   drv_cb  — driver writes inputs 1 ns after posedge
//   mon_cb  — monitor samples 1 ns before posedge (captures values driven the previous cycle)
`timescale 1ns/1ps

interface mesi_if (input logic clk, rst_n);
  // Stimulus signals (driven by driver)
  logic        cpu_rd;
  logic        cpu_wr;
  logic        cpu_hit;
  logic        snoop_valid;
  logic [1:0]  snoop_op;
  logic        shared_seen;

  // Response signals (observed by monitor)
  logic [1:0]  state_q;
  logic        bus_req;
  logic [1:0]  bus_op;
  logic        wb_en;

  clocking drv_cb @(posedge clk);
    default input #1 output #1;
    output cpu_rd, cpu_wr, cpu_hit, snoop_valid, snoop_op, shared_seen;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1;
    input cpu_rd, cpu_wr, cpu_hit, snoop_valid, snoop_op, shared_seen;
    input state_q, bus_req, bus_op, wb_en;
  endclocking

  modport drv_mp (clocking drv_cb, input clk, rst_n);
  modport mon_mp (clocking mon_cb, input clk, rst_n);
endinterface
