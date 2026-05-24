`timescale 1ns/1ps

module tb_mesi_fsm;
  logic clk = 0;
  always #5 clk = ~clk;

  logic rst_n;
  logic cpu_rd, cpu_wr, cpu_hit;
  logic snoop_valid;
  logic [1:0] snoop_op;
  logic shared_seen;

  logic [1:0] state_q;
  logic bus_req;
  logic [1:0] bus_op;
  logic wb_en;

  mesi_fsm dut (
    .clk(clk),
    .rst_n(rst_n),
    .cpu_rd(cpu_rd),
    .cpu_wr(cpu_wr),
    .cpu_hit(cpu_hit),
    .snoop_valid(snoop_valid),
    .snoop_op(snoop_op),
    .shared_seen(shared_seen),
    .state_q(state_q),
    .bus_req(bus_req),
    .bus_op(bus_op),
    .wb_en(wb_en)
  );

  localparam logic [1:0] OP_RD   = 2'd0;
  localparam logic [1:0] OP_RDX  = 2'd1;
  localparam logic [1:0] OP_UPGR = 2'd2;

  task automatic tick;
    @(posedge clk);
    #1ps; // avoid race with DUT nonblocking updates
  endtask

  initial begin
    rst_n = 0;
    cpu_rd = 0; cpu_wr = 0; cpu_hit = 0;
    snoop_valid = 0; snoop_op = '0; shared_seen = 0;
    repeat (2) @(posedge clk);
    rst_n = 1;

    // Read miss -> BusRd; if no sharing => E
    cpu_rd = 1; cpu_hit = 0; shared_seen = 0;
    #1ps;
    if (!bus_req || bus_op != OP_RD) $fatal(1, "Expected BusRd on read miss (pre-edge)");
    tick();
    if (state_q != 2'd2) $fatal(1, "Expected E after unshared read miss");
    cpu_rd = 0;

    // Snoop BusRd from other core -> E->S
    snoop_valid = 1; snoop_op = OP_RD;
    tick();
    if (state_q != 2'd1) $fatal(1, "Expected S after snooped BusRd");
    snoop_valid = 0;

    // Write hit in S -> BusUpgr, M
    cpu_wr = 1; cpu_hit = 1;
    #1ps;
    if (!bus_req || bus_op != OP_UPGR) $fatal(1, "Expected BusUpgr on write hit in S (pre-edge)");
    tick();
    if (state_q != 2'd3) $fatal(1, "Expected M after upgrade");
    cpu_wr = 0;

    // Snoop BusRdX from other -> invalidate (and writeback flag when M)
    snoop_valid = 1; snoop_op = OP_RDX;
    tick();
    if (state_q != 2'd0) $fatal(1, "Expected I after snooped BusRdX");
    snoop_valid = 0;

    $display("tb_mesi_fsm: PASS");
    $finish;
  end
endmodule
