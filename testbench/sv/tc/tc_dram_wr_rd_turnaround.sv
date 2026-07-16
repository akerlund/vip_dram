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
// tc_dram_wr_rd_turnaround (§12.3 #13)
//
// Pins the read/write bus-turnaround bubbles the scheduler layers on top of the
// row/column state machine (compute_latency's direction-turnaround terms):
//   - WR -> RD is gated by tWTR, referenced from the write DATA-burst end
//     (_L vs the same bank group, _S vs any other), and
//   - RD -> WR by the controller-derived tRTW, referenced from the read CAS.
//
// Each pair is issued back-to-back with fire-and-forget send() (NOT send_checked)
// so the second access is scheduled while the first is still in flight and the
// turnaround floor — not $realtime — is the binding term. Scenarios are spaced by
// a large settle so one scenario's rank-level reference edges (last_wr_end /
// last_rd_cas / last_cas) age fully into the past before the next one measures.
//
// The measured quantity is a DELTA between the two responses' timestamps, which
// pins to the exact turnaround value independent of the absolute issue time:
//   wr_cas      = wr.first - tWL
//   rd_cas      = rd.first - tCL
//   wr_data_end = wr.first + tBL        (single-beat write: last == first)
//
// Checks (all same rank):
//   1. tWTR_L  WR then RD, same bank group:  rd_cas - wr_data_end == tWTR_L
//   2. tRTW    RD then WR, same bank group:  wr_cas - rd_cas      == tRTW
//   3. tWTR_S  WR (bg0) then RD (pre-opened bg1): rd_cas - wr_data_end == tWTR_S
//
// Assumes the default DDR4-3200 preset, where the turnaround term dominates the
// tCCD column-spacing and bus-contention terms for these pairs (verified by the
// scenario arithmetic); tWTR_L > tWTR_S there, so scenarios 1 and 3 are distinct.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_wr_rd_turnaround extends dram_base_test;

  `uvm_component_utils(tc_dram_wr_rd_turnaround)

  // Far exceeds tRC / tWTR / tRTW, so a prior scenario's reference edges are long
  // in the past when the next scenario schedules (no refresh fires here, so open
  // rows stay open across the gap and cross-scenario hits are preserved).
  localparam real SETTLE_NS_C = 5000.0;

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_wr_rd_turnaround",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    vip_dram_timing_t t = super.env.dram.cfg.timing;
    addr_t            a_bg0_c0;
    addr_t            a_bg0_c1;
    addr_t            a_bg1_c0;
    rsp_t             wr_rsp;
    rsp_t             rd_rsp;
    int               n_target = 0;

    // Column 0 / column 1 of (rank0, bg0, bank0, row0) — same DRAM page, distinct
    // single-beat column accesses — and column 0 of (rank0, bg1, bank0, row0).
    a_bg0_c0 = super.addr_of(.rank(0), .bg(0), .bank(0), .row(0), .col(0));
    a_bg0_c1 = super.addr_of(.rank(0), .bg(0), .bank(0), .row(0), .col(1));
    a_bg1_c0 = super.addr_of(.rank(0), .bg(1), .bank(0), .row(0), .col(0));

    // === Scenario 1: WR -> RD, same bank group (tWTR_L) =====================
    // The write opens the row (empty); the read to that now-open row is a page
    // hit whose CAS cannot issue until tWTR_L after the write's data burst ends.
    super.env.sb.expect_page(.tag('hA00), .hit(1'b0), .miss(1'b0), .empty(1'b1));
    super.env.sb.expect_page(.tag('hA01), .hit(1'b1), .miss(1'b0), .empty(1'b0));
    super.env.drv.send(.req(super.mk_wr_req(.addr(a_bg0_c0), .data(super.pattern('hA0)), .tag('hA00))));
    super.env.drv.send(.req(super.mk_rd_req(.addr(a_bg0_c1), .beats(1),                  .tag('hA01))));
    n_target += 2;
    super.env.sb.wait_for(.n(n_target));

    wr_rsp = super.env.sb.get_rsp(.tag('hA00));
    rd_rsp = super.env.sb.get_rsp(.tag('hA01));
    super.chk_time(
      .nm  ( "WR->RD same-BG turnaround (tWTR_L)"                                     ),
      .got ( (rd_rsp.first_beat_ready_time - t.tCL) - (wr_rsp.first_beat_ready_time + t.tBL) ),
      .exp ( t.tWTR_L                                                                 )
    );

    #(SETTLE_NS_C);

    // === Scenario 2: RD -> WR, same bank group (tRTW) =======================
    // Row (bg0,row0) is still open from scenario 1, so both accesses are page
    // hits; the write CAS cannot issue until tRTW after the read CAS command.
    super.env.sb.expect_page(.tag('hC00), .hit(1'b1), .miss(1'b0), .empty(1'b0));
    super.env.sb.expect_page(.tag('hC01), .hit(1'b1), .miss(1'b0), .empty(1'b0));
    super.env.drv.send(.req(super.mk_rd_req(.addr(a_bg0_c0), .beats(1),                  .tag('hC00))));
    super.env.drv.send(.req(super.mk_wr_req(.addr(a_bg0_c1), .data(super.pattern('hC0)), .tag('hC01))));
    n_target += 2;
    super.env.sb.wait_for(.n(n_target));

    rd_rsp = super.env.sb.get_rsp(.tag('hC00));
    wr_rsp = super.env.sb.get_rsp(.tag('hC01));
    super.chk_time(
      .nm  ( "RD->WR same-BG turnaround (tRTW)"                                       ),
      .got ( (wr_rsp.first_beat_ready_time - t.tWL) - (rd_rsp.first_beat_ready_time - t.tCL) ),
      .exp ( t.tRTW                                                                   )
    );

    #(SETTLE_NS_C);

    // === Scenario 3: WR (bg0) -> RD (bg1), cross bank group (tWTR_S) =========
    // Pre-open bg1 with a read, then let it age out. The measured write touches
    // only bg0, so the bg1 read sees NO same-BG write-end (the tWTR_L term is
    // absent) and is gated by the weaker any-BG tWTR_S off the write data end.
    super.env.sb.expect_page(.tag('hB00), .hit(1'b0), .miss(1'b0), .empty(1'b1));
    super.env.drv.send(.req(super.mk_rd_req(.addr(a_bg1_c0), .beats(1), .tag('hB00))));
    n_target += 1;
    super.env.sb.wait_for(.n(n_target));

    #(SETTLE_NS_C);

    super.env.sb.expect_page(.tag('hB01), .hit(1'b1), .miss(1'b0), .empty(1'b0));  // bg0 row0 still open
    super.env.sb.expect_page(.tag('hB02), .hit(1'b1), .miss(1'b0), .empty(1'b0));  // bg1 row0 pre-opened
    super.env.drv.send(.req(super.mk_wr_req(.addr(a_bg0_c0), .data(super.pattern('hB0)), .tag('hB01))));
    super.env.drv.send(.req(super.mk_rd_req(.addr(a_bg1_c0), .beats(1),                  .tag('hB02))));
    n_target += 2;
    super.env.sb.wait_for(.n(n_target));

    wr_rsp = super.env.sb.get_rsp(.tag('hB01));
    rd_rsp = super.env.sb.get_rsp(.tag('hB02));
    super.chk_time(
      .nm  ( "WR->RD cross-BG turnaround (tWTR_S)"                                    ),
      .got ( (rd_rsp.first_beat_ready_time - t.tCL) - (wr_rsp.first_beat_ready_time + t.tBL) ),
      .exp ( t.tWTR_S                                                                 )
    );

    // The two WR->RD scenarios are only distinct if the preset has bank groups
    // (tWTR_L > tWTR_S). Flag the degenerate case (DDR3 / no-BG presets) rather
    // than silently letting scenarios 1 and 3 measure the same number.
    if (!(t.tWTR_L > t.tWTR_S)) begin
      `uvm_info(get_name(), $sformatf(
        "INFO [%s] note: tWTR_L (%0.3f) == tWTR_S (%0.3f) for this preset (no bank groups)",
        super.tc_name, t.tWTR_L, t.tWTR_S), UVM_LOW)
    end
  endtask

endclass
