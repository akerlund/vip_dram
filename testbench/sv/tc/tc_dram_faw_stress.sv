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
// tc_dram_faw_stress (§12.3 #5)
//
// Five back-to-back reads, each to a different (closed) bank, so each forces an
// ACTIVATE. The first four pace by tRRD; the fifth is held off by the
// four-activate window: its ACT cannot issue before the OLDEST of the prior
// four + tFAW. Since the four are issued at t=0 and the first ACT lands at
// t_first_act, the fifth ACT is observed at t_first_act + tFAW — which shows up
// as (first5 - first0) == tFAW (the constant tRCD+tCL term cancels).
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_faw_stress extends dram_base_test;

  `uvm_component_utils(tc_dram_faw_stress)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_faw_stress",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    vip_dram_timing_t t = super.env.dram.cfg.timing;

    // Five distinct banks: bg0..3 (bank0), then bg0 bank1 for the 5th ACT.
    int    bgs  [5] = '{0, 1, 2, 3, 0};
    int    bnks [5] = '{0, 0, 0, 0, 1};
    addr_t addr;
    req_t  rd_req;
    rsp_t  first_rsp;
    rsp_t  fifth_rsp;

    // Fire five reads back-to-back at five DISTINCT (closed) banks, so each is a
    // fresh open that must ACTIVATE. Spreading the first four across bank groups
    // keeps them paced by the small tRRD_S (not the larger same-bg tRRD_L), so
    // all four ACTs squeeze into a tight window — the worst case for FAW.
    for (int i = 0; i < 5; i++) begin
      addr = super.addr_of(
        .rank ( 0       ),
        .bg   ( bgs[i]  ),
        .bank ( bnks[i] ),
        .row  ( 0       ),
        .col  ( 0       )
      );
      rd_req = super.mk_rd_req(
        .addr  ( addr      ),
        .beats ( 1         ),
        .tag   ( 'h500 + i )
      );
      super.env.drv.send(
        .req ( rd_req )
      );
    end
    super.env.sb.wait_for(
      .n ( 5 )
    );

    // FAW caps the rank to 4 ACTs in any tFAW window, so the 5th ACT cannot
    // start before the OLDEST of the prior four + tFAW. Both responses carry the
    // same fixed tRCD+tCL after their ACT, so it cancels in the difference:
    // (first of the 5th) - (first of the 1st) == (ACT5 - ACT1) == tFAW.
    first_rsp = super.env.sb.get_rsp(
      .tag ( 'h500 )   // 1st ACT (the FAW window anchor)
    );
    fifth_rsp = super.env.sb.get_rsp(
      .tag ( 'h504 )   // 5th ACT (the one held off)
    );
    super.chk_time(
      .nm  ( "5th ACT deferral (tFAW)"                           ),
      .got ( fifth_rsp.first_beat_ready_time - first_rsp.first_beat_ready_time ),
      .exp ( t.tFAW                                              )
    );
  endtask

endclass
