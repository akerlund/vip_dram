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
// tc_dram_preset_sweep (§12.3 #11)
//
// Run the smoke read once per timing preset. For each: apply the preset,
// validate() it, reset, and read a fresh bank. The scoreboard checks that the
// observed timing matches predict() under that preset (the single-source-of-
// truth guarantee, exercised across every bin), and that the access is `empty`.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_preset_sweep extends dram_base_test;

  `uvm_component_utils(tc_dram_preset_sweep)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_preset_sweep",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();
    vip_dram_preset_t presets [6] = '{
      VIP_DRAM_PRESET_DDR4_3200_CL22_E,
      VIP_DRAM_PRESET_DDR4_2400_CL17_E,
      VIP_DRAM_PRESET_DDR3_1600_CL11_E,
      VIP_DRAM_PRESET_LPDDR4_3200_E,
      VIP_DRAM_PRESET_DDR5_4800_E,
      VIP_DRAM_PRESET_IDEAL_E
    };
    longint unsigned tag;
    addr_t           addr;
    req_t            rd_req;

    foreach (presets[i]) begin
      tag = 'hB00 + i;

      // Retune timing to this preset, re-check it is self-consistent, and clear
      // bank state so the read below sees a fresh device under the new timing.
      super.env.dram.cfg.apply_preset(
        .preset ( presets[i] )
      );
      super.env.dram.cfg.validate();
      super.env.dram.reset();

      // One empty read; send_checked has the scoreboard compare the observed
      // timing against predict() under THIS preset — the cross-preset proof that
      // predict() and schedule() never diverge (we don't hardcode each bin's ns).
      addr = super.addr_of(
        .rank ( 0 ),
        .bg   ( 0 ),
        .bank ( 0 ),
        .row  ( 0 ),
        .col  ( 0 )
      );
      rd_req = super.mk_rd_req(
        .addr  ( addr ),
        .beats ( 1   ),
        .tag   ( tag )
      );
      super.env.sb.expect_page(
        .tag   ( tag  ),
        .hit   ( 1'b0 ),
        .miss  ( 1'b0 ),
        .empty ( 1'b1 )
      );
      super.send_checked(            // timing checked vs predict() by the scoreboard
        .req ( rd_req )
      );
      `uvm_info(get_name(), $sformatf(
      "INFO [%s] preset %s ok", super.tc_name, presets[i].name()), UVM_LOW)
    end
  endtask

endclass
