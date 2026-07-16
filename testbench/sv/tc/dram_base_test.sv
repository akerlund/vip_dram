////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Åkerlund
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Description:
// dram_base_test
//
// Base for every vip_dram device-only test case. Builds the dram_env, installs
// the house report server / printer, and provides the request builders and the
// issue/wait helpers the test cases share. Each test overrides body(); the base
// raises/drops the run-phase objection around it.
// style).
//
////////////////////////////////////////////////////////////////////////////////

class dram_base_test extends uvm_test;

  `uvm_component_utils(dram_base_test)

  typedef vip_dram_req   #(DRAM_CFG_C)         req_t;
  typedef vip_dram_rsp   #(DRAM_CFG_C)         rsp_t;
  typedef vip_dram_types #(DRAM_CFG_C)::data_t data_t;
  typedef vip_dram_types #(DRAM_CFG_C)::strb_t strb_t;
  typedef vip_dram_types #(DRAM_CFG_C)::addr_t addr_t;

  localparam int ROW_BYTES_C = DRAM_CFG_C.ROW_BYTES_P;

  dram_env #(DRAM_CFG_C) env;

  uvm_table_printer uvm_table_printer0;
  report_server     report_server0;
  string            tc_name;

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "dram_base_test",
    input uvm_component parent = null
  );
    super.new(name, parent);
    void'($value$plusargs("UVM_TESTNAME=%s", tc_name));
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  virtual function void build_phase(
    input uvm_phase phase
  );

    super.build_phase(phase);

    report_server0 = new("report_server0");
    uvm_report_server::set_server(report_server0);

    uvm_table_printer0                     = new();
    uvm_table_printer0.knobs.depth         = 4;
    uvm_table_printer0.knobs.default_radix = UVM_HEX;

    this.env = dram_env #(DRAM_CFG_C)::type_id::create("env", this);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  virtual task body();
  endtask

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task run_phase(
    input uvm_phase phase
  );
    super.run_phase(phase);
    phase.raise_objection(this);
    this.body();
    phase.drop_objection(this);
  endtask

  // ===========================================================================
  // Request builders
  // ===========================================================================

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function addr_t addr_of(
    input int rank,
    input int bg,
    input int bank,
    input int row,
    input int col
  );
    vip_dram_dec_t d;

    d = '{rank: rank, bg: bg, bank: bank, row: row, col: col, byte_in_col: 0};
    return vip_dram_encode_addr(
      .d   ( d                       ),
      .cfg ( DRAM_CFG_C              ),
      .map ( this.env.dram.cfg.addr_map )
    );
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function data_t pattern(
    input longint unsigned seed
  );
    data_t p = '0;

    for (int b = 0; b < ROW_BYTES_C; b++) begin
      p[8*b +: 8] = (seed + b) & 8'hFF;
    end
    return p;
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function req_t mk_rd_req(
    input addr_t           addr,
    input int              beats,
    input longint unsigned tag
  );
    req_t q = req_t::type_id::create($sformatf("rd_%0h", tag));

    q.op    = VIP_DRAM_OP_RD_E;
    q.addr  = addr;
    q.beats = beats;
    q.tag   = tag;
    return q;
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function req_t mk_wr_req(
    input addr_t           addr,
    input data_t           data,
    input longint unsigned tag
  );
    req_t q = req_t::type_id::create($sformatf("wr_%0h", tag));

    q.op    = VIP_DRAM_OP_WR_E;
    q.addr  = addr;
    q.beats = 1;
    q.tag   = tag;
    q.wdata = new[1];
    q.wstrb = new[1];
    q.wdata[0] = data;
    q.wstrb[0] = '1;
    return q;
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function req_t mk_ref(
    input int              rank,
    input longint unsigned tag
  );
    req_t q = req_t::type_id::create($sformatf("ref_%0h", tag));

    q.op                = VIP_DRAM_OP_REF_E;
    q.rank              = rank;
    q.has_explicit_rank = 1'b1;
    q.tag               = tag;
    return q;
  endfunction

  // ===========================================================================
  // Issue helpers
  // ===========================================================================

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task send_checked(
    input req_t req
  );
    int target = this.env.sb.n_recv + 1;

    this.env.drv.issue(
      .req ( req )
    );
    this.env.sb.wait_for(
      .n ( target )
    );
  endtask

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function void chk_time(
    input string   nm,
    input realtime got,
    input realtime exp
  );
    realtime d = (got > exp) ? (got - exp) : (exp - got);

    if (d <= this.env.sb.tol) begin
      `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s = %0.3f ns (ok)", this.tc_name, nm, got), UVM_LOW)
    end
    else begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] %s = %0.3f ns, expected %0.3f ns", this.tc_name, nm, got, exp))
    end
  endfunction

endclass
