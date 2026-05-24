// Shared inclusive L2 cache (reference skeleton).
//
// For interview/readme completeness this is a synthesizable SRAM-style model,
// but not wired into a full system here.
`timescale 1ns/1ps

module l2_cache #(
  parameter int LINE_WORDS = 4,
  parameter int NUM_LINES  = 256,
  parameter int WORD_W     = 32,
  localparam int ADDR_W    = $clog2(NUM_LINES)
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 rd_en,
  input  logic                 wr_en,
  input  logic [ADDR_W-1:0]    line_addr,
  input  logic [LINE_WORDS*WORD_W-1:0] wr_data,
  output logic [LINE_WORDS*WORD_W-1:0] rd_data
);
  logic [LINE_WORDS*WORD_W-1:0] mem [0:NUM_LINES-1];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_data <= '0;
    end else begin
      if (wr_en) mem[line_addr] <= wr_data;
      if (rd_en) rd_data <= mem[line_addr];
    end
  end
endmodule

