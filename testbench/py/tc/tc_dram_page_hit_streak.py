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
## tc_dram_page_hit_streak (SV §12.3 #2)
##
## pyUVM port of testbench/sv/tc/tc_dram_page_hit_streak.sv.
##
## 64 single-beat reads to consecutive columns of ONE row of ONE bank, issued
## back-to-back. The first opens the row (empty); the other 63 are page hits.
## Checks the per-access spacing settles to tCCD_L (same bank group) -- NOT tBL --
## and that the device counts 1 empty + 63 hits.
##
################################################################################

from __future__ import annotations

from dram_base_test import dram_base_test


class tc_dram_page_hit_streak(dram_base_test):

  async def body(self):
    N_C = 64
    base_tag = 0x200
    t = self.env.dram.cfg.timing

    # Fire all 64 reads back-to-back (send, not send_checked). They walk
    # consecutive columns of ONE row of ONE bank: column 0 ACTIVATEs the row
    # (empty) and the remaining 63 land on the open row (hits).
    for c in range(N_C):
      addr = self.addr_of(rank=0, bg=0, bank=0, row=0, col=c)
      rd_req = self.mk_rd_req(addr, 1, base_tag + c)
      self.env.sb.expect_page(base_tag + c, hit=(c != 0), miss=False, empty=(c == 0))
      self.env.drv.send(rd_req)
    await self.env.sb.wait_for(N_C)

    # Consecutive accesses to the SAME bank group are gated by tCCD_L.
    for c in range(1, N_C):
      prev_rsp = self.env.sb.get_rsp(base_tag + c - 1)
      curr_rsp = self.env.sb.get_rsp(base_tag + c)
      self.chk_time(
        f"col {c} spacing (tCCD_L)",
        curr_rsp.first_beat_ready_time - prev_rsp.first_beat_ready_time,
        t.tCCD_L)

    # Per-request counters: exactly one empty (the open) and N-1 hits.
    if self.env.dram.get_page_empty_count() != 1:
      self.logger.error(
        f"ERROR [{self.tc_name}] empty count = "
        f"{self.env.dram.get_page_empty_count()}, expected 1")
    if self.env.dram.get_page_hit_count() != N_C - 1:
      self.logger.error(
        f"ERROR [{self.tc_name}] hit count = "
        f"{self.env.dram.get_page_hit_count()}, expected {N_C - 1}")
