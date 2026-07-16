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
## tc_dram_writes_then_reads (SV §12.3 #7)
##
## pyUVM port of testbench/sv/tc/tc_dram_writes_then_reads.sv.
##
## Write a known pattern to eight distinct (bank group, row) targets, then read
## them all back and verify the data -- the full frontdoor write/read path across
## banks and rows with the scheduler's timing applied throughout.
##
################################################################################

from __future__ import annotations

from dram_base_test import dram_base_test


class tc_dram_writes_then_reads(dram_base_test):

  async def body(self):
    N_C = 8
    # Spread the 8 targets over distinct (bank group, row) pairs.
    target_addrs = [self.addr_of(rank=0, bg=i % 4, bank=0, row=i // 4, col=0)
                    for i in range(N_C)]

    # Phase 1 -- write a per-target pattern (seed 0xA0+i, recomputed on read).
    for i in range(N_C):
      expected_data = self.pattern(0xA0 + i)
      wr_req = self.mk_wr_req(target_addrs[i], expected_data, 0x700 + i)
      await self.send_checked(wr_req)

    # Phase 2 -- read each target back and confirm it holds its written pattern.
    for i in range(N_C):
      rd_req = self.mk_rd_req(target_addrs[i], 1, 0x710 + i)
      await self.send_checked(rd_req)
      rd_rsp = self.env.sb.get_rsp(0x710 + i)
      expected_data = self.pattern(0xA0 + i)
      if rd_rsp.rdata[0] != expected_data:
        self.logger.error(
          f"ERROR [{self.tc_name}] target {i}: read {rd_rsp.rdata[0]:x} != "
          f"written {expected_data:x}")
