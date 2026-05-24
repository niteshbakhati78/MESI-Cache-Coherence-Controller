// tb_coherence_system.sv
// System testbench for the full 2-core MESI coherence system.
// Exercises all 6 coherence scenarios from the Project Completion Guide.
//
// Tests:
//   3.1  Concurrent Read — Both cores → Shared
//   3.2  Producer-Consumer — Write then Read, correct data transfer
//   3.3  Write Invalidate — Shared → Invalid on other core
//   3.4  Modified Intervention — M state writeback and downgrade
//   3.5  Upgrade Race — Simultaneous write attempt, arbiter serializes
//   3.6  False Sharing — Ping-pong, correct data throughout
//
// Performance counters and bus transaction counts are displayed at end.

`timescale 1ns/1ps

module tb_coherence_system;

  // ── Parameters ──────────────────────────────────────────────────────────
  localparam int NUM_SETS   = 16;
  localparam int NUM_WAYS   = 2;
  localparam int LINE_WORDS = 4;
  localparam int WORD_W     = 32;
  localparam int LINE_W     = LINE_WORDS * WORD_W;
  localparam int L2_LATENCY = 4;

  // MESI state encoding
  localparam logic [1:0] ST_I = 2'd0;
  localparam logic [1:0] ST_S = 2'd1;
  localparam logic [1:0] ST_E = 2'd2;
  localparam logic [1:0] ST_M = 2'd3;

  // ── Clock ────────────────────────────────────────────────────────────────
  logic clk = 1'b0;
  always #5 clk = ~clk;  // 100 MHz

  // ── DUT signals ──────────────────────────────────────────────────────────
  logic              rst_n;

  logic              cpu0_req, cpu0_we;
  logic [31:0]       cpu0_addr;
  logic [WORD_W-1:0] cpu0_wdata;
  logic [WORD_W-1:0] cpu0_rdata;
  logic              cpu0_ack;

  logic              cpu1_req, cpu1_we;
  logic [31:0]       cpu1_addr;
  logic [WORD_W-1:0] cpu1_wdata;
  logic [WORD_W-1:0] cpu1_rdata;
  logic              cpu1_ack;

  // ── DUT instantiation ────────────────────────────────────────────────────
  coherence_system #(
    .NUM_SETS   (NUM_SETS),
    .NUM_WAYS   (NUM_WAYS),
    .LINE_WORDS (LINE_WORDS),
    .WORD_W     (WORD_W),
    .L2_LATENCY (L2_LATENCY)
  ) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .cpu0_req  (cpu0_req),
    .cpu0_we   (cpu0_we),
    .cpu0_addr (cpu0_addr),
    .cpu0_wdata(cpu0_wdata),
    .cpu0_rdata(cpu0_rdata),
    .cpu0_ack  (cpu0_ack),
    .cpu1_req  (cpu1_req),
    .cpu1_we   (cpu1_we),
    .cpu1_addr (cpu1_addr),
    .cpu1_wdata(cpu1_wdata),
    .cpu1_rdata(cpu1_rdata),
    .cpu1_ack  (cpu1_ack)
  );

  // ── Helper: tick ─────────────────────────────────────────────────────────
  task automatic tick();
    @(posedge clk); #1ps;
  endtask

  // ── Helper: wait for ack from a core (with deadlock watchdog) ───────────
  task automatic wait_core0_ack(output logic [31:0] rdata);
    begin : wca0
      int t;
      for (t = 0; t < 200; t++) begin
        if (cpu0_ack) begin rdata = cpu0_rdata; break; end
        tick();
      end
      if (t >= 200) $fatal(1, "[TB3] Core0 ack timeout");
    end
  endtask

  task automatic wait_core1_ack(output logic [31:0] rdata);
    begin : wca1
      int t;
      for (t = 0; t < 200; t++) begin
        if (cpu1_ack) begin rdata = cpu1_rdata; break; end
        tick();
      end
      if (t >= 200) $fatal(1, "[TB3] Core1 ack timeout");
    end
  endtask

  // ── Helper: issue sequential Core0 read, wait ack ────────────────────────
  task automatic c0_read(input logic [31:0] addr, output logic [31:0] data);
    cpu0_req   = 1'b1;
    cpu0_we    = 1'b0;
    cpu0_addr  = addr;
    cpu0_wdata = '0;
    wait_core0_ack(data);
    cpu0_req = 1'b0;
    tick();
  endtask

  task automatic c1_read(input logic [31:0] addr, output logic [31:0] data);
    cpu1_req   = 1'b1;
    cpu1_we    = 1'b0;
    cpu1_addr  = addr;
    cpu1_wdata = '0;
    wait_core1_ack(data);
    cpu1_req = 1'b0;
    tick();
  endtask

  task automatic c0_write(input logic [31:0] addr, input logic [31:0] val);
    logic [31:0] dummy;
    cpu0_req   = 1'b1;
    cpu0_we    = 1'b1;
    cpu0_addr  = addr;
    cpu0_wdata = val;
    wait_core0_ack(dummy);
    cpu0_req = 1'b0;
    cpu0_we  = 1'b0;
    tick();
  endtask

  task automatic c1_write(input logic [31:0] addr, input logic [31:0] val);
    logic [31:0] dummy;
    cpu1_req   = 1'b1;
    cpu1_we    = 1'b1;
    cpu1_addr  = addr;
    cpu1_wdata = val;
    wait_core1_ack(dummy);
    cpu1_req = 1'b0;
    cpu1_we  = 1'b0;
    tick();
  endtask

  // ── Helper: get state of an address from a given L1 ─────────────────────
  // Uses hierarchical reference into DUT
  function automatic logic [1:0] get_l0_state(input logic [31:0] addr);
    logic [3:0] s;
    logic [23:0] t;
    s = addr[7:4];
    t = addr[31:8];
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (dut.l1_0.state_arr[s][w] != ST_I &&
          dut.l1_0.tag_arr[s][w]   == t)
        return dut.l1_0.state_arr[s][w];
    end
    return ST_I;
  endfunction

  function automatic logic [1:0] get_l1_state(input logic [31:0] addr);
    logic [3:0] s;
    logic [23:0] t;
    s = addr[7:4];
    t = addr[31:8];
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (dut.l1_1.state_arr[s][w] != ST_I &&
          dut.l1_1.tag_arr[s][w]   == t)
        return dut.l1_1.state_arr[s][w];
    end
    return ST_I;
  endfunction

  // ── Helper: get data word from L1 ────────────────────────────────────────
  function automatic logic [31:0] get_l0_data(input logic [31:0] addr);
    logic [3:0] s; logic [23:0] t; logic [1:0] woff;
    s = addr[7:4]; t = addr[31:8]; woff = addr[3:2];
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (dut.l1_0.state_arr[s][w] != ST_I && dut.l1_0.tag_arr[s][w] == t)
        return dut.l1_0.data_arr[s][w][woff*32 +: 32];
    end
    return 32'hX;
  endfunction

  function automatic logic [31:0] get_l1_data(input logic [31:0] addr);
    logic [3:0] s; logic [23:0] t; logic [1:0] woff;
    s = addr[7:4]; t = addr[31:8]; woff = addr[3:2];
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (dut.l1_1.state_arr[s][w] != ST_I && dut.l1_1.tag_arr[s][w] == t)
        return dut.l1_1.data_arr[s][w][woff*32 +: 32];
    end
    return 32'hX;
  endfunction

  // ── Test tracking ─────────────────────────────────────────────────────────
  integer pass_count = 0;
  integer fail_count = 0;
  integer total_bus_transactions = 0;

  task automatic check(input string name, input logic cond);
    if (cond) begin
      $display("  PASS: %s", name);
      pass_count++;
    end else begin
      $display("  FAIL: %s  (at time %0t)", name, $time);
      fail_count++;
    end
  endtask

  // ── Log file for golden model comparison ─────────────────────────────────
  integer log_fd;

  task automatic log_event(
    input string  core_str,
    input string  op_str,
    input logic [31:0] addr,
    input logic [1:0]  prev_st,
    input logic [1:0]  curr_st
  );
    $fwrite(log_fd, "%0t ADDR=%h CORE=%s OP=%s STATE=%0d->%0d\n",
            $time, addr, core_str, op_str, prev_st, curr_st);
  endtask

  // ── Main simulation ──────────────────────────────────────────────────────
  logic [31:0] r0, r1;
  logic [1:0]  s0, s1;

  initial begin
    // Open log file
    log_fd = $fopen("sim_output.log", "w");
    if (log_fd == 0) $display("[TB] Warning: could not open sim_output.log");

    // Reset
    rst_n     = 1'b0;
    cpu0_req  = 1'b0; cpu0_we = 1'b0; cpu0_addr = '0; cpu0_wdata = '0;
    cpu1_req  = 1'b0; cpu1_we = 1'b0; cpu1_addr = '0; cpu1_wdata = '0;
    repeat(4) tick();
    rst_n = 1'b1;
    repeat(2) tick();

    $display("=== tb_coherence_system: Starting tests ===");

    // ────────────────────────────────────────────────────────────────────
    // Test 3.1 — Concurrent Read: Both caches → Shared
    // ────────────────────────────────────────────────────────────────────
    $display("\n--- Test 3.1: Concurrent Read → Shared ---");
    begin : t31
      localparam logic [31:0] A31 = 32'h0100;

      // Core 0 reads → E (no sharer yet)
      c0_read(A31, r0);
      s0 = get_l0_state(A31);
      check("3.1 Core0 read→E (no sharer)", s0 == ST_E);

      // Core 1 reads same address → both become S
      c1_read(A31, r1);
      s0 = get_l0_state(A31);
      s1 = get_l1_state(A31);
      check("3.1 Core0 downgrades E→S", s0 == ST_S);
      check("3.1 Core1 gets Shared",    s1 == ST_S);
      check("3.1 Data matches",         r0 == r1);
    end

    // ────────────────────────────────────────────────────────────────────
    // Test 3.2 — Producer-Consumer: Write then Read
    // ────────────────────────────────────────────────────────────────────
    $display("\n--- Test 3.2: Producer-Consumer ---");
    begin : t32
      localparam logic [31:0] A32 = 32'h0200;
      localparam logic [31:0] MAGIC = 32'hDEAD_BEEF;

      // Core 0 writes
      c0_write(A32, MAGIC);
      s0 = get_l0_state(A32);
      check("3.2 Core0 write → M",    s0 == ST_M);
      check("3.2 Core1 sees Invalid", get_l1_state(A32) == ST_I);

      // Core 1 reads → gets latest data, Core0 downgrades M→S
      c1_read(A32, r1);
      check("3.2 Core1 reads 0xDEADBEEF", r1 == MAGIC);
      check("3.2 Core0 M→S after BusRD",  get_l0_state(A32) == ST_S);
      check("3.2 Core1 state = Shared",    get_l1_state(A32) == ST_S);
    end

    // ────────────────────────────────────────────────────────────────────
    // Test 3.3 — Write Invalidate: Shared → Invalid
    // ────────────────────────────────────────────────────────────────────
    $display("\n--- Test 3.3: Write Invalidate S→I ---");
    begin : t33
      localparam logic [31:0] A33 = 32'h0300;

      // Both cores read → Shared
      c0_read(A33, r0);
      c1_read(A33, r1);
      check("3.3 setup: Core0 in S", get_l0_state(A33) == ST_S);
      check("3.3 setup: Core1 in S", get_l1_state(A33) == ST_S);

      // Core 0 writes → BusUpgr, Core1 goes Invalid
      c0_write(A33, 32'hC0DE_1234);
      s0 = get_l0_state(A33);
      s1 = get_l1_state(A33);
      check("3.3 Core0 → Modified",  s0 == ST_M);
      check("3.3 Core1 → Invalid",   s1 == ST_I);
    end

    // ────────────────────────────────────────────────────────────────────
    // Test 3.4 — Modified Intervention: M→S writeback
    // ────────────────────────────────────────────────────────────────────
    $display("\n--- Test 3.4: Modified Intervention ---");
    begin : t34
      localparam logic [31:0] A34 = 32'h0400;
      localparam logic [31:0] WR_VAL = 32'hABCD_EF01;

      // Core 0 writes → M
      c0_write(A34, WR_VAL);
      check("3.4 Core0 holds Modified", get_l0_state(A34) == ST_M);

      // Core 1 reads → intervention: Core0 M→S, Core1 gets S with correct data
      c1_read(A34, r1);
      s0 = get_l0_state(A34);
      s1 = get_l1_state(A34);
      check("3.4 Core0 downgrades M→S",      s0 == ST_S);
      check("3.4 Core1 gets Shared",          s1 == ST_S);
      check("3.4 Core1 receives correct data", r1 == WR_VAL);
    end

    // ────────────────────────────────────────────────────────────────────
    // Test 3.5 — Upgrade Race: Both cores try to write Shared line
    // ────────────────────────────────────────────────────────────────────
    $display("\n--- Test 3.5: Upgrade Race ---");
    begin : t35
      localparam logic [31:0] A35 = 32'h0500;

      // Setup: both cores in Shared
      c0_read(A35, r0);
      c1_read(A35, r1);
      check("3.5 setup: both Shared",
            (get_l0_state(A35) == ST_S) && (get_l1_state(A35) == ST_S));

      // Both cores attempt to write simultaneously
      // TB issues them back-to-back (serial in TB, but bus arbiter serializes)
      fork
        c0_write(A35, 32'hC0_C0_C0_C0);
        c1_write(A35, 32'hC1_C1_C1_C1);
      join

      s0 = get_l0_state(A35);
      s1 = get_l1_state(A35);
      // After both complete, exactly one core holds M, the other fetched again
      // The final winner holds M; both should have consistent data
      // Key invariant: no dual-Modified
      check("3.5 no dual-Modified",
            !((s0 == ST_M) && (s1 == ST_M)));
      check("3.5 at least one core got Modified",
            (s0 == ST_M) || (s1 == ST_M));
      $display("  INFO: Core0=%0d Core1=%0d (0=I,1=S,2=E,3=M)", s0, s1);
    end

    // ────────────────────────────────────────────────────────────────────
    // Test 3.6 — False Sharing: 10 alternating writes to same line
    // ────────────────────────────────────────────────────────────────────
    $display("\n--- Test 3.6: False Sharing (10 iterations) ---");
    begin : t36
      // Core0 writes word0 (addr+0), Core1 writes word1 (addr+4)
      // Same cache line → ping-pong invalidations
      localparam logic [31:0] BASE = 32'h0600;
      localparam logic [31:0] WORD0 = BASE + 0;  // byte address, word offset 0
      localparam logic [31:0] WORD1 = BASE + 4;  // word offset 1 (same line)
      logic [31:0] final0, final1;
      integer bus_rd_before, bus_rdx_before;

      // Capture bus transaction counts before
      bus_rd_before  = 0; // we don't have direct access here
      bus_rdx_before = 0;

      // 10 alternating writes
      for (int i = 0; i < 10; i++) begin
        c0_write(WORD0, 32'(i * 100));
        c1_write(WORD1, 32'(i * 200));
      end

      // Final reads to verify data correctness
      c0_read(WORD0, final0);
      c1_read(WORD1, final1);

      check("3.6 final word0 correct", final0 == 32'(9 * 100));
      check("3.6 final word1 correct", final1 == 32'(9 * 200));
      $display("  INFO: final_word0=%0h final_word1=%0h", final0, final1);

      // Verify both can read each other's data
      c0_read(WORD1, r0);
      c1_read(WORD0, r1);
      check("3.6 Core0 sees Core1 data", r0 == 32'(9 * 200));
      check("3.6 Core1 sees Core0 data", r1 == 32'(9 * 100));
    end

    // ── Performance summary ───────────────────────────────────────────────
    $display("\n=== PERFORMANCE RESULTS (from arbiter stats) ===");
    $display("BusRD   transactions: %0d", dut.arb.stat_bus_rd);
    $display("BusRDX  transactions: %0d", dut.arb.stat_bus_rdx);
    $display("BusUpgr transactions: %0d", dut.arb.stat_bus_upgr);
    $display("BusWB   transactions: %0d", dut.arb.stat_bus_wb);
    $display("Total bus transactions: %0d",
             dut.arb.stat_bus_rd + dut.arb.stat_bus_rdx +
             dut.arb.stat_bus_upgr + dut.arb.stat_bus_wb);

    // Log latency counters from L1s
    $display("\n=== HIT RATE ===");
    $display("Core0: hits=%0d misses=%0d", dut.l1_0.stat_hits, dut.l1_0.stat_misses);
    $display("Core1: hits=%0d misses=%0d", dut.l1_1.stat_hits, dut.l1_1.stat_misses);

    // ── Test summary ──────────────────────────────────────────────────────
    $display("\n=== tb_coherence_system RESULTS ===");
    $display("PASS: %0d / FAIL: %0d", pass_count, fail_count);
    if (fail_count == 0)
      $display("tb_coherence_system: ALL TESTS PASS");
    else
      $display("tb_coherence_system: %0d TEST(S) FAILED", fail_count);

    if (log_fd != 0) $fclose(log_fd);
    $finish;
  end

  // ── Deadlock watchdog ─────────────────────────────────────────────────────
  initial begin
    #500000;
    $fatal(1, "[TB3] Watchdog timeout after 500us — possible deadlock");
  end

endmodule
