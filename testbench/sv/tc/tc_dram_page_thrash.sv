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
// tc_dram_page_thrash (§12.3 #3)
//
// Alternating-row reads to the SAME bank. The first opens row0 (empty); each
// subsequent access targets the other row (miss). With tRAS allowed to elapse
// between accesses (a settle delay — the "typically already satisfied" case),
// each miss costs exactly tRP + tRCD + tCL. The device counts the misses.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_page_thrash extends dram_base_test;

  `uvm_component_utils(tc_dram_page_thrash)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_page_thrash",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    vip_dram_timing_t t = super.env.dram.cfg.timing;
    addr_t            row0_addr;
    addr_t            row1_addr;
    addr_t            target_addr;
    longint unsigned  tag;
    req_t             rd_req;
    rsp_t             rd_rsp;

    // Two rows of the SAME bank — accessing one while the other is open forces
    // a precharge + re-activate (the classic page thrash).
    row0_addr = super.addr_of(
      .rank ( 0 ),
      .bg   ( 0 ),
      .bank ( 0 ),
      .row  ( 0 ),
      .col  ( 0 )
    );
    row1_addr = super.addr_of(
      .rank ( 0 ),
      .bg   ( 0 ),
      .bank ( 0 ),
      .row  ( 1 ),     // different row, same bank -> conflicts with row 0
      .col  ( 0 )
    );

    // First touch opens row 0 (bank was IDLE) -> empty, not a miss yet.
    rd_req = super.mk_rd_req(
      .addr  ( row0_addr ),
      .beats ( 1     ),
      .tag   ( 'h300 )
    );
    super.env.sb.expect_page(
      .tag   ( 'h300 ),
      .hit   ( 1'b0  ),
      .miss  ( 1'b0  ),
      .empty ( 1'b1  )
    );
    super.send_checked(
      .req ( rd_req )
    );

    // Now thrash: each access targets the OTHER row, so the bank is ACTIVE on
    // the wrong row -> a miss that must PRE the open row then ACT the new one.
    // We #40ns before each so the open row has satisfied tRAS (row-active min)
    // by the time we precharge it; the miss cost then reduces to the clean
    // tRP + tRCD + tCL (without the settle, tRAS would inflate the first miss).
    for (int i = 0; i < 3; i++) begin
      tag = 'h301 + i;
      target_addr = (i % 2 == 0) ? row1_addr : row0_addr;
                                         // alternate row1 / row0 / row1
      #40ns;
      rd_req = super.mk_rd_req(
        .addr  ( target_addr ),
        .beats ( 1   ),
        .tag   ( tag )
      );
      super.env.sb.expect_page(
        .tag   ( tag  ),
        .hit   ( 1'b0 ),
        .miss  ( 1'b1 ),    // bank open on the wrong row -> miss
        .empty ( 1'b0 )
      );
      super.send_checked(
        .req ( rd_req )
      );
      rd_rsp = super.env.sb.get_rsp(
        .tag ( tag )
      );
      // Latency measured from the device's arrival stamp on this request.
      super.chk_time(
        .nm  ( $sformatf("miss %0d (tRP+tRCD+tCL)", i)  ),
        .got ( rd_rsp.first_beat_ready_time - rd_req.arrival_time ),
        .exp ( t.tRP + t.tRCD + t.tCL                   )
      );
    end

    if (super.env.dram.get_page_miss_count() != 3) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] miss count = %0d, expected 3",
      super.tc_name, super.env.dram.get_page_miss_count()))
    end
  endtask
endclass
