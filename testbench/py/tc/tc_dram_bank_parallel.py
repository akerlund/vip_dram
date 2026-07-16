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
## tc_dram_bank_parallel (SV §12.3 #4)
##
## pyUVM port of testbench/sv/tc/tc_dram_bank_parallel.sv.
##
## Open one row in each of the 4 bank groups, then stream back-to-back reads
## round-robin across them. Consecutive accesses hit DIFFERENT bank groups, so the
## spacing is tCCD_S -- strictly less than the same-bank-group tCCD_L of the
## page-hit streak (#2).
##
################################################################################

from __future__ import annotations

from dram_base_test import dram_base_test


class tc_dram_bank_parallel(dram_base_test):

  async def body(self):
    STREAM_C = 8
    t = self.env.dram.cfg.timing

    # Phase 1 -- pre-open row 0 in each of the 4 bank groups (waited), so the
    # streaming phase is all hits and isolates the column-spacing rule.
    for bg in range(4):
      addr = self.addr_of(rank=0, bg=bg, bank=0, row=0, col=0)
      rd_req = self.mk_rd_req(addr, 1, 0x400 + bg)
      self.env.sb.expect_page(0x400 + bg, hit=False, miss=False, empty=True)
      await self.send_checked(rd_req)

    # Phase 2 -- stream reads back-to-back, hopping bank groups every access.
    # Every access is a hit; the only pacing is CAS-to-CAS across DIFFERENT bank
    # groups, governed by tCCD_S (not tCCD_L).
    for i in range(STREAM_C):
      addr = self.addr_of(rank=0, bg=i % 4, bank=0, row=0, col=0)
      rd_req = self.mk_rd_req(addr, 1, 0x410 + i)
      self.env.sb.expect_page(0x410 + i, hit=True, miss=False, empty=False)
      self.env.drv.send(rd_req)
    await self.env.sb.wait_for(4 + STREAM_C)

    # Each consecutive pair should be tCCD_S apart.
    for i in range(1, STREAM_C):
      prev_rsp = self.env.sb.get_rsp(0x410 + i - 1)
      curr_rsp = self.env.sb.get_rsp(0x410 + i)
      self.chk_time(
        f"round-robin {i} spacing (tCCD_S)",
        curr_rsp.first_beat_ready_time - prev_rsp.first_beat_ready_time,
        t.tCCD_S)

    if not (t.tCCD_S < t.tCCD_L):
      self.logger.info(
        f"INFO [{self.tc_name}] note: tCCD_S == tCCD_L for this preset")
