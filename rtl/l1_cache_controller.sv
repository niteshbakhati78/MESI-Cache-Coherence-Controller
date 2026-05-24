// l1_cache_controller.sv
// Parameterized 2-way set-associative L1 cache with MESI per-line state.
// Write-back, write-allocate policy.
// Synchronous active-low reset. Snoop transitions are synchronous.
//
// Address breakdown (default params: NUM_SETS=16, LINE_WORDS=4, WORD_W=32):
//   [1:0]   byte offset within word  (unused at word granularity)
//   [3:2]   word offset within line  (WOFF_BITS = clog2(LINE_WORDS) = 2)
//   [7:4]   set index               (SET_BITS  = clog2(NUM_SETS)   = 4)
//   [31:8]  tag                     (TAG_BITS  = 24)

`timescale 1ns/1ps

module l1_cache_controller #(
  parameter int CACHE_ID   = 0,
  parameter int NUM_SETS   = 16,
  parameter int NUM_WAYS   = 2,
  parameter int LINE_WORDS = 4,
  parameter int WORD_W     = 32
) (
  input  logic clk,
  input  logic rst_n,

  // ── CPU interface ──────────────────────────────────────────────────────
  input  logic              cpu_req,
  input  logic              cpu_we,
  input  logic [31:0]       cpu_addr,
  input  logic [WORD_W-1:0] cpu_wdata,
  output logic [WORD_W-1:0] cpu_rdata,
  output logic              cpu_ack,

  // ── Bus request interface (to bus_arbiter) ────────────────────────────
  output logic                          bus_req,
  output logic [1:0]                    bus_op,   // BUS_RD/RDX/UPGR/WB
  output logic [31:0]                   bus_addr,
  output logic [LINE_WORDS*WORD_W-1:0]  bus_wdata,
  input  logic                          bus_ack,
  input  logic [LINE_WORDS*WORD_W-1:0]  bus_rdata,
  input  logic                          bus_shared, // fill as S (not E)

  // ── Snoop interface (from bus_arbiter, combinational response) ─────────
  input  logic              snoop_valid,
  input  logic [1:0]        snoop_op,
  input  logic [31:0]       snoop_addr,
  output logic              snoop_hit,
  output logic              snoop_dirty,
  output logic [LINE_WORDS*WORD_W-1:0] snoop_data,

  // ── Statistics ─────────────────────────────────────────────────────────
  output logic [31:0]       stat_hits,
  output logic [31:0]       stat_misses,

  // ── Debug / testbench visibility ──────────────────────────────────────
  output logic [1:0]        dbg_state [0:NUM_SETS-1][0:NUM_WAYS-1],
  output logic [31:0]       dbg_tag   [0:NUM_SETS-1][0:NUM_WAYS-1]
);

  // ── Local parameters ───────────────────────────────────────────────────
  localparam int LINE_BYTES = LINE_WORDS * (WORD_W / 8);    // 16
  localparam int OFF_BITS   = $clog2(LINE_BYTES);            // 4
  localparam int WOFF_BITS  = $clog2(LINE_WORDS);            // 2
  localparam int SET_BITS   = $clog2(NUM_SETS);              // 4
  localparam int TAG_BITS   = 32 - SET_BITS - OFF_BITS;      // 24
  localparam int LINE_W     = LINE_WORDS * WORD_W;           // 128

  // MESI state constants
  localparam logic [1:0] ST_I = 2'd0;
  localparam logic [1:0] ST_S = 2'd1;
  localparam logic [1:0] ST_E = 2'd2;
  localparam logic [1:0] ST_M = 2'd3;

  // Bus op constants (match mesi_pkg.sv)
  localparam logic [1:0] OP_RD   = 2'd0;
  localparam logic [1:0] OP_RDX  = 2'd1;
  localparam logic [1:0] OP_UPGR = 2'd2;
  localparam logic [1:0] OP_WB   = 2'd3;

  // FSM state constants
  localparam logic [2:0] FSM_IDLE     = 3'd0;
  localparam logic [2:0] FSM_HIT_ACK  = 3'd1;
  localparam logic [2:0] FSM_MISS_WB  = 3'd2;
  localparam logic [2:0] FSM_MISS_BUS = 3'd3;
  localparam logic [2:0] FSM_FILL     = 3'd4;

  // ── Storage arrays ─────────────────────────────────────────────────────
  logic [TAG_BITS-1:0] tag_arr   [0:NUM_SETS-1][0:NUM_WAYS-1];
  logic [LINE_W-1:0]   data_arr  [0:NUM_SETS-1][0:NUM_WAYS-1];
  logic [1:0]          state_arr [0:NUM_SETS-1][0:NUM_WAYS-1];
  logic                lru_bit   [0:NUM_SETS-1]; // 0=way0 LRU, 1=way1 LRU

  // ── FSM register ────────────────────────────────────────────────────────
  logic [2:0] fsm_state;

  // ── Registered request info ────────────────────────────────────────────
  logic              r_cpu_we;
  logic [31:0]       r_cpu_addr;
  logic [WORD_W-1:0] r_cpu_wdata;
  logic              r_hit_valid;
  logic              r_hit_way;
  logic [1:0]        r_req_op;        // bus op for current miss
  logic              r_victim_way;
  logic [LINE_W-1:0] r_fill_data;
  logic              r_fill_shared;

  // Eviction WB info (for dirty victim)
  logic [31:0]   r_evict_addr;
  logic [LINE_W-1:0] r_evict_data;

  // ── CPU address decode (combinational from live cpu_addr) ──────────────
  logic [WOFF_BITS-1:0] cpu_woff;
  logic [SET_BITS-1:0]  cpu_set;
  logic [TAG_BITS-1:0]  cpu_tag;

  assign cpu_woff = cpu_addr[OFF_BITS-1 -: WOFF_BITS];      // [3:2]
  assign cpu_set  = cpu_addr[OFF_BITS+SET_BITS-1 -: SET_BITS]; // [7:4]
  assign cpu_tag  = cpu_addr[31:OFF_BITS+SET_BITS];          // [31:8]

  // ── Registered address decode ──────────────────────────────────────────
  logic [WOFF_BITS-1:0] r_woff;
  logic [SET_BITS-1:0]  r_set;
  logic [TAG_BITS-1:0]  r_tag;

  assign r_woff = r_cpu_addr[OFF_BITS-1 -: WOFF_BITS];
  assign r_set  = r_cpu_addr[OFF_BITS+SET_BITS-1 -: SET_BITS];
  assign r_tag  = r_cpu_addr[31:OFF_BITS+SET_BITS];

  // ── Hit detection (combinational from live cpu_addr) ───────────────────
  logic hit_w0, hit_w1;
  assign hit_w0 = (state_arr[cpu_set][0] != ST_I) && (tag_arr[cpu_set][0] == cpu_tag);
  assign hit_w1 = (state_arr[cpu_set][1] != ST_I) && (tag_arr[cpu_set][1] == cpu_tag);

  logic cpu_hit;
  logic cpu_hit_way;
  assign cpu_hit     = hit_w0 | hit_w1;
  assign cpu_hit_way = hit_w1;  // way1 wins if both (shouldn't happen)

  logic [1:0] cpu_hit_state;
  assign cpu_hit_state = hit_w1 ? state_arr[cpu_set][1] : state_arr[cpu_set][0];

  // LRU victim
  logic cpu_victim_way;
  assign cpu_victim_way = lru_bit[cpu_set];

  logic victim_dirty;
  assign victim_dirty = (state_arr[cpu_set][cpu_victim_way] == ST_M);

  // ── Snoop address decode ───────────────────────────────────────────────
  logic [WOFF_BITS-1:0] snp_woff;
  logic [SET_BITS-1:0]  snp_set;
  logic [TAG_BITS-1:0]  snp_tag;

  assign snp_woff = snoop_addr[OFF_BITS-1 -: WOFF_BITS];
  assign snp_set  = snoop_addr[OFF_BITS+SET_BITS-1 -: SET_BITS];
  assign snp_tag  = snoop_addr[31:OFF_BITS+SET_BITS];

  logic snp_hit_w0, snp_hit_w1;
  assign snp_hit_w0 = (state_arr[snp_set][0] != ST_I) && (tag_arr[snp_set][0] == snp_tag);
  assign snp_hit_w1 = (state_arr[snp_set][1] != ST_I) && (tag_arr[snp_set][1] == snp_tag);

  logic       snp_way;
  logic [1:0] snp_state;
  assign snp_way   = snp_hit_w1;
  assign snp_state = snp_hit_w1 ? state_arr[snp_set][1] : state_arr[snp_set][0];

  // Combinational snoop response
  assign snoop_hit   = snoop_valid & (snp_hit_w0 | snp_hit_w1);
  assign snoop_dirty = snoop_hit & (snp_state == ST_M);
  assign snoop_data  = data_arr[snp_set][snp_way];

  // ── Debug outputs ──────────────────────────────────────────────────────
  generate
    genvar gs, gw;
    for (gs = 0; gs < NUM_SETS; gs++) begin : dbg_sets
      for (gw = 0; gw < NUM_WAYS; gw++) begin : dbg_ways
        assign dbg_state[gs][gw] = state_arr[gs][gw];
        assign dbg_tag[gs][gw]   = {{(32-TAG_BITS){1'b0}}, tag_arr[gs][gw]};
      end
    end
  endgenerate

  // ── Combinational FSM outputs ──────────────────────────────────────────
  always_comb begin
    cpu_ack   = 1'b0;
    cpu_rdata = '0;
    bus_req   = 1'b0;
    bus_op    = OP_RD;
    bus_addr  = '0;
    bus_wdata = '0;

    unique case (fsm_state)
      // ── IDLE: decode + classify request ──────────────────────────────
      FSM_IDLE: begin
        // Outputs are default (no ack, no bus request)
        // Next-state logic is purely registered (below)
      end

      // ── HIT_ACK: one cycle after IDLE if hit (or after UPGR) ─────────
      FSM_HIT_ACK: begin
        cpu_ack = 1'b1;
        if (r_cpu_we) begin
          cpu_rdata = r_cpu_wdata;
        end else begin
          cpu_rdata = data_arr[r_set][r_hit_way][r_woff * WORD_W +: WORD_W];
        end
      end

      // ── MISS_WB: evicting dirty line — issue BUS_WB ───────────────────
      FSM_MISS_WB: begin
        bus_req   = 1'b1;
        bus_op    = OP_WB;
        bus_addr  = r_evict_addr;
        bus_wdata = r_evict_data;
      end

      // ── MISS_BUS: issue BUS_RD, BUS_RDX, or BUS_UPGR ─────────────────
      FSM_MISS_BUS: begin
        bus_req  = 1'b1;
        bus_op   = r_req_op;
        bus_addr = r_cpu_addr;
      end

      // ── FILL: commit fill data, ack CPU ──────────────────────────────
      FSM_FILL: begin
        cpu_ack = 1'b1;
        if (r_cpu_we) begin
          cpu_rdata = r_cpu_wdata;
        end else begin
          cpu_rdata = r_fill_data[r_woff * WORD_W +: WORD_W];
        end
      end

      default: begin end
    endcase
  end

  // ── Synchronous state updates (arrays, FSM, registers) ────────────────
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fsm_state   <= FSM_IDLE;
      r_cpu_we    <= 1'b0;
      r_cpu_addr  <= '0;
      r_cpu_wdata <= '0;
      r_hit_valid <= 1'b0;
      r_hit_way   <= 1'b0;
      r_req_op    <= OP_RD;
      r_victim_way<= 1'b0;
      r_fill_data <= '0;
      r_fill_shared <= 1'b0;
      r_evict_addr  <= '0;
      r_evict_data  <= '0;
      stat_hits   <= '0;
      stat_misses <= '0;
      for (int s = 0; s < NUM_SETS; s++) begin
        lru_bit[s] <= 1'b0;
        for (int w = 0; w < NUM_WAYS; w++) begin
          state_arr[s][w] <= ST_I;
          tag_arr[s][w]   <= '0;
          data_arr[s][w]  <= '0;
        end
      end
    end else begin

      // ── Priority 1: Snoop updates ──────────────────────────────────────
      // Snoops happen while another core holds the bus; this cache is idle.
      if (snoop_valid && (snp_hit_w0 || snp_hit_w1)) begin
        unique case (snoop_op)
          OP_RD: begin
            // M→S, E→S (clean downgrade)
            if (snp_state == ST_M || snp_state == ST_E)
              state_arr[snp_set][snp_way] <= ST_S;
            // S stays S
          end
          OP_RDX: begin
            // All states → I
            state_arr[snp_set][snp_way] <= ST_I;
            tag_arr[snp_set][snp_way]   <= '0;
          end
          OP_UPGR: begin
            // S → I (other sharers must invalidate)
            if (snp_state == ST_S) begin
              state_arr[snp_set][snp_way] <= ST_I;
              tag_arr[snp_set][snp_way]   <= '0;
            end
          end
          default: begin end
        endcase
      end

      // ── Priority 2: FSM state transitions + cache array updates ───────
      unique case (fsm_state)

        FSM_IDLE: begin
          if (cpu_req) begin
            // Capture request
            r_cpu_we    <= cpu_we;
            r_cpu_addr  <= cpu_addr;
            r_cpu_wdata <= cpu_wdata;
            r_hit_valid <= cpu_hit;
            r_hit_way   <= cpu_hit_way;
            r_victim_way<= cpu_victim_way;

            if (cpu_hit) begin
              // Hit: check if bus is needed (S→M upgrade)
              if (cpu_we && cpu_hit_state == ST_S) begin
                // Write to Shared line: need BUS_UPGR
                r_req_op   <= OP_UPGR;
                stat_hits  <= stat_hits + 1;
                fsm_state  <= FSM_MISS_BUS;
              end else begin
                // Read hit (any state) or write hit (E or M)
                stat_hits  <= stat_hits + 1;
                fsm_state  <= FSM_HIT_ACK;
              end
            end else begin
              // Miss
              stat_misses <= stat_misses + 1;
              r_req_op    <= cpu_we ? OP_RDX : OP_RD;

              if (victim_dirty) begin
                // Need to evict dirty line first
                // Reconstruct evict byte address from tag+set
                r_evict_addr <= {tag_arr[cpu_set][cpu_victim_way],
                                 cpu_set[SET_BITS-1:0],
                                 {OFF_BITS{1'b0}}};
                r_evict_data <= data_arr[cpu_set][cpu_victim_way];
                // Invalidate the victim line now (WB will write to L2)
                state_arr[cpu_set][cpu_victim_way] <= ST_I;
                fsm_state <= FSM_MISS_WB;
              end else begin
                fsm_state <= FSM_MISS_BUS;
              end
            end
          end
        end

        FSM_HIT_ACK: begin
          // Apply write to cache array if needed
          if (r_cpu_we && r_hit_valid) begin
            // E→M or M→M (silent upgrade or continued write)
            state_arr[r_set][r_hit_way] <= ST_M;
            data_arr[r_set][r_hit_way][r_woff * WORD_W +: WORD_W] <= r_cpu_wdata;
          end
          // S→M handled below (came from FSM_MISS_BUS with UPGR)
          lru_bit[r_set] <= ~r_hit_way;
          fsm_state <= FSM_IDLE;
        end

        FSM_MISS_WB: begin
          if (bus_ack) begin
            // WB complete; now issue the actual miss request
            fsm_state <= FSM_MISS_BUS;
          end
        end

        FSM_MISS_BUS: begin
          if (bus_ack) begin
            if (r_req_op == OP_UPGR) begin
              // S→M upgrade: update state in cache, go ack CPU
              state_arr[r_set][r_hit_way] <= ST_M;
              data_arr[r_set][r_hit_way][r_woff * WORD_W +: WORD_W] <= r_cpu_wdata;
              lru_bit[r_set] <= ~r_hit_way;
              fsm_state <= FSM_HIT_ACK;
            end else begin
              // RD or RDX: capture fill data, go to FILL
              r_fill_data   <= bus_rdata;
              r_fill_shared <= bus_shared;
              fsm_state     <= FSM_FILL;
            end
          end
        end

        FSM_FILL: begin
          // Commit fill data to victim way
          data_arr[r_set][r_victim_way] <= r_fill_data;
          tag_arr[r_set][r_victim_way]  <= r_tag;
          if (r_cpu_we) begin
            // Write-allocate: fill then write the word
            data_arr[r_set][r_victim_way][r_woff * WORD_W +: WORD_W] <= r_cpu_wdata;
            state_arr[r_set][r_victim_way] <= ST_M;
          end else begin
            state_arr[r_set][r_victim_way] <= r_fill_shared ? ST_S : ST_E;
          end
          lru_bit[r_set] <= ~r_victim_way;
          fsm_state <= FSM_IDLE;
        end

        default: fsm_state <= FSM_IDLE;
      endcase
    end
  end

endmodule
