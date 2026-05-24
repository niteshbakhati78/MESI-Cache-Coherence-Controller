// mesi_sva.sv
// SVA protocol correctness assertions for the MESI coherence system.
// Bind point: coherence_system (or tb_coherence_system via bind statement).
//
// How to include in Vivado simulation:
//   1. Add this file to the project sim fileset.
//   2. In Tcl console (or run_sim.tcl) after adding all sources:
//      set_property -name {xsim.simulate.xsim.more_options} \
//                   -value {-assert} \
//                   -objects [get_filesets sim_1]
//   3. Add the bind directive below to tb_coherence_system or a separate
//      bind file, and include in the sim compile step.
//
// Alternatively, instantiate mesi_sva directly in tb_coherence_system and
// wire the required signals.

`timescale 1ns/1ps

module mesi_sva #(
  parameter int NUM_SETS   = 16,
  parameter int NUM_WAYS   = 2,
  parameter int LINE_WORDS = 4,
  parameter int WORD_W     = 32
) (
  input  logic clk,
  input  logic rst_n,

  // L1_0 state/tag arrays (all sets, all ways)
  input  logic [1:0]  l0_state [0:NUM_SETS-1][0:NUM_WAYS-1],
  input  logic [31:0] l0_tag   [0:NUM_SETS-1][0:NUM_WAYS-1],

  // L1_1 state/tag arrays (all sets, all ways)
  input  logic [1:0]  l1_state [0:NUM_SETS-1][0:NUM_WAYS-1],
  input  logic [31:0] l1_tag   [0:NUM_SETS-1][0:NUM_WAYS-1],

  // Bus signals (from bus_arbiter)
  input  logic        bus_snoop0_valid,   // snoop being sent to L1_0
  input  logic [1:0]  bus_snoop0_op,
  input  logic        bus_snoop1_valid,   // snoop being sent to L1_1
  input  logic [1:0]  bus_snoop1_op,

  input  logic        snoop0_dirty,       // L1_0 has dirty copy
  input  logic        snoop1_dirty,       // L1_1 has dirty copy

  input  logic        l0_ack,             // L1_0 bus transaction complete
  input  logic        l1_ack,             // L1_1 bus transaction complete
  input  logic [1:0]  l0_op,             // L1_0 current bus op
  input  logic [1:0]  l1_op,

  // Sharer count (combinationally computed below from state arrays)
  // Used for BusReadX assertion
  input  logic [31:0] bus_addr_arb        // address currently on bus
);

  // MESI state constants
  localparam logic [1:0] ST_I = 2'd0;
  localparam logic [1:0] ST_S = 2'd1;
  localparam logic [1:0] ST_E = 2'd2;
  localparam logic [1:0] ST_M = 2'd3;

  // Bus op constants
  localparam logic [1:0] OP_RD   = 2'd0;
  localparam logic [1:0] OP_RDX  = 2'd1;
  localparam logic [1:0] OP_UPGR = 2'd2;
  localparam logic [1:0] OP_WB   = 2'd3;

  // ── Helper: check if a line address is present in a state array ────────
  // Returns the MESI state for a given {tag, set} combo; ST_I if absent.
  function automatic logic [1:0] l0_line_state(
    input logic [3:0]  set_idx,
    input logic [23:0] tag
  );
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (l0_state[set_idx][w] != ST_I && l0_tag[set_idx][w][23:0] == tag)
        return l0_state[set_idx][w];
    end
    return ST_I;
  endfunction

  function automatic logic [1:0] l1_line_state(
    input logic [3:0]  set_idx,
    input logic [23:0] tag
  );
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (l1_state[set_idx][w] != ST_I && l1_tag[set_idx][w][23:0] == tag)
        return l1_state[set_idx][w];
    end
    return ST_I;
  endfunction

  // Derive set index and tag from bus address
  logic [3:0]  bus_set;
  logic [23:0] bus_tag;
  assign bus_set = bus_addr_arb[7:4];
  assign bus_tag = bus_addr_arb[31:8];

  // Current states of the line on the bus in each cache
  logic [1:0] bus_l0_st, bus_l1_st;
  assign bus_l0_st = l0_line_state(bus_set, bus_tag);
  assign bus_l1_st = l1_line_state(bus_set, bus_tag);

  // ── Sharer count for the bus address ──────────────────────────────────
  logic [2:0] sharer_count;
  always_comb begin
    sharer_count = 3'd0;
    if (bus_l0_st != ST_I) sharer_count++;
    if (bus_l1_st != ST_I) sharer_count++;
  end

  // ── Assertion 1: No Dual Modified (most critical coherence invariant) ──
  // For every set and every way combination, no two caches can hold the
  // same line address in Modified state simultaneously.
  generate
    genvar s, w0, w1;
    for (s = 0; s < NUM_SETS; s++) begin : a1_sets
      for (w0 = 0; w0 < NUM_WAYS; w0++) begin : a1_w0
        for (w1 = 0; w1 < NUM_WAYS; w1++) begin : a1_w1
          property no_dual_modified;
            @(posedge clk) disable iff (!rst_n)
            !(l0_state[s][w0] == ST_M &&
              l1_state[s][w1] == ST_M &&
              l0_tag[s][w0]   == l1_tag[s][w1] &&
              l0_state[s][w0] != ST_I);
          endproperty
          NO_DUAL_MOD: assert property (no_dual_modified)
            else $error("[SVA FAIL] Dual-Modified violation: set=%0d w0=%0d w1=%0d tag=%h time=%0t",
                        s, w0, w1, l0_tag[s][w0], $time);
        end
      end
    end
  endgenerate

  // ── Assertion 2: No Shared+Modified simultaneously ─────────────────────
  // A line cannot be Shared in one cache and Modified in the other.
  generate
    genvar sa, wa, wb;
    for (sa = 0; sa < NUM_SETS; sa++) begin : a2_sets
      for (wa = 0; wa < NUM_WAYS; wa++) begin : a2_wa
        for (wb = 0; wb < NUM_WAYS; wb++) begin : a2_wb
          property no_shared_and_modified;
            @(posedge clk) disable iff (!rst_n)
            !(((l0_state[sa][wa] == ST_S && l1_state[sa][wb] == ST_M) ||
               (l0_state[sa][wa] == ST_M && l1_state[sa][wb] == ST_S)) &&
              l0_tag[sa][wa] == l1_tag[sa][wb] &&
              l0_state[sa][wa] != ST_I);
          endproperty
          NO_SHR_MOD: assert property (no_shared_and_modified)
            else $error("[SVA FAIL] Shared+Modified violation: set=%0d tag=%h time=%0t",
                        sa, l0_tag[sa][wa], $time);
        end
      end
    end
  endgenerate

  // ── Assertion 3: Modified writeback on BusRead snoop (within 4 cycles) ─
  // When a snoop BUS_RD targets a cache with M state, the dirty flag must
  // be observed (combinationally) in the same cycle the snoop is issued.
  // This checks that snoop logic is correct: if we're snooping L1_0 with
  // BUS_RD and L1_0 holds the line Modified, then snoop0_dirty must be 1.
  property modified_wb_on_busrd_snoop0;
    @(posedge clk) disable iff (!rst_n)
    (bus_snoop0_valid && bus_snoop0_op == OP_RD && bus_l0_st == ST_M)
    |->
    snoop0_dirty;
  endproperty
  MOD_WB_BUSRD_0: assert property (modified_wb_on_busrd_snoop0)
    else $error("[SVA FAIL] L1_0 in Modified but snoop0_dirty not asserted on BusRD snoop");

  property modified_wb_on_busrd_snoop1;
    @(posedge clk) disable iff (!rst_n)
    (bus_snoop1_valid && bus_snoop1_op == OP_RD && bus_l1_st == ST_M)
    |->
    snoop1_dirty;
  endproperty
  MOD_WB_BUSRD_1: assert property (modified_wb_on_busrd_snoop1)
    else $error("[SVA FAIL] L1_1 in Modified but snoop1_dirty not asserted on BusRD snoop");

  // ── Assertion 4: BusReadX invalidates all sharers within 3 cycles ──────
  // After a BusReadX completes (bus_ack), sharer_count must drop to <= 1
  // within 3 cycles (the winner gets M, everyone else goes I).
  property busreadx_invalidates_l0;
    @(posedge clk) disable iff (!rst_n)
    (l0_ack && l0_op == OP_RDX) |-> ##[1:3] (bus_l1_st == ST_I);
  endproperty
  BRX_INVAL_L0: assert property (busreadx_invalidates_l0)
    else $error("[SVA FAIL] BusRDX by L0: L1_1 not invalidated within 3 cycles");

  property busreadx_invalidates_l1;
    @(posedge clk) disable iff (!rst_n)
    (l1_ack && l1_op == OP_RDX) |-> ##[1:3] (bus_l0_st == ST_I);
  endproperty
  BRX_INVAL_L1: assert property (busreadx_invalidates_l1)
    else $error("[SVA FAIL] BusRDX by L1: L1_0 not invalidated within 3 cycles");

  // ── Assertion 5: Exclusive state is unshared ───────────────────────────
  // If one cache holds a line in E state, the other must be I.
  generate
    genvar se, we0, we1;
    for (se = 0; se < NUM_SETS; se++) begin : a5_sets
      for (we0 = 0; we0 < NUM_WAYS; we0++) begin : a5_we0
        for (we1 = 0; we1 < NUM_WAYS; we1++) begin : a5_we1
          property exclusive_unshared;
            @(posedge clk) disable iff (!rst_n)
            !(l0_state[se][we0] == ST_E &&
              l1_state[se][we1] != ST_I  &&
              l0_tag[se][we0] == l1_tag[se][we1]);
          endproperty
          EXCL_UNSHARED: assert property (exclusive_unshared)
            else $error("[SVA FAIL] Exclusive line shared: set=%0d tag=%h time=%0t",
                        se, l0_tag[se][we0], $time);
        end
      end
    end
  endgenerate

endmodule


// ── Bind directive (add to simulation compile command or separate file) ──
// Uncomment and use this bind in your tb_coherence_system or Vivado TCL:
//
// bind coherence_system mesi_sva #(
//   .NUM_SETS   (NUM_SETS),
//   .NUM_WAYS   (NUM_WAYS),
//   .LINE_WORDS (LINE_WORDS),
//   .WORD_W     (WORD_W)
// ) sva_inst (
//   .clk              (clk),
//   .rst_n            (rst_n),
//   .l0_state         (l1_0.dbg_state),
//   .l0_tag           (l1_0.dbg_tag),
//   .l1_state         (l1_1.dbg_state),
//   .l1_tag           (l1_1.dbg_tag),
//   .bus_snoop0_valid (arb.snoop0_valid),
//   .bus_snoop0_op    (arb.snoop0_op),
//   .bus_snoop1_valid (arb.snoop1_valid),
//   .bus_snoop1_op    (arb.snoop1_op),
//   .snoop0_dirty     (arb.snoop0_dirty),
//   .snoop1_dirty     (arb.snoop1_dirty),
//   .l0_ack           (arb.l0_ack),
//   .l1_ack           (arb.l1_ack),
//   .l0_op            (arb.l0_op),
//   .l1_op            (arb.l1_op),
//   .bus_addr_arb     (arb.r_addr)
// );
