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
// tc_dram_predict_matches_schedule (§12.2)
//
// Assert the public predict() contract directly (the driver's issue() path uses
// it internally, but no test drives predict() as an API and checks its purity).
// For a short sequence that walks page-empty / page-hit / page-miss / write:
//   1. predict() is side-effect-free — three back-to-back calls on the same
//      request return identical times and do not perturb committed state, so the
//      subsequent real access still lands where the first predict said it would.
//   2. predict() == schedule() — the fire-and-forget send() commits the access
//      and the response's first/last beat times match the pre-committed predict
//      within the scoreboard's one-cycle tolerance.
// Single-outstanding throughout (predict() reads $realtime + committed state), so
// each predict sees the state the prior access committed.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_predict_matches_schedule extends dram_base_test;

  `uvm_component_utils(tc_dram_predict_matches_schedule)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_predict_matches_schedule",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Predict thrice (assert purity), then commit via send() and check the
  // observed timing against the first predict.
  // ---------------------------------------------------------------------------
  task check_op(input req_t req, input string label);
    realtime f0, l0, f1, l1, f2, l2;
    int      target;
    rsp_t    rsp;

    super.env.dram.predict(.req(req), .first_beat_ready(f0), .last_beat_ready(l0));
    super.env.dram.predict(.req(req), .first_beat_ready(f1), .last_beat_ready(l1));
    super.env.dram.predict(.req(req), .first_beat_ready(f2), .last_beat_ready(l2));

    if ((f0 != f1) || (f0 != f2) || (l0 != l1) || (l0 != l2)) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] %s predict() not side-effect-free: (%0.3f,%0.3f)/(%0.3f,%0.3f)/(%0.3f,%0.3f)",
      super.tc_name, label, f0, l0, f1, l1, f2, l2))
    end

    // Fire-and-forget (no scoreboard expectation): the test owns the check.
    target = super.env.sb.n_recv + 1;
    super.env.drv.send(.req(req));
    super.env.sb.wait_for(.n(target));
    rsp = super.env.sb.get_rsp(.tag(req.tag));

    super.chk_time(.nm({label, ".first"}), .got(rsp.first_beat_ready_time), .exp(f0));
    super.chk_time(.nm({label, ".last"}),  .got(rsp.last_beat_ready_time),  .exp(l0));
  endtask

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    addr_t a_r0;
    addr_t a_r1;
    addr_t a_wr;

    a_r0 = super.addr_of(.rank(0), .bg(0), .bank(0), .row(0), .col(0));
    a_r1 = super.addr_of(.rank(0), .bg(0), .bank(0), .row(1), .col(0));
    a_wr = super.addr_of(.rank(0), .bg(1), .bank(0), .row(0), .col(0));

    // page-empty read (bank closed -> ACT + CAS)
    this.check_op(.req(super.mk_rd_req(.addr(a_r0), .beats(1), .tag('hA00))), .label("rd_empty"));
    // page-hit read (row still open -> CAS only)
    this.check_op(.req(super.mk_rd_req(.addr(a_r0), .beats(1), .tag('hA01))), .label("rd_hit"));
    // page-miss read (open row differs -> PRE + ACT + CAS)
    this.check_op(.req(super.mk_rd_req(.addr(a_r1), .beats(1), .tag('hA02))), .label("rd_miss"));
    // write to a different bank group
    this.check_op(.req(super.mk_wr_req(.addr(a_wr), .data(super.pattern(.seed('hD0))), .tag('hA03))), .label("wr"));
  endtask

endclass
