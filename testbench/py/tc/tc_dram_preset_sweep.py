################################################################################
##
## Copyright (C) 2026 Fredrik Åkerlund
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.
##
## Description:
## tc_dram_preset_sweep (SV §12.3 #11)
##
## pyUVM port of testbench/sv/tc/tc_dram_preset_sweep.sv.
##
## Run the smoke read once per timing preset. For each: apply the preset,
## validate() it, reset, and read a fresh bank. The scoreboard checks the observed
## timing matches predict() under that preset (the single-source-of-truth
## guarantee, across every bin), and that the access is `empty`.
##
################################################################################

from __future__ import annotations

from vip_dram_timing_pkg import VipDramPreset
from dram_base_test import dram_base_test


class tc_dram_preset_sweep(dram_base_test):

  async def body(self):
    presets = [
      VipDramPreset.DDR4_3200_CL22,
      VipDramPreset.DDR4_2400_CL17,
      VipDramPreset.DDR3_1600_CL11,
      VipDramPreset.LPDDR4_3200,
      VipDramPreset.DDR5_4800,
      VipDramPreset.IDEAL,
    ]

    for i, preset in enumerate(presets):
      tag = 0xB00 + i

      # Retune timing to this preset, re-check self-consistency, clear bank state.
      self.env.dram.cfg.apply_preset(preset)
      self.env.dram.cfg.validate()
      await self.env.dram.reset()

      # One empty read; send_checked has the scoreboard compare the observed
      # timing against predict() under THIS preset.
      addr = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
      rd_req = self.mk_rd_req(addr, 1, tag)
      self.env.sb.expect_page(tag, hit=False, miss=False, empty=True)
      await self.send_checked(rd_req)
      self.logger.info(f"INFO [{self.tc_name}] preset {preset.name} ok")
