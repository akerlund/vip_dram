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
## tc_dram_page_thrash (SV §12.3 #3)
##
## pyUVM port of testbench/sv/tc/tc_dram_page_thrash.sv.
##
## Alternating-row reads to the SAME bank. The first opens row0 (empty); each
## subsequent access targets the other row (miss). With tRAS allowed to elapse
## between accesses, each miss costs exactly tRP + tRCD + tCL. The device counts
## the misses.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import delay_ns
from dram_base_test import dram_base_test


class tc_dram_page_thrash(dram_base_test):

  async def body(self):
    t = self.env.dram.cfg.timing

    # Two rows of the SAME bank -- accessing one while the other is open forces a
    # precharge + re-activate (the classic page thrash).
    row0_addr = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
    row1_addr = self.addr_of(rank=0, bg=0, bank=0, row=1, col=0)

    # First touch opens row 0 (bank was IDLE) -> empty, not a miss yet.
    rd_req = self.mk_rd_req(row0_addr, 1, 0x300)
    self.env.sb.expect_page(0x300, hit=False, miss=False, empty=True)
    await self.send_checked(rd_req)

    # Thrash: each access targets the OTHER row -> a miss that PREs the open row
    # then ACTs the new one. Wait 40 ns before each so the open row has satisfied
    # tRAS; the miss cost then reduces to the clean tRP + tRCD + tCL.
    for i in range(3):
      tag = 0x301 + i
      target_addr = row1_addr if (i % 2 == 0) else row0_addr
      await delay_ns(40)
      rd_req = self.mk_rd_req(target_addr, 1, tag)
      self.env.sb.expect_page(tag, hit=False, miss=True, empty=False)
      await self.send_checked(rd_req)
      rd_rsp = self.env.sb.get_rsp(tag)
      # Latency measured from the device's arrival stamp on this request.
      self.chk_time(
        f"miss {i} (tRP+tRCD+tCL)",
        rd_rsp.first_beat_ready_time - rd_req.arrival_time,
        t.tRP + t.tRCD + t.tCL)

    if self.env.dram.get_page_miss_count() != 3:
      self.logger.error(
        f"ERROR [{self.tc_name}] miss count = "
        f"{self.env.dram.get_page_miss_count()}, expected 3")
