// coverage.sv
// Functional coverage groups for MESI protocol verification.
// Instantiate this module inside tb_coherence_system to collect coverage.
//
// Coverage targets:
//   - All 4 MESI states in both caches
//   - All MESI state transitions for each cache
//   - All bus operation types
//   - Key coherence scenarios

`timescale 1ns/1ps

module coverage #(
  parameter int NUM_SETS   = 16,
  parameter int NUM_WAYS   = 2
) (
  input  logic clk,
  input  logic rst_n,

  // MESI states for a sampled cache line (typically address 0)
  input  logic [1:0] l0_state_samp,  // current state of sampled line in L1_0
  input  logic [1:0] l1_state_samp,  // current state of sampled line in L1_1

  // Bus operations
  input  logic       bus_rd_valid,
  input  logic       bus_rdx_valid,
  input  logic       bus_upgr_valid,
  input  logic       bus_wb_valid,

  // Snoop events
  input  logic       snoop0_hit_ev,
  input  logic       snoop0_dirty_ev,
  input  logic       snoop1_hit_ev,
  input  logic       snoop1_dirty_ev,

  // CPU events
  input  logic       cpu0_hit_ev,
  input  logic       cpu0_miss_ev,
  input  logic       cpu1_hit_ev,
  input  logic       cpu1_miss_ev
);

  // MESI state constants
  localparam logic [1:0] ST_I = 2'd0;
  localparam logic [1:0] ST_S = 2'd1;
  localparam logic [1:0] ST_E = 2'd2;
  localparam logic [1:0] ST_M = 2'd3;

  // ── Previous state registers (for transition coverage) ───────────────
  logic [1:0] prev_l0_state, prev_l1_state;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      prev_l0_state <= ST_I;
      prev_l1_state <= ST_I;
    end else begin
      prev_l0_state <= l0_state_samp;
      prev_l1_state <= l1_state_samp;
    end
  end

  // ── Coverage Groups ──────────────────────────────────────────────────

  // All 4 MESI states in L1_0
  covergroup cg_l0_states @(posedge clk);
    option.name = "L1_0_MESI_States";
    cp_state: coverpoint l0_state_samp {
      bins invalid   = {ST_I};
      bins shared    = {ST_S};
      bins exclusive = {ST_E};
      bins modified  = {ST_M};
    }
  endgroup

  // All 4 MESI states in L1_1
  covergroup cg_l1_states @(posedge clk);
    option.name = "L1_1_MESI_States";
    cp_state: coverpoint l1_state_samp {
      bins invalid   = {ST_I};
      bins shared    = {ST_S};
      bins exclusive = {ST_E};
      bins modified  = {ST_M};
    }
  endgroup

  // MESI state transitions for L1_0
  covergroup cg_l0_transitions @(posedge clk);
    option.name = "L1_0_MESI_Transitions";
    cp_prev: coverpoint prev_l0_state {
      bins I = {ST_I}; bins S = {ST_S};
      bins E = {ST_E}; bins M = {ST_M};
    }
    cp_curr: coverpoint l0_state_samp {
      bins I = {ST_I}; bins S = {ST_S};
      bins E = {ST_E}; bins M = {ST_M};
    }
    cp_trans: cross cp_prev, cp_curr {
      // Valid MESI transitions
      bins I_to_E  = binsof(cp_prev.I) && binsof(cp_curr.E);
      bins I_to_S  = binsof(cp_prev.I) && binsof(cp_curr.S);
      bins I_to_M  = binsof(cp_prev.I) && binsof(cp_curr.M);
      bins E_to_M  = binsof(cp_prev.E) && binsof(cp_curr.M);
      bins E_to_S  = binsof(cp_prev.E) && binsof(cp_curr.S);
      bins E_to_I  = binsof(cp_prev.E) && binsof(cp_curr.I);
      bins S_to_M  = binsof(cp_prev.S) && binsof(cp_curr.M);
      bins S_to_I  = binsof(cp_prev.S) && binsof(cp_curr.I);
      bins M_to_S  = binsof(cp_prev.M) && binsof(cp_curr.S);
      bins M_to_I  = binsof(cp_prev.M) && binsof(cp_curr.I);
      bins M_stay  = binsof(cp_prev.M) && binsof(cp_curr.M);
      bins S_stay  = binsof(cp_prev.S) && binsof(cp_curr.S);
      bins E_stay  = binsof(cp_prev.E) && binsof(cp_curr.E);
      bins I_stay  = binsof(cp_prev.I) && binsof(cp_curr.I);
      // Illegal transitions (should never occur)
      illegal_bins S_to_E  = binsof(cp_prev.S) && binsof(cp_curr.E);
      illegal_bins M_to_E  = binsof(cp_prev.M) && binsof(cp_curr.E);
    }
  endgroup

  // Bus operation types
  covergroup cg_bus_ops @(posedge clk);
    option.name = "Bus_Operations";
    cp_busrd:   coverpoint bus_rd_valid   { bins active = {1}; }
    cp_busrdx:  coverpoint bus_rdx_valid  { bins active = {1}; }
    cp_busupgr: coverpoint bus_upgr_valid { bins active = {1}; }
    cp_buswb:   coverpoint bus_wb_valid   { bins active = {1}; }
  endgroup

  // Snoop events
  covergroup cg_snoop_events @(posedge clk);
    option.name = "Snoop_Events";
    cp_snp0_hit:   coverpoint snoop0_hit_ev   { bins hit = {1}; }
    cp_snp0_dirty: coverpoint snoop0_dirty_ev { bins dirty = {1}; }
    cp_snp1_hit:   coverpoint snoop1_hit_ev   { bins hit = {1}; }
    cp_snp1_dirty: coverpoint snoop1_dirty_ev { bins dirty = {1}; }
    // Dirty intervention: snoop hit AND dirty
    cp_dirty_int: cross cp_snp0_hit, cp_snp0_dirty;
  endgroup

  // Hit/miss ratios per core
  covergroup cg_hit_miss @(posedge clk);
    option.name = "Hit_Miss_Events";
    cp_c0_hit:  coverpoint cpu0_hit_ev  { bins hit = {1}; }
    cp_c0_miss: coverpoint cpu0_miss_ev { bins miss = {1}; }
    cp_c1_hit:  coverpoint cpu1_hit_ev  { bins hit = {1}; }
    cp_c1_miss: coverpoint cpu1_miss_ev { bins miss = {1}; }
  endgroup

  // Joint state of both L1s (for coherence invariant coverage)
  covergroup cg_joint_state @(posedge clk);
    option.name = "Joint_L0_L1_States";
    cp_l0: coverpoint l0_state_samp {
      bins I = {ST_I}; bins S = {ST_S};
      bins E = {ST_E}; bins M = {ST_M};
    }
    cp_l1: coverpoint l1_state_samp {
      bins I = {ST_I}; bins S = {ST_S};
      bins E = {ST_E}; bins M = {ST_M};
    }
    // All valid protocol state combinations
    cp_joint: cross cp_l0, cp_l1 {
      // Valid combinations
      bins both_I    = binsof(cp_l0.I) && binsof(cp_l1.I);
      bins l0E_l1I   = binsof(cp_l0.E) && binsof(cp_l1.I);
      bins l0I_l1E   = binsof(cp_l0.I) && binsof(cp_l1.E);
      bins l0M_l1I   = binsof(cp_l0.M) && binsof(cp_l1.I);
      bins l0I_l1M   = binsof(cp_l0.I) && binsof(cp_l1.M);
      bins both_S    = binsof(cp_l0.S) && binsof(cp_l1.S);
      bins l0S_l1I   = binsof(cp_l0.S) && binsof(cp_l1.I);
      bins l0I_l1S   = binsof(cp_l0.I) && binsof(cp_l1.S);
      // Illegal combinations (protocol violations)
      illegal_bins dual_M   = binsof(cp_l0.M) && binsof(cp_l1.M);
      illegal_bins l0M_l1S  = binsof(cp_l0.M) && binsof(cp_l1.S);
      illegal_bins l0S_l1M  = binsof(cp_l0.S) && binsof(cp_l1.M);
      illegal_bins l0M_l1E  = binsof(cp_l0.M) && binsof(cp_l1.E);
      illegal_bins l0E_l1M  = binsof(cp_l0.E) && binsof(cp_l1.M);
      illegal_bins dual_E   = binsof(cp_l0.E) && binsof(cp_l1.E);
      illegal_bins l0E_l1S  = binsof(cp_l0.E) && binsof(cp_l1.S);
      illegal_bins l0S_l1E  = binsof(cp_l0.S) && binsof(cp_l1.E);
    }
  endgroup

  // ── Instantiate covergroups ──────────────────────────────────────────
  cg_l0_states       cov_l0_states   = new();
  cg_l1_states       cov_l1_states   = new();
  cg_l0_transitions  cov_l0_trans    = new();
  cg_bus_ops         cov_bus_ops     = new();
  cg_snoop_events    cov_snoop       = new();
  cg_hit_miss        cov_hit_miss    = new();
  cg_joint_state     cov_joint       = new();

  // ── Coverage report at end of simulation ────────────────────────────
  final begin
    $display("\n=== Functional Coverage Report ===");
    $display("L1_0 States:      %0.1f%%", cov_l0_states.get_coverage());
    $display("L1_1 States:      %0.1f%%", cov_l1_states.get_coverage());
    $display("L1_0 Transitions: %0.1f%%", cov_l0_trans.get_coverage());
    $display("Bus Operations:   %0.1f%%", cov_bus_ops.get_coverage());
    $display("Snoop Events:     %0.1f%%", cov_snoop.get_coverage());
    $display("Hit/Miss Events:  %0.1f%%", cov_hit_miss.get_coverage());
    $display("Joint States:     %0.1f%%", cov_joint.get_coverage());
  end

endmodule
