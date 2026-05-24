// bus_arbiter.sv
// Snooping bus arbiter with full coherence coordination.
// Manages the shared bus for a 2-core MESI system:
//   1. Arbitrates between L1_0 and L1_1 requests (round-robin)
//   2. Broadcasts snoop to the non-requesting cache
//   3. Handles dirty intervention (M-state writeback)
//   4. Fetches from shared L2 if no dirty copy is available
//   5. Returns fill data + shared flag to the requesting cache
//
// L2 is a registered SRAM (data valid one cycle after rd_en).
// L2_LATENCY parameter determines the number of wait cycles in ARB_L2_WAIT.
// Minimum useful value is 2 (1 to register address, 1 for data to appear).

`timescale 1ns/1ps

module bus_arbiter #(
  parameter int LINE_WORDS = 4,
  parameter int WORD_W     = 32,
  parameter int L2_LATENCY = 4,   // cycles to wait in L2_WAIT state
  parameter int OFF_BITS   = 4    // byte offset bits (clog2 of line bytes)
) (
  input  logic clk,
  input  logic rst_n,

  // ── L1 Cache 0 request/response ───────────────────────────────────────
  input  logic                         l0_req,
  input  logic [1:0]                   l0_op,
  input  logic [31:0]                  l0_addr,
  input  logic [LINE_WORDS*WORD_W-1:0] l0_wdata,
  output logic                         l0_gnt,
  output logic                         l0_ack,
  output logic [LINE_WORDS*WORD_W-1:0] l0_rdata,
  output logic                         l0_shared,

  // ── L1 Cache 1 request/response ───────────────────────────────────────
  input  logic                         l1_req,
  input  logic [1:0]                   l1_op,
  input  logic [31:0]                  l1_addr,
  input  logic [LINE_WORDS*WORD_W-1:0] l1_wdata,
  output logic                         l1_gnt,
  output logic                         l1_ack,
  output logic [LINE_WORDS*WORD_W-1:0] l1_rdata,
  output logic                         l1_shared,

  // ── Snoop to L1 Cache 0 ───────────────────────────────────────────────
  output logic                         snoop0_valid,
  output logic [1:0]                   snoop0_op,
  output logic [31:0]                  snoop0_addr,
  input  logic                         snoop0_hit,
  input  logic                         snoop0_dirty,
  input  logic [LINE_WORDS*WORD_W-1:0] snoop0_data,

  // ── Snoop to L1 Cache 1 ───────────────────────────────────────────────
  output logic                         snoop1_valid,
  output logic [1:0]                   snoop1_op,
  output logic [31:0]                  snoop1_addr,
  input  logic                         snoop1_hit,
  input  logic                         snoop1_dirty,
  input  logic [LINE_WORDS*WORD_W-1:0] snoop1_data,

  // ── Shared L2 cache ───────────────────────────────────────────────────
  output logic                         l2_rd,
  output logic                         l2_wr,
  output logic [7:0]                   l2_addr,   // line index (256 lines)
  output logic [LINE_WORDS*WORD_W-1:0] l2_wdata,
  input  logic [LINE_WORDS*WORD_W-1:0] l2_rdata,

  // ── Bus transaction statistics ────────────────────────────────────────
  output logic [31:0]                  stat_bus_rd,
  output logic [31:0]                  stat_bus_rdx,
  output logic [31:0]                  stat_bus_upgr,
  output logic [31:0]                  stat_bus_wb
);

  localparam int LINE_W = LINE_WORDS * WORD_W;  // 128

  // Bus op constants
  localparam logic [1:0] OP_RD   = 2'd0;
  localparam logic [1:0] OP_RDX  = 2'd1;
  localparam logic [1:0] OP_UPGR = 2'd2;
  localparam logic [1:0] OP_WB   = 2'd3;

  // FSM states
  localparam logic [2:0] ARB_IDLE     = 3'd0;
  localparam logic [2:0] ARB_SNOOP    = 3'd1;
  localparam logic [2:0] ARB_SNOOP_WB = 3'd2;
  localparam logic [2:0] ARB_L2_WAIT  = 3'd3;
  localparam logic [2:0] ARB_RESP     = 3'd4;
  localparam logic [2:0] ARB_WB_WAIT  = 3'd5;

  // ── State registers ───────────────────────────────────────────────────
  logic [2:0] arb_state;
  logic       last_grant;     // 0=L0 last granted, 1=L1 last granted
  logic       r_winner;       // 0=L0 won this round, 1=L1 won

  // Saved request info
  logic [1:0]     r_op;
  logic [31:0]    r_addr;
  logic [LINE_W-1:0] r_wdata;

  // Snoop response info
  logic           r_snp_hit;
  logic           r_snp_dirty;
  logic [LINE_W-1:0] r_snp_data;

  // Fill data to return to requester
  logic [LINE_W-1:0] r_fill_data;
  logic           r_fill_shared;

  // L2 wait counter
  logic [$clog2(L2_LATENCY+1)-1:0] l2_cnt;

  // ── Combinational snoop mux (selects non-winner's responses) ──────────
  logic       snp_hit;
  logic       snp_dirty;
  logic [LINE_W-1:0] snp_data;

  // snoop sent to L1_1 when L1_0 wins, sent to L1_0 when L1_1 wins
  assign snp_hit   = r_winner ? snoop0_hit   : snoop1_hit;
  assign snp_dirty = r_winner ? snoop0_dirty : snoop1_dirty;
  assign snp_data  = r_winner ? snoop0_data  : snoop1_data;

  // ── Combinational FSM outputs ──────────────────────────────────────────
  always_comb begin
    // defaults
    l0_gnt    = 1'b0;   l1_gnt    = 1'b0;
    l0_ack    = 1'b0;   l1_ack    = 1'b0;
    l0_rdata  = '0;     l1_rdata  = '0;
    l0_shared = 1'b0;   l1_shared = 1'b0;

    snoop0_valid = 1'b0;  snoop0_op = OP_RD;  snoop0_addr = '0;
    snoop1_valid = 1'b0;  snoop1_op = OP_RD;  snoop1_addr = '0;

    l2_rd    = 1'b0;
    l2_wr    = 1'b0;
    l2_addr  = '0;
    l2_wdata = '0;

    unique case (arb_state)
      ARB_IDLE: begin
        // Combinational grant pulse: assert for 1 cycle when a request is seen
        if (l0_req && (!l1_req || last_grant == 1'b0))
          l0_gnt = 1'b1;
        else if (l1_req)
          l1_gnt = 1'b1;
      end

      ARB_SNOOP: begin
        // Assert snoop to non-winning L1
        if (r_winner == 1'b0) begin  // L0 won → snoop L1
          snoop1_valid = 1'b1;
          snoop1_op    = r_op;
          snoop1_addr  = r_addr;
        end else begin               // L1 won → snoop L0
          snoop0_valid = 1'b1;
          snoop0_op    = r_op;
          snoop0_addr  = r_addr;
        end
      end

      ARB_SNOOP_WB: begin
        // Write dirty snoop data to L2
        l2_wr    = (l2_cnt > 0);
        l2_addr  = r_addr[OFF_BITS +: 8];
        l2_wdata = r_snp_data;
      end

      ARB_L2_WAIT: begin
        // Read from L2 (drive rd_en throughout to ensure registered data valid)
        l2_rd   = 1'b1;
        l2_addr = r_addr[OFF_BITS +: 8];
      end

      ARB_WB_WAIT: begin
        // Write eviction data to L2
        l2_wr    = (l2_cnt > 0);
        l2_addr  = r_addr[OFF_BITS +: 8];
        l2_wdata = r_wdata;
      end

      ARB_RESP: begin
        // Send fill response to winning L1
        if (r_winner == 1'b0) begin
          l0_ack    = 1'b1;
          l0_rdata  = r_fill_data;
          l0_shared = r_fill_shared;
        end else begin
          l1_ack    = 1'b1;
          l1_rdata  = r_fill_data;
          l1_shared = r_fill_shared;
        end
      end

      default: begin end
    endcase
  end

  // ── FSM sequential logic ───────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      arb_state   <= ARB_IDLE;
      last_grant  <= 1'b0;
      r_winner    <= 1'b0;
      r_op        <= OP_RD;
      r_addr      <= '0;
      r_wdata     <= '0;
      r_snp_hit   <= 1'b0;
      r_snp_dirty <= 1'b0;
      r_snp_data  <= '0;
      r_fill_data <= '0;
      r_fill_shared <= 1'b0;
      l2_cnt      <= '0;
      stat_bus_rd   <= '0;
      stat_bus_rdx  <= '0;
      stat_bus_upgr <= '0;
      stat_bus_wb   <= '0;
    end else begin

      unique case (arb_state)

        // ── IDLE: wait for request, grant winner ────────────────────────
        ARB_IDLE: begin
          if (l0_req || l1_req) begin
            // Round-robin arbitration
            if      (l0_req && !l1_req)                   r_winner <= 1'b0;
            else if (l1_req && !l0_req)                   r_winner <= 1'b1;
            else if (l0_req && l1_req && last_grant == 0) r_winner <= 1'b1; // give L1 turn
            else                                           r_winner <= 1'b0;

            // Capture request from winner
            // (must use combinational mux since r_winner set above)
            if (l0_req && (!l1_req || last_grant == 0)) begin
              r_op    <= l0_op;
              r_addr  <= l0_addr;
              r_wdata <= l0_wdata;
              last_grant <= 1'b0;
              // Stats
              case (l0_op)
                OP_RD:   stat_bus_rd   <= stat_bus_rd   + 1;
                OP_RDX:  stat_bus_rdx  <= stat_bus_rdx  + 1;
                OP_UPGR: stat_bus_upgr <= stat_bus_upgr + 1;
                OP_WB:   stat_bus_wb   <= stat_bus_wb   + 1;
                default: begin end
              endcase
              if (l0_op == OP_WB)
                arb_state <= ARB_WB_WAIT;
              else
                arb_state <= ARB_SNOOP;
            end else begin
              r_op    <= l1_op;
              r_addr  <= l1_addr;
              r_wdata <= l1_wdata;
              last_grant <= 1'b1;
              case (l1_op)
                OP_RD:   stat_bus_rd   <= stat_bus_rd   + 1;
                OP_RDX:  stat_bus_rdx  <= stat_bus_rdx  + 1;
                OP_UPGR: stat_bus_upgr <= stat_bus_upgr + 1;
                OP_WB:   stat_bus_wb   <= stat_bus_wb   + 1;
                default: begin end
              endcase
              if (l1_op == OP_WB)
                arb_state <= ARB_WB_WAIT;
              else
                arb_state <= ARB_SNOOP;
            end

            l2_cnt <= L2_LATENCY[($clog2(L2_LATENCY+1))-1:0] - 1;
          end
        end

        // ── SNOOP: snoop_valid driven combinationally; read responses ───
        ARB_SNOOP: begin
          // snoop_valid was asserted last cycle by combinational logic.
          // L1 combinationally responds with hit/dirty/data.
          // Capture responses and decide next state.
          r_snp_hit   <= snp_hit;
          r_snp_dirty <= snp_dirty;
          r_snp_data  <= snp_data;

          // Determine fill_shared for BUS_RD
          if (r_op == OP_RD)
            r_fill_shared <= snp_hit; // shared if non-winner had a copy
          else
            r_fill_shared <= 1'b0;

          if (snp_dirty) begin
            // Dirty intervention: write snoop data to L2, then respond
            r_fill_data <= snp_data; // use intervention data, not L2
            arb_state   <= ARB_SNOOP_WB;
            l2_cnt      <= L2_LATENCY[($clog2(L2_LATENCY+1))-1:0] - 1;
          end else if (r_op == OP_UPGR) begin
            // Upgrade: no data fill needed
            r_fill_data <= '0;
            arb_state   <= ARB_RESP;
          end else begin
            // Fetch from L2 (RD or RDX with no dirty snoop)
            arb_state <= ARB_L2_WAIT;
            l2_cnt    <= L2_LATENCY[($clog2(L2_LATENCY+1))-1:0] - 1;
          end
        end

        // ── SNOOP_WB: write dirty snoop data to L2, then respond ───────
        ARB_SNOOP_WB: begin
          if (l2_cnt == 0) begin
            // WB complete; fill data already captured (= r_snp_data)
            arb_state <= ARB_RESP;
          end else begin
            l2_cnt <= l2_cnt - 1;
          end
        end

        // ── L2_WAIT: wait for L2 read data ──────────────────────────────
        ARB_L2_WAIT: begin
          if (l2_cnt == 0) begin
            // l2_rd was asserted combinationally every cycle in this state.
            // l2_rdata is valid now (registered output from l2_cache).
            r_fill_data <= l2_rdata;
            arb_state   <= ARB_RESP;
          end else begin
            l2_cnt <= l2_cnt - 1;
          end
        end

        // ── RESP: deliver response to requester ──────────────────────────
        ARB_RESP: begin
          // l0_ack/l1_ack driven combinationally in this state.
          // Send winning L1 ack for BUS_WB case too (if op was WB)
          arb_state <= ARB_IDLE;
        end

        // ── WB_WAIT: wait for L2 eviction writeback ──────────────────────
        ARB_WB_WAIT: begin
          if (l2_cnt == 0) begin
            // WB done: ack the requester
            if (r_winner == 1'b0) begin end // l0_ack driven in RESP
            arb_state <= ARB_RESP;
            // Clear fill_data/shared (not used for WB response)
            r_fill_data   <= '0;
            r_fill_shared <= 1'b0;
          end else begin
            l2_cnt <= l2_cnt - 1;
          end
        end

        default: arb_state <= ARB_IDLE;
      endcase
    end
  end

endmodule
