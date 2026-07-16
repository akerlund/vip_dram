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
// tc_dram_backdoor_preload (§12.3 #8)
//
// Seed memory via the (timing-free) backdoor, then read it back both through
// the frontdoor (full timing) and the backdoor, verifying the data matches.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_backdoor_preload extends dram_base_test;

  `uvm_component_utils(tc_dram_backdoor_preload)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_backdoor_preload",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    addr_t addr0;
    addr_t addr1;
    data_t seeded_data0;
    data_t seeded_data1;
    data_t backdoor_data;
    req_t  rd_req;
    rsp_t  rd_rsp;

    addr0 = super.addr_of(
      .rank ( 0 ),
      .bg   ( 0 ),
      .bank ( 0 ),
      .row  ( 0 ),
      .col  ( 0 )
    );
    addr1 = super.addr_of(
      .rank ( 0 ),
      .bg   ( 1 ),
      .bank ( 0 ),
      .row  ( 5 ),
      .col  ( 0 )
    );
    seeded_data0 = super.pattern(
      .seed ( 'hB0 )
    );
    seeded_data1 = super.pattern(
      .seed ( 'hB1 )
    );

    // Seed two rows with no timing at all (direct vip_mem writes). This is the
    // path cosim/DPI environments use to preload memory before the clock starts.
    super.env.dram.backdoor_write(
      .addr ( addr0        ),
      .data ( seeded_data0 )
    );
    super.env.dram.backdoor_write(
      .addr ( addr1        ),
      .data ( seeded_data1 )
    );

    // Frontdoor read (full timing, opens the row) must return the seeded data:
    // the backdoor and the scheduled access share the same storage.
    rd_req = super.mk_rd_req(
      .addr  ( addr0  ),
      .beats ( 1     ),
      .tag   ( 'h800 )
    );
    super.send_checked(
      .req ( rd_req )
    );
    rd_rsp = super.env.sb.get_rsp(
      .tag ( 'h800 )
    );
    if (rd_rsp.rdata[0] !== seeded_data0) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] frontdoor a0 %0h != seeded %0h",
      super.tc_name, rd_rsp.rdata[0], seeded_data0))
    end

    rd_req = super.mk_rd_req(
      .addr  ( addr1  ),
      .beats ( 1     ),
      .tag   ( 'h801 )
    );
    super.send_checked(
      .req ( rd_req )
    );
    rd_rsp = super.env.sb.get_rsp(
      .tag ( 'h801 )
    );
    if (rd_rsp.rdata[0] !== seeded_data1) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] frontdoor a1 %0h != seeded %0h",
      super.tc_name, rd_rsp.rdata[0], seeded_data1))
    end

    // And the backdoor read agrees with the backdoor write (no timing path).
    backdoor_data = super.env.dram.backdoor_read(
      .addr ( addr0 )
    );
    if (backdoor_data !== seeded_data0) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] backdoor_read a0 mismatch", super.tc_name))
    end
  endtask

endclass
