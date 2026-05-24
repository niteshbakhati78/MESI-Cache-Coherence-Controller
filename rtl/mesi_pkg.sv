// mesi_pkg.sv — Shared type definitions for the MESI coherence system.
// Used by coherence_system.sv, l1_cache_controller.sv, bus_arbiter.sv,
// and assertion/coverage modules.

package mesi_pkg;

  // ── MESI state encoding ────────────────────────────────────────────────
  typedef enum logic [1:0] {
    MESI_I = 2'b00,   // Invalid
    MESI_S = 2'b01,   // Shared
    MESI_E = 2'b10,   // Exclusive
    MESI_M = 2'b11    // Modified
  } mesi_state_e;

  // ── Bus operation encoding ─────────────────────────────────────────────
  typedef enum logic [1:0] {
    BUS_RD   = 2'b00,  // Read miss — fetch line, may share
    BUS_RDX  = 2'b01,  // Read-for-ownership — fetch line exclusive
    BUS_UPGR = 2'b10,  // Upgrade Shared→Modified (no data fetch)
    BUS_WB   = 2'b11   // Writeback — evicting dirty line to L2
  } bus_op_e;

  // ── L1 FSM state encoding ─────────────────────────────────────────────
  typedef enum logic [2:0] {
    L1_IDLE     = 3'd0,   // Waiting for CPU request
    L1_HIT_ACK  = 3'd1,   // Serve hit (or post-upgrade write)
    L1_MISS_WB  = 3'd2,   // Evict dirty line before fill
    L1_MISS_BUS = 3'd3,   // Waiting for bus grant + transaction
    L1_FILL     = 3'd4    // Write fill data into cache arrays
  } l1_fsm_e;

  // ── Bus arbiter FSM state encoding ────────────────────────────────────
  typedef enum logic [2:0] {
    ARB_IDLE     = 3'd0,  // Waiting for requests
    ARB_SNOOP    = 3'd1,  // Broadcast snoop, read response
    ARB_SNOOP_WB = 3'd2,  // Write snoop dirty data to L2
    ARB_L2_WAIT  = 3'd3,  // Waiting for L2 read
    ARB_RESP     = 3'd4,  // Send fill response to requester
    ARB_WB_WAIT  = 3'd5   // Wait for L2 eviction writeback
  } arb_fsm_e;

endpackage
