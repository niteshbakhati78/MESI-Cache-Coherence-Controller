// UVM testbench package for mesi_fsm.sv.
// Contains all UVM components in dependency order:
//   seq_item → driver/monitor → scoreboard → agent → env → sequences → tests
`include "uvm_macros.svh"

package mesi_uvm_pkg;
  import uvm_pkg::*;

  typedef virtual mesi_if mesi_vif;

  // State/op encodings mirrored from the DUT
  localparam logic [1:0] ST_I    = 2'd0, ST_S = 2'd1, ST_E = 2'd2, ST_M = 2'd3;
  localparam logic [1:0] OP_RD   = 2'd0, OP_RDX = 2'd1, OP_UPGR = 2'd2;

  // ── Sequence Item ────────────────────────────────────────────────────────────
  class mesi_seq_item extends uvm_sequence_item;
    `uvm_object_utils_begin(mesi_seq_item)
      `uvm_field_int(cpu_rd,      UVM_ALL_ON)
      `uvm_field_int(cpu_wr,      UVM_ALL_ON)
      `uvm_field_int(cpu_hit,     UVM_ALL_ON)
      `uvm_field_int(snoop_valid, UVM_ALL_ON)
      `uvm_field_int(snoop_op,    UVM_ALL_ON)
      `uvm_field_int(shared_seen, UVM_ALL_ON)
      `uvm_field_int(state_q,     UVM_ALL_ON | UVM_NORAND)
      `uvm_field_int(bus_req,     UVM_ALL_ON | UVM_NORAND)
      `uvm_field_int(bus_op,      UVM_ALL_ON | UVM_NORAND)
      `uvm_field_int(wb_en,       UVM_ALL_ON | UVM_NORAND)
    `uvm_object_utils_end

    // Randomized stimulus
    rand logic       cpu_rd;
    rand logic       cpu_wr;
    rand logic       cpu_hit;
    rand logic       snoop_valid;
    rand logic [1:0] snoop_op;
    rand logic       shared_seen;

    // Response fields — filled in by the monitor
    logic [1:0] state_q;
    logic       bus_req;
    logic [1:0] bus_op;
    logic       wb_en;

    // CPU can't read and write the same line in one cycle
    constraint c_no_rw_conflict { !(cpu_rd && cpu_wr); }

    // Only issue legal snoop ops
    constraint c_valid_snoop_op { snoop_op inside {OP_RD, OP_RDX, OP_UPGR}; }

    // When a snoop is active the DUT ignores CPU inputs; avoid ambiguous stimuli
    constraint c_snoop_dominates {
      snoop_valid -> (cpu_rd == 1'b0 && cpu_wr == 1'b0);
    }

    // Bias toward CPU reads (the most common cache operation)
    constraint c_activity_bias {
      snoop_valid dist {1'b0 := 65, 1'b1 := 35};
      cpu_rd      dist {1'b0 := 30, 1'b1 := 70};
    }

    function new(string name = "mesi_seq_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf(
        "cpu_rd=%0b wr=%0b hit=%0b | snoop=%0b op=%0d | ss=%0b || state_q=%0d bus_req=%0b op=%0d wb=%0b",
        cpu_rd, cpu_wr, cpu_hit, snoop_valid, snoop_op, shared_seen,
        state_q, bus_req, bus_op, wb_en);
    endfunction
  endclass

  // ── Driver ───────────────────────────────────────────────────────────────────
  class mesi_driver extends uvm_driver #(mesi_seq_item);
    `uvm_component_utils(mesi_driver)

    mesi_vif vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db #(mesi_vif)::get(this, "", "vif", vif))
        `uvm_fatal("NO_VIF", "mesi_driver: virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
      mesi_seq_item item;
      // Hold all inputs low during reset
      vif.drv_cb.cpu_rd      <= 1'b0;
      vif.drv_cb.cpu_wr      <= 1'b0;
      vif.drv_cb.cpu_hit     <= 1'b0;
      vif.drv_cb.snoop_valid <= 1'b0;
      vif.drv_cb.snoop_op    <= 2'd0;
      vif.drv_cb.shared_seen <= 1'b0;
      @(posedge vif.rst_n); // wait for reset release

      forever begin
        seq_item_port.get_next_item(item);
        @(vif.drv_cb);
        vif.drv_cb.cpu_rd      <= item.cpu_rd;
        vif.drv_cb.cpu_wr      <= item.cpu_wr;
        vif.drv_cb.cpu_hit     <= item.cpu_hit;
        vif.drv_cb.snoop_valid <= item.snoop_valid;
        vif.drv_cb.snoop_op    <= item.snoop_op;
        vif.drv_cb.shared_seen <= item.shared_seen;
        seq_item_port.item_done();
      end
    endtask
  endclass

  // ── Monitor ──────────────────────────────────────────────────────────────────
  // Samples 1 ns before each posedge (input skew), so it sees:
  //   - state_q  : registered at this posedge from the previous cycle's inputs
  //   - bus_*/wb_: combinational outputs driven by state_q + inputs from the previous cycle
  //   - stimulus : inputs that were driven 1 ns after the previous posedge
  // This gives the scoreboard a self-consistent snapshot per cycle.
  class mesi_monitor extends uvm_monitor;
    `uvm_component_utils(mesi_monitor)

    mesi_vif vif;
    uvm_analysis_port #(mesi_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      ap = new("ap", this);
      if (!uvm_config_db #(mesi_vif)::get(this, "", "vif", vif))
        `uvm_fatal("NO_VIF", "mesi_monitor: virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
      mesi_seq_item item;
      @(posedge vif.rst_n);
      forever begin
        @(vif.mon_cb);
        item = mesi_seq_item::type_id::create("mon_item");
        item.cpu_rd      = vif.mon_cb.cpu_rd;
        item.cpu_wr      = vif.mon_cb.cpu_wr;
        item.cpu_hit     = vif.mon_cb.cpu_hit;
        item.snoop_valid = vif.mon_cb.snoop_valid;
        item.snoop_op    = vif.mon_cb.snoop_op;
        item.shared_seen = vif.mon_cb.shared_seen;
        item.state_q     = vif.mon_cb.state_q;
        item.bus_req     = vif.mon_cb.bus_req;
        item.bus_op      = vif.mon_cb.bus_op;
        item.wb_en       = vif.mon_cb.wb_en;
        ap.write(item);
      end
    endtask
  endclass

  // ── Scoreboard ───────────────────────────────────────────────────────────────
  // Maintains a cycle-accurate reference model that mirrors the DUT's always_comb.
  // On each transaction: verifies state_q matches our tracked state, checks all
  // combinational outputs, then advances the model to the next state.
  class mesi_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(mesi_scoreboard)

    uvm_analysis_imp #(mesi_seq_item, mesi_scoreboard) analysis_export;

    local logic [1:0] ref_state;
    local int unsigned pass_cnt;
    local int unsigned fail_cnt;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      analysis_export = new("analysis_export", this);
      ref_state = ST_I;
      pass_cnt  = 0;
      fail_cnt  = 0;
    endfunction

    // Exact mirror of mesi_fsm's always_comb block.
    // Pure function — no side effects on ref_state.
    function automatic void predict(
      input  logic [1:0] cur_state,
      input  logic       cpu_rd, cpu_wr, cpu_hit,
      input  logic       snoop_valid,
      input  logic [1:0] snoop_op,
      input  logic       shared_seen,
      output logic [1:0] next_state,
      output logic       exp_bus_req,
      output logic [1:0] exp_bus_op,
      output logic       exp_wb_en
    );
      next_state  = cur_state;
      exp_bus_req = 1'b0;
      exp_bus_op  = OP_RD;
      exp_wb_en   = 1'b0;

      if (snoop_valid) begin
        case (snoop_op)
          OP_RD: begin
            if (cur_state == ST_M) begin
              next_state = ST_S;
              exp_wb_en  = 1'b1;
            end else if (cur_state == ST_E)
              next_state = ST_S;
          end
          OP_RDX: begin
            if (cur_state != ST_I) begin
              if (cur_state == ST_M) exp_wb_en = 1'b1;
              next_state = ST_I;
            end
          end
          OP_UPGR: begin
            if (cur_state == ST_S) next_state = ST_I;
          end
          default: ;
        endcase
      end else begin
        if (cpu_rd) begin
          if (!cpu_hit || cur_state == ST_I) begin
            exp_bus_req = 1'b1;
            exp_bus_op  = OP_RD;
            next_state  = shared_seen ? ST_S : ST_E;
          end
        end
        if (cpu_wr) begin
          if (cpu_hit && cur_state == ST_E) begin
            next_state = ST_M;              // silent upgrade, no bus
          end else if (cpu_hit && cur_state == ST_S) begin
            exp_bus_req = 1'b1;
            exp_bus_op  = OP_UPGR;
            next_state  = ST_M;
          end else if (!cpu_hit || cur_state == ST_I) begin
            exp_bus_req = 1'b1;
            exp_bus_op  = OP_RDX;
            next_state  = ST_M;
          end
        end
      end
    endfunction

    function string state_name(logic [1:0] s);
      case (s)
        ST_I: return "I";
        ST_S: return "S";
        ST_E: return "E";
        ST_M: return "M";
        default: return "?";
      endcase
    endfunction

    function void write(mesi_seq_item item);
      logic [1:0] exp_next, exp_bus_op;
      logic       exp_bus_req, exp_wb_en;
      bit ok = 1;

      // Verify registered state matches our model before checking outputs
      if (item.state_q !== ref_state) begin
        `uvm_error("SB/STATE",
          $sformatf("state_q mismatch: DUT=%0s  REF=%0s",
            state_name(item.state_q), state_name(ref_state)))
        fail_cnt++;
        ref_state = item.state_q; // resync to avoid error avalanche
        return;
      end

      predict(ref_state,
              item.cpu_rd, item.cpu_wr, item.cpu_hit,
              item.snoop_valid, item.snoop_op, item.shared_seen,
              exp_next, exp_bus_req, exp_bus_op, exp_wb_en);

      if (item.bus_req !== exp_bus_req) begin
        `uvm_error("SB/BUS_REQ",
          $sformatf("@ state=%0s: bus_req got=%0b exp=%0b | %0s",
            state_name(ref_state), item.bus_req, exp_bus_req, item.convert2string()))
        ok = 0;
      end
      if (item.bus_req && item.bus_op !== exp_bus_op) begin
        `uvm_error("SB/BUS_OP",
          $sformatf("@ state=%0s: bus_op got=%0d exp=%0d | %0s",
            state_name(ref_state), item.bus_op, exp_bus_op, item.convert2string()))
        ok = 0;
      end
      if (item.wb_en !== exp_wb_en) begin
        `uvm_error("SB/WB_EN",
          $sformatf("@ state=%0s: wb_en got=%0b exp=%0b | %0s",
            state_name(ref_state), item.wb_en, exp_wb_en, item.convert2string()))
        ok = 0;
      end

      if (ok) pass_cnt++; else fail_cnt++;
      ref_state = exp_next;
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("SCOREBOARD",
        $sformatf("── Results: %0d PASS  %0d FAIL ──", pass_cnt, fail_cnt), UVM_NONE)
      if (fail_cnt > 0)
        `uvm_error("SCOREBOARD", "TEST FAILED")
      else
        `uvm_info("SCOREBOARD", "TEST PASSED", UVM_NONE)
    endfunction
  endclass

  // ── Agent ────────────────────────────────────────────────────────────────────
  class mesi_agent extends uvm_agent;
    `uvm_component_utils(mesi_agent)

    mesi_driver  drv;
    mesi_monitor mon;
    uvm_sequencer #(mesi_seq_item) seqr;

    uvm_analysis_port #(mesi_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      ap  = new("ap", this);
      mon = mesi_monitor::type_id::create("mon", this);
      if (is_active == UVM_ACTIVE) begin
        drv  = mesi_driver::type_id::create("drv", this);
        seqr = uvm_sequencer #(mesi_seq_item)::type_id::create("seqr", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      mon.ap.connect(ap);
      if (is_active == UVM_ACTIVE)
        drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction
  endclass

  // ── Environment ──────────────────────────────────────────────────────────────
  class mesi_env extends uvm_env;
    `uvm_component_utils(mesi_env)

    mesi_agent      agent;
    mesi_scoreboard sb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent = mesi_agent::type_id::create("agent", this);
      sb    = mesi_scoreboard::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      agent.ap.connect(sb.analysis_export);
    endfunction
  endclass

  // ── Base Sequence: 100 random transactions ────────────────────────────────────
  class mesi_random_seq extends uvm_sequence #(mesi_seq_item);
    `uvm_object_utils(mesi_random_seq)

    int unsigned num_txns = 100;

    function new(string name = "mesi_random_seq");
      super.new(name);
    endfunction

    task body();
      repeat (num_txns) begin
        mesi_seq_item item = mesi_seq_item::type_id::create("item");
        start_item(item);
        if (!item.randomize())
          `uvm_fatal("RAND_FAIL", "Randomization failed")
        finish_item(item);
      end
    endtask
  endclass

  // ── Directed Sequence: walks every canonical MESI arc ────────────────────────
  // Exercises all 9 state transitions in order, covering every arc on the
  // MESI state diagram.  Useful for directed regression and coverage closure.
  class mesi_directed_seq extends uvm_sequence #(mesi_seq_item);
    `uvm_object_utils(mesi_directed_seq)

    function new(string name = "mesi_directed_seq");
      super.new(name);
    endfunction

    // Convenience: build and send one fully-specified transaction
    task send(
      input logic rd, wr, hit, sv,
      input logic [1:0] sop,
      input logic ss
    );
      mesi_seq_item item = mesi_seq_item::type_id::create("item");
      start_item(item);
      item.cpu_rd      = rd;
      item.cpu_wr      = wr;
      item.cpu_hit     = hit;
      item.snoop_valid = sv;
      item.snoop_op    = sop;
      item.shared_seen = ss;
      finish_item(item);
    endtask

    task body();
      // Start state: I (after reset)
      // args: rd  wr  hit  sv   sop      ss(shared_seen)
      send(1, 0,  0,  0,  OP_RD,   0);  // I→E : cpu read miss, no sharers
      send(0, 1,  1,  0,  OP_RD,   0);  // E→M : cpu write hit (silent upgrade)
      send(0, 0,  0,  1,  OP_RD,   0);  // M→S : snoop BusRd (writeback + downgrade)
      send(0, 1,  1,  0,  OP_RD,   0);  // S→M : cpu write hit in S (BusUpgr)
      send(0, 0,  0,  1,  OP_RDX,  0);  // M→I : snoop BusRdX (writeback + invalidate)
      send(1, 0,  0,  0,  OP_RD,   1);  // I→S : cpu read miss, sharers present
      send(0, 0,  0,  1,  OP_RDX,  0);  // S→I : snoop BusRdX
      send(0, 0,  0,  1,  OP_UPGR, 0);  // I   : snoop BusUpgr while I (no-op)
      send(1, 0,  0,  0,  OP_RD,   1);  // I→S : cpu read miss, shared
      send(0, 0,  0,  1,  OP_UPGR, 0);  // S→I : snoop BusUpgr
    endtask
  endclass

  // ── Base Test ─────────────────────────────────────────────────────────────────
  class mesi_base_test extends uvm_test;
    `uvm_component_utils(mesi_base_test)

    mesi_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = mesi_env::type_id::create("env", this);
    endfunction

    // Derived tests override this
    virtual task run_test_body();
    endtask

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      run_test_body();
      phase.drop_objection(this);
    endtask
  endclass

  // ── Random Test ───────────────────────────────────────────────────────────────
  class mesi_random_test extends mesi_base_test;
    `uvm_component_utils(mesi_random_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_test_body();
      mesi_random_seq seq = mesi_random_seq::type_id::create("seq");
      seq.num_txns = 200;
      seq.start(env.agent.seqr);
    endtask
  endclass

  // ── Directed Test ─────────────────────────────────────────────────────────────
  class mesi_directed_test extends mesi_base_test;
    `uvm_component_utils(mesi_directed_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_test_body();
      mesi_directed_seq seq = mesi_directed_seq::type_id::create("seq");
      seq.start(env.agent.seqr);
    endtask
  endclass

endpackage
