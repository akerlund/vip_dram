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
## tc_dram_faw_stress (SV §12.3 #5)
##
## pyUVM port of testbench/sv/tc/tc_dram_faw_stress.sv.
##
## Five back-to-back reads, each to a different (closed) bank, so each forces an
## ACTIVATE. The first four pace by tRRD; the fifth is held off by the
## four-activate window: its ACT cannot issue before the OLDEST of the prior four
## + tFAW, which shows up as (first5 - first0) == tFAW.
##
################################################################################

from __future__ import annotations

from dram_base_test import dram_base_test


class tc_dram_faw_stress(dram_base_test):

  async def body(self):
    t = self.env.dram.cfg.timing

    # Five distinct banks: bg0..3 (bank0), then bg0 bank1 for the 5th ACT.
    bgs = [0, 1, 2, 3, 0]
    bnks = [0, 0, 0, 0, 1]

    # Fire five reads back-to-back at five DISTINCT (closed) banks. Spreading the
    # first four across bank groups keeps them paced by the small tRRD_S, so all
    # four ACTs squeeze into a tight window -- the worst case for FAW.
    for i in range(5):
      addr = self.addr_of(rank=0, bg=bgs[i], bank=bnks[i], row=0, col=0)
      rd_req = self.mk_rd_req(addr, 1, 0x500 + i)
      self.env.drv.send(rd_req)
    await self.env.sb.wait_for(5)

    # (first of the 5th) - (first of the 1st) == (ACT5 - ACT1) == tFAW.
    first_rsp = self.env.sb.get_rsp(0x500)   # 1st ACT (the FAW window anchor)
    fifth_rsp = self.env.sb.get_rsp(0x504)   # 5th ACT (the one held off)
    self.chk_time(
      "5th ACT deferral (tFAW)",
      fifth_rsp.first_beat_ready_time - first_rsp.first_beat_ready_time,
      t.tFAW)
