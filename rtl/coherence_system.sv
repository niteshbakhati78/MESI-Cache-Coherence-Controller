// coherence_system.sv
// Top-level 2-core MESI coherence system.
// Instantiates:
//   - 2x l1_cache_controller (Core 0 and Core 1)
//   - 1x bus_arbiter (snooping bus controller + L2 coordination)
//   - 1x l2_cache (shared inclusive L2)
//
// All modules use synchronous active-low reset.
// Parameters are propagated consistently.

`timescale 1ns/1ps

module coherence_system #(
  parameter int NUM_SETS   = 16,
  parameter int NUM_WAYS   = 2,
  parameter int LINE_WORDS = 4,
  parameter int WORD_W     = 32,
  parameter int L2_LINES   = 256,
  parameter int L2_LATENCY = 4
) (
  input  logic clk,
  input  logic rst_n,

  // ── Core 0 CPU interface ───────────────────────────────────────────────
  input  logic              cpu0_req,
  input  logic              cpu0_we,
  input  logic [31:0]       cpu0_addr,
  input  logic [WORD_W-1:0] cpu0_wdata,
  output logic [WORD_W-1:0] cpu0_rdata,
  output logic              cpu0_ack,

  // ── Core 1 CPU interface ───────────────────────────────────────────────
  input  logic              cpu1_req,
  input  logic              cpu1_we,
  input  logic [31:0]       cpu1_addr,
  input  logic [WORD_W-1:0] cpu1_wdata,
  output logic [WORD_W-1:0] cpu1_rdata,
  output logic              cpu1_ack
);

  localparam int LINE_W   = LINE_WORDS * WORD_W;
  localparam int OFF_BITS = $clog2(LINE_WORDS * (WORD_W / 8));

  // ── Bus wires: L1_0 ↔ Arbiter ────────────────────────────────────────
  logic                  l0_req,  l0_gnt,  l0_ack;
  logic [1:0]            l0_op;
  logic [31:0]           l0_addr;
  logic [LINE_W-1:0]     l0_wdata, l0_rdata;
  logic                  l0_shared;

  // ── Bus wires: L1_1 ↔ Arbiter ────────────────────────────────────────
  logic                  l1_req,  l1_gnt,  l1_ack;
  logic [1:0]            l1_op;
  logic [31:0]           l1_addr;
  logic [LINE_W-1:0]     l1_wdata, l1_rdata;
  logic                  l1_shared;

  // ── Snoop wires: Arbiter → L1_0 ──────────────────────────────────────
  logic                  snoop0_valid, snoop0_hit, snoop0_dirty;
  logic [1:0]            snoop0_op;
  logic [31:0]           snoop0_addr;
  logic [LINE_W-1:0]     snoop0_data;

  // ── Snoop wires: Arbiter → L1_1 ──────────────────────────────────────
  logic                  snoop1_valid, snoop1_hit, snoop1_dirty;
  logic [1:0]            snoop1_op;
  logic [31:0]           snoop1_addr;
  logic [LINE_W-1:0]     snoop1_data;

  // ── L2 wires: Arbiter ↔ L2 ───────────────────────────────────────────
  logic                  l2_rd, l2_wr;
  logic [7:0]            l2_line_addr;
  logic [LINE_W-1:0]     l2_wdata, l2_rdata;

  // ── L1 Cache 0 ────────────────────────────────────────────────────────
  logic [1:0]  dbg_l0_state [0:NUM_SETS-1][0:NUM_WAYS-1];
  logic [31:0] dbg_l0_tag   [0:NUM_SETS-1][0:NUM_WAYS-1];

  l1_cache_controller #(
    .CACHE_ID   (0),
    .NUM_SETS   (NUM_SETS),
    .NUM_WAYS   (NUM_WAYS),
    .LINE_WORDS (LINE_WORDS),
    .WORD_W     (WORD_W)
  ) l1_0 (
    .clk        (clk),
    .rst_n      (rst_n),
    // CPU
    .cpu_req    (cpu0_req),
    .cpu_we     (cpu0_we),
    .cpu_addr   (cpu0_addr),
    .cpu_wdata  (cpu0_wdata),
    .cpu_rdata  (cpu0_rdata),
    .cpu_ack    (cpu0_ack),
    // Bus
    .bus_req    (l0_req),
    .bus_op     (l0_op),
    .bus_addr   (l0_addr),
    .bus_wdata  (l0_wdata),
    .bus_ack    (l0_ack),
    .bus_rdata  (l0_rdata),
    .bus_shared (l0_shared),
    // Snoop
    .snoop_valid(snoop0_valid),
    .snoop_op   (snoop0_op),
    .snoop_addr (snoop0_addr),
    .snoop_hit  (snoop0_hit),
    .snoop_dirty(snoop0_dirty),
    .snoop_data (snoop0_data),
    // Debug
    .dbg_state  (dbg_l0_state),
    .dbg_tag    (dbg_l0_tag),
    // Stats (unused at top)
    .stat_hits  (),
    .stat_misses()
  );

  // ── L1 Cache 1 ────────────────────────────────────────────────────────
  logic [1:0]  dbg_l1_state [0:NUM_SETS-1][0:NUM_WAYS-1];
  logic [31:0] dbg_l1_tag   [0:NUM_SETS-1][0:NUM_WAYS-1];

  l1_cache_controller #(
    .CACHE_ID   (1),
    .NUM_SETS   (NUM_SETS),
    .NUM_WAYS   (NUM_WAYS),
    .LINE_WORDS (LINE_WORDS),
    .WORD_W     (WORD_W)
  ) l1_1 (
    .clk        (clk),
    .rst_n      (rst_n),
    // CPU
    .cpu_req    (cpu1_req),
    .cpu_we     (cpu1_we),
    .cpu_addr   (cpu1_addr),
    .cpu_wdata  (cpu1_wdata),
    .cpu_rdata  (cpu1_rdata),
    .cpu_ack    (cpu1_ack),
    // Bus
    .bus_req    (l1_req),
    .bus_op     (l1_op),
    .bus_addr   (l1_addr),
    .bus_wdata  (l1_wdata),
    .bus_ack    (l1_ack),
    .bus_rdata  (l1_rdata),
    .bus_shared (l1_shared),
    // Snoop
    .snoop_valid(snoop1_valid),
    .snoop_op   (snoop1_op),
    .snoop_addr (snoop1_addr),
    .snoop_hit  (snoop1_hit),
    .snoop_dirty(snoop1_dirty),
    .snoop_data (snoop1_data),
    // Debug
    .dbg_state  (dbg_l1_state),
    .dbg_tag    (dbg_l1_tag),
    // Stats
    .stat_hits  (),
    .stat_misses()
  );

  // ── Bus Arbiter ────────────────────────────────────────────────────────
  bus_arbiter #(
    .LINE_WORDS (LINE_WORDS),
    .WORD_W     (WORD_W),
    .L2_LATENCY (L2_LATENCY),
    .OFF_BITS   (OFF_BITS)
  ) arb (
    .clk          (clk),
    .rst_n        (rst_n),
    // L1_0
    .l0_req       (l0_req),
    .l0_op        (l0_op),
    .l0_addr      (l0_addr),
    .l0_wdata     (l0_wdata),
    .l0_gnt       (l0_gnt),
    .l0_ack       (l0_ack),
    .l0_rdata     (l0_rdata),
    .l0_shared    (l0_shared),
    // L1_1
    .l1_req       (l1_req),
    .l1_op        (l1_op),
    .l1_addr      (l1_addr),
    .l1_wdata     (l1_wdata),
    .l1_gnt       (l1_gnt),
    .l1_ack       (l1_ack),
    .l1_rdata     (l1_rdata),
    .l1_shared    (l1_shared),
    // Snoop 0
    .snoop0_valid (snoop0_valid),
    .snoop0_op    (snoop0_op),
    .snoop0_addr  (snoop0_addr),
    .snoop0_hit   (snoop0_hit),
    .snoop0_dirty (snoop0_dirty),
    .snoop0_data  (snoop0_data),
    // Snoop 1
    .snoop1_valid (snoop1_valid),
    .snoop1_op    (snoop1_op),
    .snoop1_addr  (snoop1_addr),
    .snoop1_hit   (snoop1_hit),
    .snoop1_dirty (snoop1_dirty),
    .snoop1_data  (snoop1_data),
    // L2
    .l2_rd        (l2_rd),
    .l2_wr        (l2_wr),
    .l2_addr      (l2_line_addr),
    .l2_wdata     (l2_wdata),
    .l2_rdata     (l2_rdata),
    // Stats (unused at top, but wired for synthesis visibility)
    .stat_bus_rd  (),
    .stat_bus_rdx (),
    .stat_bus_upgr(),
    .stat_bus_wb  ()
  );

  // ── Shared L2 Cache ────────────────────────────────────────────────────
  l2_cache #(
    .LINE_WORDS (LINE_WORDS),
    .NUM_LINES  (L2_LINES),
    .WORD_W     (WORD_W)
  ) l2 (
    .clk       (clk),
    .rst_n     (rst_n),
    .rd_en     (l2_rd),
    .wr_en     (l2_wr),
    .line_addr (l2_line_addr),
    .wr_data   (l2_wdata),
    .rd_data   (l2_rdata)
  );

endmodule
