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
// tc_dram_bank_parallel (§12.3 #4)
//
// Open one row in each of the 4 bank groups, then stream back-to-back reads
// round-robin across them. Because consecutive accesses hit DIFFERENT bank
// groups, the spacing is tCCD_S — strictly less than the same-bank-group tCCD_L
// of the page-hit streak (#2). This is the bank-group-level parallelism the
// model now captures (tCCD_S was previously dead).
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_bank_parallel extends dram_base_test;

  `uvm_component_utils(tc_dram_bank_parallel)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_bank_parallel",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    localparam int    STREAM_C = 8;
    vip_dram_timing_t t = super.env.dram.cfg.timing;
    addr_t            addr;
    req_t             rd_req;
    rsp_t             curr_rsp;
    rsp_t             prev_rsp;

    // Phase 1 — pre-open row 0 in each of the 4 bank groups, one at a time
    // (send_checked waits for each), so the streaming phase that follows is all
    // hits and isolates the column-spacing rule from any activate cost.
    for (int bg = 0; bg < 4; bg++) begin
      addr = super.addr_of(
        .rank ( 0  ),
        .bg   ( bg ),
        .bank ( 0  ),
        .row  ( 0  ),
        .col  ( 0  )
      );
      rd_req = super.mk_rd_req(
        .addr  ( addr       ),
        .beats ( 1          ),
        .tag   ( 'h400 + bg )
      );
      super.env.sb.expect_page(
        .tag   ( 'h400 + bg ),
        .hit   ( 1'b0       ),
        .miss  ( 1'b0       ),
        .empty ( 1'b1       )
      );
      super.send_checked(
        .req ( rd_req )
      );
    end

    // Phase 2 — stream reads back-to-back, hopping bank groups every access
    // (bg = i % 4). Every access is a hit on an already-open row, so the only
    // thing pacing them is the CAS-to-CAS rule: consecutive CAS land in
    // DIFFERENT bank groups, which is governed by tCCD_S (not tCCD_L).
    for (int i = 0; i < STREAM_C; i++) begin
      addr = super.addr_of(
        .rank ( 0     ),
        .bg   ( i % 4 ),    // round-robin across the four open bank groups
        .bank ( 0     ),
        .row  ( 0     ),
        .col  ( 0     )
      );
      rd_req = super.mk_rd_req(
        .addr  ( addr      ),
        .beats ( 1         ),
        .tag   ( 'h410 + i )
      );
      super.env.sb.expect_page(
        .tag   ( 'h410 + i ),
        .hit   ( 1'b1      ),
        .miss  ( 1'b0      ),
        .empty ( 1'b0      )
      );
      super.env.drv.send(
        .req ( rd_req )
      );
    end
    super.env.sb.wait_for(
      .n ( 4 + STREAM_C )
    );

    // Each consecutive pair should be tCCD_S apart — proving cross-bank-group
    // interleaving beats the tCCD_L of a single bank group (tc_dram_page_hit_streak).
    for (int i = 1; i < STREAM_C; i++) begin
      prev_rsp = super.env.sb.get_rsp(
        .tag ( 'h410 + i - 1 )
      );
      curr_rsp = super.env.sb.get_rsp(
        .tag ( 'h410 + i )
      );
      super.chk_time(
        .nm  ( $sformatf("round-robin %0d spacing (tCCD_S)", i)       ),
        .got ( curr_rsp.first_beat_ready_time - prev_rsp.first_beat_ready_time ),
        .exp ( t.tCCD_S                                               )
      );
    end

    if (!(t.tCCD_S < t.tCCD_L)) begin
      `uvm_info(get_name(), $sformatf(
      "INFO [%s] note: tCCD_S == tCCD_L for this preset", super.tc_name), UVM_LOW)
    end
  endtask

endclass
