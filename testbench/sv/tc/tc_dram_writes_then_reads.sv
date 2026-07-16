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
// tc_dram_writes_then_reads (§12.3 #7)
//
// Write a known pattern to eight distinct (bank group, row) targets, then read
// them all back and verify the data. Exercises the full frontdoor write/read
// path across banks and rows with the scheduler's timing applied throughout.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_writes_then_reads extends dram_base_test;

  `uvm_component_utils(tc_dram_writes_then_reads)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_writes_then_reads",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    localparam int N_C = 8;
    addr_t         target_addrs   [N_C];
    data_t         expected_data;
    req_t          wr_req;
    req_t          rd_req;
    rsp_t          rd_rsp;

    // Spread the 8 targets over distinct (bank group, row) pairs (bg = i%4,
    // row = i/4) so the writes exercise different banks and rows, not one
    // hammered location.
    for (int i = 0; i < N_C; i++) begin
      target_addrs[i] = super.addr_of(
        .rank ( 0     ),
        .bg   ( i % 4 ),
        .bank ( 0     ),
        .row  ( i / 4 ),
        .col  ( 0     )
      );
    end

    // Phase 1 — write a per-target pattern (seed 'hA0+i is recomputed on
    // read-back, so no need to stash the data).
    for (int i = 0; i < N_C; i++) begin
      expected_data = super.pattern(
        .seed ( 'hA0 + i )
      );
      wr_req = super.mk_wr_req(
        .addr ( target_addrs[i] ),
        .data ( expected_data    ),
        .tag  ( 'h700 + i )
      );
      super.send_checked(
        .req ( wr_req )
      );
    end

    // Phase 2 — read each target back and confirm it holds its written pattern.
    for (int i = 0; i < N_C; i++) begin
      rd_req = super.mk_rd_req(
        .addr  ( target_addrs[i] ),
        .beats ( 1         ),
        .tag   ( 'h710 + i )
      );
      super.send_checked(
        .req ( rd_req )
      );
      rd_rsp = super.env.sb.get_rsp(
        .tag ( 'h710 + i )
      );
      expected_data = super.pattern(   // same seed used to write target i
        .seed ( 'hA0 + i )
      );
      if (rd_rsp.rdata[0] !== expected_data) begin
        `uvm_error(get_name(), $sformatf(
        "ERROR [%s] target %0d: read %0h != written %0h",
        super.tc_name, i, rd_rsp.rdata[0], expected_data))
      end
    end
  endtask

endclass
