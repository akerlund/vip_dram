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
## tc_dram_reset_recovery (SV §12.3 #10)
##
## pyUVM port of testbench/sv/tc/tc_dram_reset_recovery.sv.
##
## Issue a read (which schedules + commits an open row + forks a delayed
## response), then reset() the device mid-flight before that response fires.
## Checks:
##   - the in-flight response is cancelled (kill of the forked task) -- never
##     arrives,
##   - bank state is cleared -- a read to the SAME address after reset is `empty`,
##   - only the post-reset response is observed.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import delay_ns
from dram_base_test import dram_base_test


class tc_dram_reset_recovery(dram_base_test):

  async def body(self):
    addr = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)

    # Fire a read and do NOT wait for it. The 1 ns lets the consumer actually get
    # the request, schedule() it (committing an open row), and fork the delayed
    # response -- so we are genuinely resetting with work in flight.
    pre_reset_rd_req = self.mk_rd_req(addr, 1, 0xA00)
    self.env.drv.send(pre_reset_rd_req)
    await delay_ns(1)              # let the consumer schedule + fork the response
    await self.env.dram.reset()   # kill the forked response; scheduler state cleared

    # Read the SAME address after reset. If the open row had survived this would
    # be a hit; getting empty proves reset returned the bank to IDLE.
    post_reset_rd_req = self.mk_rd_req(addr, 1, 0xA01)
    self.env.sb.expect_page(0xA01, hit=False, miss=False, empty=True)
    await self.send_checked(post_reset_rd_req)

    # The pre-reset response must never have fired (it was cancelled)...
    if self.env.sb.get_rsp(0xA00) is not None:
      self.logger.error(
        f"ERROR [{self.tc_name}] cancelled response (tag A00) still arrived "
        f"after reset")
    # ...so exactly one response (the post-reset read) was ever observed.
    if self.env.sb.n_recv != 1:
      self.logger.error(
        f"ERROR [{self.tc_name}] observed {self.env.sb.n_recv} responses, "
        f"expected 1 (only post-reset)")
