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
// tc_dram_refresh_explicit (§12.3 #6)
//
// Open a row, settle, then issue an explicit REF to the rank. With the rank
// otherwise idle the REF takes exactly tRFC. After it completes every bank of
// the rank is precharged, so the next access is classified empty. The device's
// refresh counter increments by one.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_refresh_explicit extends dram_base_test;

  `uvm_component_utils(tc_dram_refresh_explicit)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_refresh_explicit",
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
    req_t             warmup_rd_req;
    req_t             ref_req;
    rsp_t             ref_rsp;
    req_t             post_ref_rd_req;

    addr = super.addr_of(
      .rank ( 0 ),
      .bg   ( 0 ),
      .bank ( 0 ),
      .row  ( 0 ),
      .col  ( 0 )
    );

    // Put some traffic on the rank first: open a row so the device has live
    // bank state for the REF to tear down.
    warmup_rd_req = super.mk_rd_req(
      .addr  ( addr   ),
      .beats ( 1     ),
      .tag   ( 'h600 )
    );
    super.env.sb.expect_page(
      .tag   ( 'h600 ),
      .hit   ( 1'b0  ),
      .miss  ( 1'b0  ),
      .empty ( 1'b1  )
    );
    super.send_checked(
      .req ( warmup_rd_req )
    );

    // Settle so the read's data burst has fully drained. REF must wait for any
    // in-flight rank activity; settling first means its latency is a clean tRFC
    // rather than tRFC plus the tail of the read burst.
    #100ns;

    // Refresh rank 0. The device takes the target rank straight from req.rank
    // (REF carries no address); it blocks the whole rank for tRFC.
    ref_req = super.mk_ref(
      .rank ( 0     ),
      .tag  ( 'h601 )
    );
    super.send_checked(
      .req ( ref_req )
    );
    ref_rsp = super.env.sb.get_rsp(
      .tag ( 'h601 )
    );
    if (ref_rsp.op != VIP_DRAM_OP_REF_E) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] REF response op mismatch", super.tc_name))
    end
    super.chk_time(
      .nm  ( "REF latency (tRFC)"                     ),
      .got ( ref_rsp.first_beat_ready_time - ref_req.arrival_time ),
      .exp ( t.tRFC                                   )
    );

    // REF does a precharge-all, so the row opened earlier is gone: the next
    // access to the rank finds an IDLE bank and is classified empty (a hit here
    // would mean the refresh failed to close the row).
    post_ref_rd_req = super.mk_rd_req(
      .addr  ( addr   ),
      .beats ( 1     ),
      .tag   ( 'h602 )
    );
    super.env.sb.expect_page(
      .tag   ( 'h602 ),
      .hit   ( 1'b0  ),
      .miss  ( 1'b0  ),
      .empty ( 1'b1  )
    );
    super.send_checked(
      .req ( post_ref_rd_req )
    );

    if (super.env.dram.get_refresh_count() != 1) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] refresh count = %0d, expected 1",
      super.tc_name, super.env.dram.get_refresh_count()))
    end
  endtask

endclass
