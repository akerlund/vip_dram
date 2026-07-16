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
// tc_dram_smoke (§12.3 #1)
//
// One write then one read to the same row of a fresh bank. Checks:
//   - the write to the empty bank is classified `empty` and rises EXACTLY at
//     tRCD + tWL (no spurious tRP term — t_last_pre starts at -LARGE, Q1),
//   - the follow-up read to the now-open row is classified `hit`,
//   - the read returns the written data (frontdoor round-trip),
//   - predict() matches the observed timing for both (scoreboard).
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_smoke extends dram_base_test;

  `uvm_component_utils(tc_dram_smoke)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_smoke",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    vip_dram_timing_t t = super.env.dram.cfg.timing;
    addr_t            addr;
    data_t            data;
    req_t             wr_req;
    req_t             rd_req;
    rsp_t             wr_rsp;
    rsp_t             rd_rsp;

    // Target the very first column of bank 0 in a freshly-reset device, and a
    // known data row to write/read back.
    addr = super.addr_of(
      .rank ( 0 ),
      .bg   ( 0 ),
      .bank ( 0 ),
      .row  ( 0 ),
      .col  ( 0 )
    );
    data = super.pattern(
      .seed ( 'hC0 )
    );

    // -- Write to the empty bank --------------------------------------------
    // The bank is IDLE, so this access must ACTIVATE the row first: it is
    // classified EMPTY and its data lands at exactly tRCD (ACT->CAS) + tWL
    // (CAS->write-data). The key assertion is that there is NO extra tRP term
    // — a fresh bank's t_last_pre starts at -LARGE, so the precharge floor
    // collapses (plan Q1). predict() vs observed is also checked by the sb.
    wr_req = super.mk_wr_req(
      .addr ( addr ),
      .data ( data ),
      .tag  ( 'h10 )
    );
    super.env.sb.expect_page(
      .tag   ( 'h10 ),
      .hit   ( 1'b0 ),
      .miss  ( 1'b0 ),
      .empty ( 1'b1 )    // first access to an IDLE bank -> empty
    );
    super.send_checked(            // single outstanding -> predict is exact
      .req ( wr_req )
    );
    wr_rsp = super.env.sb.get_rsp(
      .tag ( 'h10 )
    );
    super.chk_time(
      .nm  ( "write first (tRCD+tWL)"  ),
      .got ( wr_rsp.first_beat_ready_time ),
      .exp ( t.tRCD + t.tWL            )   // no tRP on a first access
    );

    // -- Read the now-open row ----------------------------------------------
    // The write left the row open, so reading the same row is a page HIT and
    // must return the data the write committed (frontdoor write -> frontdoor
    // read round-trip through the owned vip_mem).
    rd_req = super.mk_rd_req(
      .addr  ( addr ),
      .beats ( 1    ),
      .tag   ( 'h11 )
    );
    super.env.sb.expect_page(
      .tag   ( 'h11 ),
      .hit   ( 1'b1 ),    // row still open on the requested row -> hit
      .miss  ( 1'b0 ),
      .empty ( 1'b0 )
    );
    super.send_checked(
      .req ( rd_req )
    );
    rd_rsp = super.env.sb.get_rsp(
      .tag ( 'h11 )
    );
    if (rd_rsp.rdata[0] !== data) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] read data %0h != written %0h",
      super.tc_name, rd_rsp.rdata[0], data))
    end
    else begin
      `uvm_info(get_name(), $sformatf(
      "INFO [%s] frontdoor round-trip ok", super.tc_name), UVM_LOW)
    end
  endtask

endclass
