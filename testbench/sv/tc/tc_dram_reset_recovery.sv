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
// tc_dram_reset_recovery (§12.3 #10)
//
// Issue a read (which schedules + commits an open row + forks a delayed
// response), then reset() the device mid-flight before that response fires.
// Checks:
//   - the in-flight response is cancelled (disable fork) — it never arrives,
//   - bank state is cleared — a read to the SAME address after reset is `empty`
//     (it would be a `hit` if the open row had survived),
//   - only the post-reset response is observed.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_reset_recovery extends dram_base_test;

  `uvm_component_utils(tc_dram_reset_recovery)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_reset_recovery",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    addr_t addr;
    req_t  pre_reset_rd_req;
    req_t  post_reset_rd_req;

    addr = super.addr_of(
      .rank ( 0 ),
      .bg   ( 0 ),
      .bank ( 0 ),
      .row  ( 0 ),
      .col  ( 0 )
    );

    // Fire a read and do NOT wait for it. The #1ns lets the consumer actually
    // get() the request, schedule() it (committing an open row), and fork the
    // delayed response — so we are genuinely resetting with work in flight, not
    // just flushing the input fifo.
    pre_reset_rd_req = super.mk_rd_req(
      .addr  ( addr   ),
      .beats ( 1     ),
      .tag   ( 'hA00 )
    );
    super.env.drv.send(
      .req ( pre_reset_rd_req )
    );
    #1ns;                       // let the consumer schedule + fork the response
    super.env.dram.reset();     // disable fork cancels it; scheduler state cleared

    // Read the SAME address after reset. If the open row had survived this would
    // be a hit; getting empty proves reset returned the bank to IDLE.
    post_reset_rd_req = super.mk_rd_req(
      .addr  ( addr   ),
      .beats ( 1     ),
      .tag   ( 'hA01 )
    );
    super.env.sb.expect_page(
      .tag   ( 'hA01 ),
      .hit   ( 1'b0  ),
      .miss  ( 1'b0  ),
      .empty ( 1'b1  )    // bank state cleared by reset
    );
    super.send_checked(
      .req ( post_reset_rd_req )
    );

    // The pre-reset response must never have fired (it was cancelled)...
    if (super.env.sb.get_rsp(.tag ( 'hA00 )) != null) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] cancelled response (tag A00) still arrived after reset",
      super.tc_name))
    end
    // ...so exactly one response (the post-reset read) was ever observed.
    if (super.env.sb.n_recv != 1) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] observed %0d responses, expected 1 (only post-reset)",
      super.tc_name, super.env.sb.n_recv))
    end
  endtask

endclass
