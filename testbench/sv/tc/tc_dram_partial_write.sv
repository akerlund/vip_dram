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
// tc_dram_partial_write (§12.3 #9)
//
// Seed a row with a base pattern, then frontdoor-write the SAME row with a new
// pattern but a non-all-ones wstrb (even bytes only). Reading back, the strobed
// (even) bytes must hold the new data and the masked (odd) bytes must retain
// the base — exercising the vip_mem wr_be byte-enable merge.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_partial_write extends dram_base_test;

  `uvm_component_utils(tc_dram_partial_write)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_partial_write",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    addr_t addr;
    data_t base_data;
    data_t new_data;
    data_t expected_data;
    strb_t mask = '0;
    req_t  wr_req;
    req_t  rd_req;
    rsp_t  rd_rsp;

    addr = super.addr_of(
      .rank ( 0 ),
      .bg   ( 0 ),
      .bank ( 0 ),
      .row  ( 0 ),
      .col  ( 0 )
    );
    base_data = super.pattern(
      .seed ( 'h00 )
    );
    new_data = super.pattern(
      .seed ( 'hF0 )
    );

    // Byte-enable mask: strobe even bytes, mask odd bytes.
    for (int b = 0; b < ROW_BYTES_C; b++) begin
      if (b % 2 == 0) mask[b] = 1'b1;
    end

    // Seed the whole row with the base pattern via the backdoor (all bytes).
    super.env.dram.backdoor_write(
      .addr ( addr      ),
      .data ( base_data )
    );

    // Frontdoor write the NEW pattern but with the partial mask. mk_wr_req sets
    // all strobes, so build this request by hand to carry the custom wstrb.
    wr_req = req_t::type_id::create("pw");
    wr_req.op    = VIP_DRAM_OP_WR_E;
    wr_req.addr  = addr;
    wr_req.beats = 1;
    wr_req.tag   = 'h900;
    wr_req.wdata = new[1];
    wr_req.wstrb = new[1];
    wr_req.wdata[0] = new_data;
    wr_req.wstrb[0] = mask;
    super.send_checked(
      .req ( wr_req )
    );

    // Read the row back — the merge must keep only the strobed bytes' new data.
    rd_req = super.mk_rd_req(
      .addr  ( addr   ),
      .beats ( 1     ),
      .tag   ( 'h901 )
    );
    super.send_checked(
      .req ( rd_req )
    );
    rd_rsp = super.env.sb.get_rsp(
      .tag ( 'h901 )
    );

    // Expected = base with the even (strobed) bytes overwritten by newd.
    expected_data = base_data;
    for (int b = 0; b < ROW_BYTES_C; b++) begin
      if (b % 2 == 0) expected_data[8*b +: 8] = new_data[8*b +: 8];
    end
    if (rd_rsp.rdata[0] !== expected_data) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] partial write readback %0h != expected %0h",
      super.tc_name, rd_rsp.rdata[0], expected_data))
    end
  endtask

endclass
