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
// tc_dram_page_hit_streak (§12.3 #2)
//
// 64 single-beat reads to consecutive columns of ONE row of ONE bank, issued
// back-to-back. The first opens the row (empty); the other 63 are page hits.
// Checks the per-access spacing settles to tCCD_L (same bank group) — NOT tBL —
// and that the device counts 1 empty + 63 hits.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_page_hit_streak extends dram_base_test;

  `uvm_component_utils(tc_dram_page_hit_streak)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_page_hit_streak",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();
    localparam int    N_C  = 64;
    longint unsigned  base_tag = 'h200;
    vip_dram_timing_t t        = super.env.dram.cfg.timing;
    addr_t            addr;
    req_t             rd_req;
    rsp_t             curr_rsp;
    rsp_t             prev_rsp;

    // Fire all 64 reads back-to-back (send, not send_checked): we do NOT wait
    // between them, so they queue into the device at the same time and the
    // scheduler must space them by its column-to-column rule. They walk
    // consecutive columns of ONE row of ONE bank, so column 0 ACTIVATEs the row
    // (empty) and the remaining 63 land on the open row (hits).
    for (int c = 0; c < N_C; c++) begin
      addr = super.addr_of(
        .rank ( 0 ),
        .bg   ( 0 ),
        .bank ( 0 ),
        .row  ( 0 ),
        .col  ( c )      // advance the column each iteration
      );
      rd_req = super.mk_rd_req(
        .addr  ( addr     ),
        .beats ( 1        ),
        .tag   ( base_tag + c )
      );
      super.env.sb.expect_page(
        .tag   ( base_tag + c ),
        .hit   ( (c != 0) ),       // col 0 opens the row, the rest hit
        .miss  ( 1'b0     ),
        .empty ( (c == 0) )
      );
      super.env.drv.send(
        .req ( rd_req )
      );
    end
    super.env.sb.wait_for(            // block until all 64 responses retire
      .n ( N_C )
    );

    // The throughput claim: consecutive accesses to the SAME bank group are
    // gated by tCCD_L, so the data of access c lands exactly tCCD_L after access
    // c-1. This is the same-bank-group ceiling — distinctly slower than the
    // cross-bank-group tCCD_S exercised by tc_dram_bank_parallel.
    for (int c = 1; c < N_C; c++) begin
      prev_rsp = super.env.sb.get_rsp(
        .tag ( base_tag + c - 1 )
      );
      curr_rsp = super.env.sb.get_rsp(
        .tag ( base_tag + c )
      );
      super.chk_time(
        .nm  ( $sformatf("col %0d spacing (tCCD_L)", c)               ),
        .got ( curr_rsp.first_beat_ready_time - prev_rsp.first_beat_ready_time ),
        .exp ( t.tCCD_L                                               )
      );
    end

    // Per-request counters: exactly one empty (the open) and N-1 hits.
    if (super.env.dram.get_page_empty_count() != 1) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] empty count = %0d, expected 1",
      super.tc_name, super.env.dram.get_page_empty_count()))
    end
    if (super.env.dram.get_page_hit_count() != N_C - 1) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] hit count = %0d, expected %0d",
      super.tc_name, super.env.dram.get_page_hit_count(), N_C - 1))
    end
  endtask

endclass
