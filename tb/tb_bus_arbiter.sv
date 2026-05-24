// tb_bus_arbiter.sv
// Unit testbench for bus_arbiter.
// Tests: round-robin grant, BusRD fill from L2, BusRDX fill, BusUpgr (no fill),
//        dirty intervention (snoop_dirty → fills from snoop_data), BusWB.

`timescale 1ns/1ps

module tb_bus_arbiter;

  localparam int LINE_WORDS = 4;
  localparam int WORD_W     = 32;
  localparam int LINE_W     = LINE_WORDS * WORD_W;
  localparam int L2_LATENCY = 2;  // short for TB speed

  logic clk = 0;
  always #5 clk = ~clk;

  logic rst_n;

  // L1_0 interface
  logic               l0_req, l0_gnt, l0_ack;
  logic [1:0]         l0_op;
  logic [31:0]        l0_addr;
  logic [LINE_W-1:0]  l0_wdata, l0_rdata;
  logic               l0_shared;

  // L1_1 interface
  logic               l1_req, l1_gnt, l1_ack;
  logic [1:0]         l1_op;
  logic [31:0]        l1_addr;
  logic [LINE_W-1:0]  l1_wdata, l1_rdata;
  logic               l1_shared;

  // Snoop 0
  logic               snoop0_valid, snoop0_hit, snoop0_dirty;
  logic [1:0]         snoop0_op;
  logic [31:0]        snoop0_addr;
  logic [LINE_W-1:0]  snoop0_data;

  // Snoop 1
  logic               snoop1_valid, snoop1_hit, snoop1_dirty;
  logic [1:0]         snoop1_op;
  logic [31:0]        snoop1_addr;
  logic [LINE_W-1:0]  snoop1_data;

  // L2 model
  logic               l2_rd, l2_wr;
  logic [7:0]         l2_addr;
  logic [LINE_W-1:0]  l2_wdata, l2_rdata;

  bus_arbiter #(
    .LINE_WORDS (LINE_WORDS),
    .WORD_W     (WORD_W),
    .L2_LATENCY (L2_LATENCY),
    .OFF_BITS   (4)
  ) dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .l0_req       (l0_req),  .l0_op  (l0_op),  .l0_addr (l0_addr),
    .l0_wdata     (l0_wdata),.l0_gnt (l0_gnt), .l0_ack  (l0_ack),
    .l0_rdata     (l0_rdata),.l0_shared(l0_shared),
    .l1_req       (l1_req),  .l1_op  (l1_op),  .l1_addr (l1_addr),
    .l1_wdata     (l1_wdata),.l1_gnt (l1_gnt), .l1_ack  (l1_ack),
    .l1_rdata     (l1_rdata),.l1_shared(l1_shared),
    .snoop0_valid (snoop0_valid), .snoop0_op(snoop0_op), .snoop0_addr(snoop0_addr),
    .snoop0_hit   (snoop0_hit),   .snoop0_dirty(snoop0_dirty), .snoop0_data(snoop0_data),
    .snoop1_valid (snoop1_valid), .snoop1_op(snoop1_op), .snoop1_addr(snoop1_addr),
    .snoop1_hit   (snoop1_hit),   .snoop1_dirty(snoop1_dirty), .snoop1_data(snoop1_data),
    .l2_rd        (l2_rd),  .l2_wr(l2_wr), .l2_addr(l2_addr),
    .l2_wdata     (l2_wdata), .l2_rdata(l2_rdata),
    .stat_bus_rd  (), .stat_bus_rdx(), .stat_bus_upgr(), .stat_bus_wb()
  );

  // Simple L2 model (behavioral)
  logic [LINE_W-1:0] l2_mem [0:255];
  always_ff @(posedge clk) begin
    if (l2_wr) l2_mem[l2_addr] <= l2_wdata;
    if (l2_rd) l2_rdata        <= l2_mem[l2_addr];
  end

  task automatic tick;
    @(posedge clk); #1ps;
  endtask

  task automatic wait_ack0(input int max);
    begin : w0
      for (int i = 0; i < max; i++) begin
        if (l0_ack) break;
        tick();
      end
      if (!l0_ack) $fatal(1, "l0_ack timeout");
    end
  endtask

  task automatic wait_ack1(input int max);
    begin : w1
      for (int i = 0; i < max; i++) begin
        if (l1_ack) break;
        tick();
      end
      if (!l1_ack) $fatal(1, "l1_ack timeout");
    end
  endtask

  integer pass_count = 0, fail_count = 0;
  task automatic check(input string name, input logic cond);
    if (cond) begin $display("  PASS: %s", name); pass_count++; end
    else begin      $display("  FAIL: %s", name); fail_count++; end
  endtask

  // Bus op encoding
  localparam logic [1:0] OP_RD   = 2'd0;
  localparam logic [1:0] OP_RDX  = 2'd1;
  localparam logic [1:0] OP_UPGR = 2'd2;
  localparam logic [1:0] OP_WB   = 2'd3;

  initial begin
    rst_n = 0;
    l0_req = 0; l0_op = OP_RD; l0_addr = 0; l0_wdata = 0;
    l1_req = 0; l1_op = OP_RD; l1_addr = 0; l1_wdata = 0;
    snoop0_hit = 0; snoop0_dirty = 0; snoop0_data = 0;
    snoop1_hit = 0; snoop1_dirty = 0; snoop1_data = 0;

    // Pre-load L2 with known data
    for (int i = 0; i < 256; i++) l2_mem[i] = {4{32'(i)}};

    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(2) tick();

    $display("=== tb_bus_arbiter: Starting tests ===");

    // ── Test: Single L0 BusRD request ──────────────────────────────────
    $display("\n--- BusRD from L0 (no snoop hit) ---");
    l0_req = 1; l0_op = OP_RD; l0_addr = 32'h100; // set4, line_addr=0x10=16
    snoop1_hit = 0; snoop1_dirty = 0;  // L1 has no copy
    wait_ack0(50);
    l0_req = 0;
    check("L0 BusRD: ack received",   l0_ack == 1'b1);
    check("L0 BusRD: shared=0 (E)",   l0_shared == 1'b0);
    check("L0 BusRD: data from L2",   l0_rdata == l2_mem[8'h10]);
    tick();

    // ── Test: Single L1 BusRDX request ─────────────────────────────────
    $display("\n--- BusRDX from L1 (no snoop hit) ---");
    l1_req = 1; l1_op = OP_RDX; l1_addr = 32'h200;
    snoop0_hit = 0; snoop0_dirty = 0;
    wait_ack1(50);
    l1_req = 0;
    check("L1 BusRDX: ack received",  l1_ack == 1'b1);
    check("L1 BusRDX: shared=0 (M)",  l1_shared == 1'b0);
    tick();

    // ── Test: BusRD with dirty snoop (intervention) ─────────────────────
    $display("\n--- BusRD with dirty intervention (L1 snoops, dirty) ---");
    begin : dirty_int
      logic [LINE_W-1:0] int_data = {4{32'hDEAD_BEEF}};
      l0_req = 1; l0_op = OP_RD; l0_addr = 32'h300;
      // L1 reports dirty copy
      snoop1_hit = 1; snoop1_dirty = 1; snoop1_data = int_data;
      wait_ack0(50);
      l0_req = 0;
      snoop1_hit = 0; snoop1_dirty = 0;
      check("Dirty intervention: ack",     l0_ack == 1'b1);
      check("Dirty intervention: shared",  l0_shared == 1'b1); // both → S
      check("Dirty intervention: data",    l0_rdata == int_data);
      tick();
    end

    // ── Test: BusRD with shared snoop (E→S downgrade) ──────────────────
    $display("\n--- BusRD with shared snoop (E→S) ---");
    l0_req = 1; l0_op = OP_RD; l0_addr = 32'h400;
    snoop1_hit = 1; snoop1_dirty = 0; // L1 has clean copy
    wait_ack0(50);
    l0_req = 0;
    snoop1_hit = 0;
    check("Shared snoop: ack",    l0_ack == 1'b1);
    check("Shared snoop: shared", l0_shared == 1'b1);
    tick();

    // ── Test: BusUpgr (no data) ─────────────────────────────────────────
    $display("\n--- BusUpgr from L0 ---");
    l0_req = 1; l0_op = OP_UPGR; l0_addr = 32'h500;
    snoop1_hit = 1; snoop1_dirty = 0; // L1 has shared copy, will invalidate
    wait_ack0(50);
    l0_req = 0;
    snoop1_hit = 0;
    check("BusUpgr: ack", l0_ack == 1'b1);
    tick();

    // ── Test: BusWB from L1 ─────────────────────────────────────────────
    $display("\n--- BusWB from L1 (dirty eviction) ---");
    l1_req = 1; l1_op = OP_WB; l1_addr = 32'h600;
    l1_wdata = {4{32'hC0DE_C0DE}};
    wait_ack1(50);
    l1_req = 0;
    check("BusWB: ack", l1_ack == 1'b1);
    tick();

    // ── Test: Round-robin fairness (both request simultaneously) ─────────
    $display("\n--- Round-robin: both request simultaneously ---");
    begin : rr_test
      logic got0, got1;
      got0 = 0; got1 = 0;
      l0_req = 1; l0_op = OP_RD; l0_addr = 32'h700;
      l1_req = 1; l1_op = OP_RD; l1_addr = 32'h800;
      snoop0_hit = 0; snoop1_hit = 0;

      // Wait for both to complete
      begin : rr_wait
        int t;
        for (t = 0; t < 100; t++) begin
          if (l0_ack) begin got0 = 1; l0_req = 0; end
          if (l1_ack) begin got1 = 1; l1_req = 0; end
          if (got0 && got1) break;
          tick();
        end
      end
      check("RR: L0 got ack", got0);
      check("RR: L1 got ack", got1);
    end

    $display("\n=== tb_bus_arbiter RESULTS: PASS=%0d FAIL=%0d ===",
             pass_count, fail_count);
    if (fail_count == 0) $display("tb_bus_arbiter: PASS");
    else                 $display("tb_bus_arbiter: FAIL");
    $finish;
  end

  initial begin #50000; $fatal(1, "[TB_ARB] Watchdog timeout"); end

endmodule
