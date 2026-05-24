// MESI per-line finite state machine (reference skeleton).
//
// This is intentionally lightweight: it encodes the canonical MESI transitions
// needed for a 2-core snooping system (BusRd/BusRdX/BusUpgr).
//
// The Python golden model in `verif/mesi_model.py` is the functional reference.

`timescale 1ns/1ps

module mesi_fsm #(
  parameter bit ONE_HOT = 1'b0
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 cpu_rd,
  input  logic                 cpu_wr,
  input  logic                 cpu_hit,

  input  logic                 snoop_valid,
  input  logic [1:0]           snoop_op,   // 0:BusRd 1:BusRdX 2:BusUpgr

  input  logic                 shared_seen, // from bus (another cache had a copy) for BusRd

  output logic [1:0]           state_q,     // 0:I 1:S 2:E 3:M
  output logic                 bus_req,
  output logic [1:0]           bus_op,      // 0:BusRd 1:BusRdX 2:BusUpgr
  output logic                 wb_en        // writeback enable (when supplying dirty data)
);

  localparam logic [1:0] ST_I = 2'd0;
  localparam logic [1:0] ST_S = 2'd1;
  localparam logic [1:0] ST_E = 2'd2;
  localparam logic [1:0] ST_M = 2'd3;

  localparam logic [1:0] OP_RD   = 2'd0;
  localparam logic [1:0] OP_RDX  = 2'd1;
  localparam logic [1:0] OP_UPGR = 2'd2;

  logic [1:0] state_d;

  always_comb begin
    state_d = state_q;
    bus_req = 1'b0;
    bus_op  = OP_RD;
    wb_en   = 1'b0;

    // Snoop-side transitions (highest priority).
    if (snoop_valid) begin
      unique case (snoop_op)
        OP_RD: begin
          if (state_q == ST_M) begin
            // MESI has no Owned state; downgrade M->S and write back/supply.
            state_d = ST_S;
            wb_en   = 1'b1;
          end else if (state_q == ST_E) begin
            state_d = ST_S;
          end
        end
        OP_RDX: begin
          if (state_q != ST_I) begin
            // Invalidate on read-for-ownership by other core.
            if (state_q == ST_M) wb_en = 1'b1;
            state_d = ST_I;
          end
        end
        OP_UPGR: begin
          // Other core is upgrading S->M; any shared copies must invalidate.
          if (state_q == ST_S) begin
            state_d = ST_I;
          end
        end
        default: begin end
      endcase
    end else begin
      // CPU-side transitions.
      if (cpu_rd) begin
        if (!cpu_hit || state_q == ST_I) begin
          bus_req = 1'b1;
          bus_op  = OP_RD;
          state_d = shared_seen ? ST_S : ST_E;
        end
      end

      if (cpu_wr) begin
        if (cpu_hit && state_q == ST_E) begin
          state_d = ST_M; // silent upgrade
        end else if (cpu_hit && state_q == ST_S) begin
          bus_req = 1'b1;
          bus_op  = OP_UPGR;
          state_d = ST_M;
        end else if (!cpu_hit || state_q == ST_I) begin
          bus_req = 1'b1;
          bus_op  = OP_RDX;
          state_d = ST_M;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q <= ST_I;
    end else begin
      state_q <= state_d;
    end
  end

endmodule

