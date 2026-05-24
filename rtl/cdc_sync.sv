// 2-FF synchronizer (reference).
`timescale 1ns/1ps

module cdc_sync (
  input  logic clk_dst,
  input  logic rst_n_dst,
  input  logic sig_src,
  output logic sig_dst
);
  logic ff1, ff2;

  always_ff @(posedge clk_dst) begin
    if (!rst_n_dst) begin
      ff1 <= 1'b0;
      ff2 <= 1'b0;
    end else begin
      ff1 <= sig_src;
      ff2 <= ff1;
    end
  end

  assign sig_dst = ff2;
endmodule

