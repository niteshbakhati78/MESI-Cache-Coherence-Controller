// tb_l1_cache.sv
// Unit testbench for l1_cache_controller — Tests 2.1 through 2.7.
// This TB acts as the bus arbiter: it drives bus_ack, bus_rdata, bus_shared
// in response to bus_req from the DUT.
//
// Tests:
//   2.1  Read miss → Exclusive state
//   2.2  Read hit (Exclusive state) — no bus transaction
//   2.3  Write hit from Exclusive → Modified
//   2.4  Write hit from Shared → Modified (BusUpgr)
//   2.5  Write miss from Invalid → Modified (BusReadX)
//   2.6  Clean eviction (Exclusive line evicted, no writeback)
//   2.7  Dirty eviction (Modified line evicted → BusWB)

`timescale 1ns/1ps

module tb_l1_cache;

  // ── Parameters ─────────────────────────────────────────────────────────
  localparam int NUM_SETS   = 16;
  localparam int NUM_WAYS   = 2;
  localparam int LINE_WORDS = 4;
  localparam int WORD_W     = 32;
  localparam int LINE_W     = LINE_WORDS * WORD_W;

  // Address layout (NUM_SETS=16, LINE_WORDS=4, WORD_W=32)
  //   [1:0] byte offset, [3:2] word offset, [7:4] set index, [31:8] tag
  localparam int OFF_BITS  = 4;  // clog2(16 bytes)
  localparam int SET_BITS  = 4;  // clog2(16 sets)
  localparam int TAG_BITS  = 24; // 32-4-4

  // MESI state encoding
  localparam logic [1:0] ST_I = 2'd0;
  localparam logic [1:0] ST_S = 2'd1;
  localparam logic [1:0] ST_E = 2'd2;
  localparam logic [1:0] ST_M = 2'd3;

  // Bus op encoding
  localparam logic [1:0] OP_RD   = 2'd0;
  localparam logic [1:0] OP_RDX  = 2'd1;
  localparam logic [1:0] OP_UPGR = 2'd2;
  localparam logic [1:0] OP_WB   = 2'd3;

  // ── Clock ──────────────────────────────────────────────────────────────
  logic clk = 1'b0;
  always #5 clk = ~clk;  // 100 MHz

  // ── DUT signals ────────────────────────────────────────────────────────
  logic              rst_n;
  logic              cpu_req, cpu_we;
  logic [31:0]       cpu_addr;
  logic [WORD_W-1:0] cpu_wdata;
  logic [WORD_W-1:0] cpu_rdata;
  logic              cpu_ack;

  logic                bus_ack;
  logic [LINE_W-1:0]   bus_rdata;
  logic                bus_shared;
  logic                bus_req;
  logic [1:0]          bus_op;
  logic [31:0]         bus_addr_out;
  logic [LINE_W-1:0]   bus_wdata_out;

  logic              snoop_valid;
  logic [1:0]        snoop_op;
  logic [31:0]       snoop_addr;
  logic              snoop_hit;
  logic              snoop_dirty;
  logic [LINE_W-1:0] snoop_data;

  logic [1:0]  dbg_state [0:NUM_SETS-1][0:NUM_WAYS-1];
  logic [31:0] dbg_tag   [0:NUM_SETS-1][0:NUM_WAYS-1];

  // ── DUT instantiation ──────────────────────────────────────────────────
  l1_cache_controller #(
    .CACHE_ID   (0),
    .NUM_SETS   (NUM_SETS),
    .NUM_WAYS   (NUM_WAYS),
    .LINE_WORDS (LINE_WORDS),
    .WORD_W     (WORD_W)
  ) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .cpu_req    (cpu_req),
    .cpu_we     (cpu_we),
    .cpu_addr   (cpu_addr),
    .cpu_wdata  (cpu_wdata),
    .cpu_rdata  (cpu_rdata),
    .cpu_ack    (cpu_ack),
    .bus_ack    (bus_ack),
    .bus_rdata  (bus_rdata),
    .bus_shared (bus_shared),
    .bus_req    (bus_req),
    .bus_op     (bus_op),
    .bus_addr   (bus_addr_out),
    .bus_wdata  (bus_wdata_out),
    .snoop_valid(snoop_valid),
    .snoop_op   (snoop_op),
    .snoop_addr (snoop_addr),
    .snoop_hit  (snoop_hit),
    .snoop_dirty(snoop_dirty),
    .snoop_data (snoop_data),
    .stat_hits  (),
    .stat_misses(),
    .dbg_state  (dbg_state),
    .dbg_tag    (dbg_tag)
  );

  // ── Helper tasks ───────────────────────────────────────────────────────

  // Advance one clock cycle, sample outputs after edge
  task automatic tick();
    @(posedge clk);
    #1ps;
  endtask

  // Wait up to MAX_WAIT cycles for cpu_ack, returns 1 if seen
  task automatic wait_ack(input int max_wait, output logic got_ack);
    got_ack = 1'b0;
    for (int i = 0; i < max_wait; i++) begin
      tick();
      if (cpu_ack) begin got_ack = 1'b1; break; end
    end
  endtask

  // Simulate bus arbiter: respond to bus_req with fill data
  // op_expected: expected bus op; fill_data: line to return
  task automatic bus_respond(
    input logic [1:0]     op_expected,
    input logic [LINE_W-1:0] fill,
    input logic           shared_flag
  );
    // Wait for bus_req to be asserted
    begin : wait_bus
      int t;
      for (t = 0; t < 100; t++) begin
        if (bus_req) break;
        tick();
      end
      if (!bus_req)
        $fatal(1, "[TB] Timeout waiting for bus_req");
    end

    if (bus_op !== op_expected)
      $error("[TB] bus_op mismatch: expected %0d, got %0d", op_expected, bus_op);

    // For WB: just ack (no data returned)
    // For others: ack with fill data
    bus_rdata  = fill;
    bus_shared = shared_flag;
    bus_ack    = 1'b1;
    tick();
    bus_ack    = 1'b0;
    bus_rdata  = '0;
    bus_shared = 1'b0;
  endtask

  // Inject a snoop to the DUT
  task automatic do_snoop(
    input logic [1:0]  op,
    input logic [31:0] addr
  );
    snoop_valid = 1'b1;
    snoop_op    = op;
    snoop_addr  = addr;
    tick();
    snoop_valid = 1'b0;
  endtask

  // Get state of a cache line by address
  function automatic logic [1:0] get_state(input logic [31:0] addr);
    logic [3:0] set_idx;
    logic [23:0] tag;
    set_idx = addr[7:4];
    tag     = addr[31:8];
    for (int w = 0; w < NUM_WAYS; w++) begin
      if (dbg_state[set_idx][w] != ST_I &&
          dbg_tag[set_idx][w][TAG_BITS-1:0] == tag)
        return dbg_state[set_idx][w];
    end
    return ST_I;
  endfunction

  // Issue a CPU read and wait for ack
  task automatic cpu_read(input logic [31:0] addr, output logic [31:0] data);
    cpu_req   = 1'b1;
    cpu_we    = 1'b0;
    cpu_addr  = addr;
    cpu_wdata = '0;
    begin : wait_read_ack
      logic got;
      wait_ack(50, got);
      if (!got) $fatal(1, "[TB] cpu_read: timeout");
    end
    data    = cpu_rdata;
    cpu_req = 1'b0;
    tick();
  endtask

  // Issue a CPU write and wait for ack
  task automatic cpu_write(input logic [31:0] addr, input logic [31:0] data);
    cpu_req   = 1'b1;
    cpu_we    = 1'b1;
    cpu_addr  = addr;
    cpu_wdata = data;
    begin : wait_write_ack
      logic got;
      wait_ack(50, got);
      if (!got) $fatal(1, "[TB] cpu_write: timeout");
    end
    cpu_req = 1'b0;
    cpu_we  = 1'b0;
    tick();
  endtask

  // ── Test runner ────────────────────────────────────────────────────────
  integer pass_count = 0;
  integer fail_count = 0;

  task automatic check(input string name, input logic cond);
    if (cond) begin
      $display("  PASS: %s", name);
      pass_count++;
    end else begin
      $display("  FAIL: %s", name);
      fail_count++;
    end
  endtask

  // ── Main test sequence ─────────────────────────────────────────────────
  // Addresses: set 0 = addr[7:4]=0 → addr 0x000, 0x010, 0x020 ... (16-byte lines)
  // Addr 0x100 → set=(0x100>>4)%16 = (0x10)%16 = 0, tag=0x10
  // Addr 0x200 → set=(0x200>>4)%16 = (0x20)%16 = 0, tag=0x20
  // Addr 0x300 → set=(0x300>>4)%16 = (0x30)%16 = 0, tag=0x30
  //   (same set as 0x100 and 0x200, forces eviction on 2-way)

  localparam logic [31:0] ADDR_A = 32'h100; // set 0, tag 0x10
  localparam logic [31:0] ADDR_B = 32'h200; // set 0, tag 0x20
  localparam logic [31:0] ADDR_C = 32'h300; // set 0, tag 0x30 (causes eviction)

  // Fill data: recognizable pattern
  localparam logic [LINE_W-1:0] DATA_A = {4{32'hAAAA_0000}};
  localparam logic [LINE_W-1:0] DATA_B = {4{32'hBBBB_0000}};
  localparam logic [LINE_W-1:0] DATA_C = {4{32'hCCCC_0000}};

  logic [31:0] rdata_tmp;
  logic [1:0]  state_tmp;
  logic        bus_req_seen;

  initial begin
    // Initial signal state
    rst_n       = 1'b0;
    cpu_req     = 1'b0;
    cpu_we      = 1'b0;
    cpu_addr    = '0;
    cpu_wdata   = '0;
    bus_ack     = 1'b0;
    bus_rdata   = '0;
    bus_shared  = 1'b0;
    snoop_valid = 1'b0;
    snoop_op    = '0;
    snoop_addr  = '0;

    repeat(4) tick();
    rst_n = 1'b1;
    repeat(2) tick();

    $display("=== tb_l1_cache: Starting tests ===");

    // ── Test 2.1: Read miss → Exclusive ────────────────────────────────
    $display("\n--- Test 2.1: Read miss → Exclusive ---");
    fork
      cpu_read(ADDR_A, rdata_tmp);
      bus_respond(OP_RD, DATA_A, 1'b0);  // no shared copy → Exclusive
    join
    state_tmp = get_state(ADDR_A);
    check("2.1 state == EXCLUSIVE", state_tmp == ST_E);
    check("2.1 data word0 correct", rdata_tmp == DATA_A[31:0]);

    // ── Test 2.2: Read hit (Exclusive) — no bus transaction ─────────────
    $display("\n--- Test 2.2: Read hit from Exclusive ---");
    bus_req_seen = 1'b0;
    cpu_req  = 1'b1;
    cpu_we   = 1'b0;
    cpu_addr = ADDR_A;
    @(posedge clk); #1ps;
    // Monitor bus_req for 5 cycles; should never go high
    repeat(5) begin
      if (bus_req) bus_req_seen = 1'b1;
      @(posedge clk); #1ps;
    end
    check("2.2 no bus transaction", bus_req_seen == 1'b0);
    begin : wait_ack_2_2
      logic got;
      // Already counting cycles above; just wait for ack
      wait_ack(10, got);
      check("2.2 cpu_ack received", got == 1'b1);
    end
    cpu_req = 1'b0;
    tick();
    state_tmp = get_state(ADDR_A);
    check("2.2 state still EXCLUSIVE", state_tmp == ST_E);

    // ── Test 2.3: Write hit from Exclusive → Modified ───────────────────
    $display("\n--- Test 2.3: Write hit E→M ---");
    bus_req_seen = 1'b0;
    fork
      begin
        cpu_req   = 1'b1;
        cpu_we    = 1'b1;
        cpu_addr  = ADDR_A;
        cpu_wdata = 32'hDEAD_BEEF;
        begin : wait_23
          logic got;
          wait_ack(50, got);
          check("2.3 cpu_ack received", got);
        end
        cpu_req = 1'b0;
        cpu_we  = 1'b0;
        tick();
      end
      begin
        // Watch for bus_req — should NOT occur for E→M
        repeat(20) begin
          @(posedge clk); #1ps;
          if (bus_req) bus_req_seen = 1'b1;
        end
      end
    join
    state_tmp = get_state(ADDR_A);
    check("2.3 no bus transaction", bus_req_seen == 1'b0);
    check("2.3 state == MODIFIED", state_tmp == ST_M);

    // ── Test 2.4: Write hit from Shared → Modified (BusUpgr) ────────────
    $display("\n--- Test 2.4: Write hit S→M (BusUpgr) ---");
    // Force cache line at ADDR_A to Shared state via snoop
    // (It's currently Modified; inject BusRD snoop to downgrade to Shared)
    do_snoop(OP_RD, ADDR_A);
    state_tmp = get_state(ADDR_A);
    check("2.4 setup: state is SHARED after snoop", state_tmp == ST_S);

    fork
      begin
        cpu_req   = 1'b1;
        cpu_we    = 1'b1;
        cpu_addr  = ADDR_A;
        cpu_wdata = 32'hCAFE_BABE;
        begin : wait_24
          logic got;
          wait_ack(50, got);
          check("2.4 cpu_ack received", got);
        end
        cpu_req = 1'b0;
        cpu_we  = 1'b0;
        tick();
      end
      begin
        // Expect BUS_UPGR
        begin : wait_req_24
          int t;
          for (t = 0; t < 30; t++) begin
            @(posedge clk); #1ps;
            if (bus_req && bus_op == OP_UPGR) break;
          end
        end
        check("2.4 BusUpgr observed", bus_req && bus_op == OP_UPGR);
        // Ack the upgrade (no fill data)
        bus_ack = 1'b1; tick(); bus_ack = 1'b0;
      end
    join
    state_tmp = get_state(ADDR_A);
    check("2.4 state == MODIFIED", state_tmp == ST_M);

    // ── Test 2.5: Write miss from Invalid → Modified (BusReadX) ─────────
    $display("\n--- Test 2.5: Write miss I→M (BusReadX) ---");
    fork
      cpu_write(ADDR_B, 32'hBEEF_CAFE);
      bus_respond(OP_RDX, DATA_B, 1'b0);  // exclusive intent
    join
    state_tmp = get_state(ADDR_B);
    check("2.5 state == MODIFIED", state_tmp == ST_M);

    // ── Test 2.6: Clean eviction (Exclusive line evicted) ─────────────
    $display("\n--- Test 2.6: Clean eviction (E state, no BusWB) ---");
    // Need a line in E state that will be evicted.
    // Bring ADDR_C into cache (same set as A&B, way 0 or 1 used)
    // First: get a fresh E line at a new address in same set
    // Currently set 0 has: ADDR_A(M) in one way, ADDR_B(M) in other way
    // Access ADDR_C → evict LRU (which was last accessed = ADDR_B, so evict ADDR_A?)
    // ADDR_A is M — will trigger dirty eviction (Test 2.7 pattern)
    // Let's use a different set to isolate Test 2.6:
    // ADDR_D = 0x110 → set 1, tag 0x11 (clean set)
    // ADDR_E = 0x210 → set 1, tag 0x21
    // ADDR_F = 0x310 → set 1, tag 0x31 (triggers eviction)
    begin : test_26
      localparam logic [31:0] ADDR_D = 32'h110;
      localparam logic [31:0] ADDR_E_t26 = 32'h210;
      localparam logic [31:0] ADDR_F = 32'h310;
      localparam logic [LINE_W-1:0] DATA_D = {4{32'hDDDD_0000}};
      localparam logic [LINE_W-1:0] DATA_E_t26 = {4{32'hEEEE_0000}};
      localparam logic [LINE_W-1:0] DATA_F = {4{32'hFFFF_0000}};
      logic [31:0] rd;
      logic seen_wb;

      // Fill ADDR_D as Exclusive
      fork
        cpu_read(ADDR_D, rd);
        bus_respond(OP_RD, DATA_D, 1'b0);  // Exclusive
      join
      check("2.6 ADDR_D initial state E", get_state(ADDR_D) == ST_E);

      // Fill ADDR_E to occupy second way
      fork
        cpu_read(ADDR_E_t26, rd);
        bus_respond(OP_RD, DATA_E_t26, 1'b0);
      join
      check("2.6 ADDR_E initial state E", get_state(ADDR_E_t26) == ST_E);

      // Now access ADDR_F (same set) → eviction of LRU (ADDR_D, which was LRU after E filled)
      // Expect: no BUS_WB (line is E/clean), then BUS_RD for ADDR_F
      seen_wb = 1'b0;
      fork
        cpu_read(ADDR_F, rd);
        begin
          // Watch for any BUS_WB (should NOT appear)
          // Then respond to expected BUS_RD
          begin : watch_wb_26
            int t;
            for (t = 0; t < 5; t++) begin
              @(posedge clk); #1ps;
              if (bus_req && bus_op == OP_WB) seen_wb = 1'b1;
            end
          end
          bus_respond(OP_RD, DATA_F, 1'b0);
        end
      join
      check("2.6 no BUS_WB on clean eviction", seen_wb == 1'b0);
      check("2.6 evicted line now INVALID", get_state(ADDR_D) == ST_I);
      check("2.6 new line ADDR_F state E", get_state(ADDR_F) == ST_E);
    end

    // ── Test 2.7: Dirty eviction (Modified state → BusWB) ───────────────
    $display("\n--- Test 2.7: Dirty eviction (M state → BusWB) ---");
    begin : test_27
      // Use set 2: ADDR_G=0x120, ADDR_H=0x220, ADDR_I=0x320
      localparam logic [31:0] ADDR_G = 32'h120;
      localparam logic [31:0] ADDR_H = 32'h220;
      localparam logic [31:0] ADDR_I_t27 = 32'h320;
      localparam logic [LINE_W-1:0] DATA_G = {4{32'h1111_2222}};
      localparam logic [LINE_W-1:0] DATA_H = {4{32'h3333_4444}};
      localparam logic [LINE_W-1:0] DATA_I_t27 = {4{32'h5555_6666}};
      logic [31:0] rd;
      logic seen_wb;

      // Write ADDR_G → M state
      fork
        cpu_write(ADDR_G, 32'hDEAD_0001);
        bus_respond(OP_RDX, DATA_G, 1'b0);
      join
      check("2.7 ADDR_G is MODIFIED", get_state(ADDR_G) == ST_M);

      // Fill ADDR_H (second way of same set)
      fork
        cpu_write(ADDR_H, 32'hDEAD_0002);
        bus_respond(OP_RDX, DATA_H, 1'b0);
      join
      check("2.7 ADDR_H is MODIFIED", get_state(ADDR_H) == ST_M);

      // Access ADDR_I → evict LRU (dirty line) → expect BUS_WB, then BUS_RD
      seen_wb = 1'b0;
      fork
        cpu_read(ADDR_I_t27, rd);
        begin
          // First bus transaction should be BUS_WB (dirty eviction)
          begin : watch_wb_27
            int t;
            for (t = 0; t < 30; t++) begin
              @(posedge clk); #1ps;
              if (bus_req && bus_op == OP_WB) begin
                seen_wb = 1'b1;
                break;
              end
            end
          end
          if (seen_wb) begin
            bus_ack = 1'b1; tick(); bus_ack = 1'b0;
          end
          // Then BUS_RD for ADDR_I
          bus_respond(OP_RD, DATA_I_t27, 1'b0);
        end
      join
      check("2.7 BUS_WB issued on dirty eviction", seen_wb == 1'b1);
      check("2.7 new line ADDR_I state E", get_state(ADDR_I_t27) == ST_E);
    end

    // ── Summary ─────────────────────────────────────────────────────────
    $display("\n=== tb_l1_cache RESULTS ===");
    $display("PASS: %0d / FAIL: %0d", pass_count, fail_count);
    if (fail_count == 0)
      $display("tb_l1_cache: ALL TESTS PASS");
    else
      $display("tb_l1_cache: %0d TEST(S) FAILED", fail_count);

    $finish;
  end

  // Watchdog
  initial begin
    #100000;
    $fatal(1, "[TB] Watchdog timeout after 100us");
  end

endmodule
