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
## tc_dram_refresh_explicit (SV §12.3 #6)
##
## pyUVM port of testbench/sv/tc/tc_dram_refresh_explicit.sv.
##
## Open a row, settle, then issue an explicit REF to the rank. With the rank
## otherwise idle the REF takes exactly tRFC. After it completes every bank of the
## rank is precharged, so the next access is classified empty. The device's
## refresh counter increments by one.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import VipDramOp, delay_ns
from dram_base_test import dram_base_test


class tc_dram_refresh_explicit(dram_base_test):

  async def body(self):
    t = self.env.dram.cfg.timing
    addr = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)

    # Put some traffic on the rank first: open a row so the device has live bank
    # state for the REF to tear down.
    warmup_rd_req = self.mk_rd_req(addr, 1, 0x600)
    self.env.sb.expect_page(0x600, hit=False, miss=False, empty=True)
    await self.send_checked(warmup_rd_req)

    # Settle so the read's data burst has fully drained. REF must wait for any
    # in-flight rank activity; settling first means its latency is a clean tRFC.
    await delay_ns(100)

    # Refresh rank 0. The device takes the target rank straight from req.rank; it
    # blocks the whole rank for tRFC.
    ref_req = self.mk_ref(0, 0x601)
    await self.send_checked(ref_req)
    ref_rsp = self.env.sb.get_rsp(0x601)
    if ref_rsp.op != VipDramOp.REF:
      self.logger.error(f"ERROR [{self.tc_name}] REF response op mismatch")
    self.chk_time("REF latency (tRFC)",
                  ref_rsp.first_beat_ready_time - ref_req.arrival_time, t.tRFC)

    # REF does a precharge-all, so the row opened earlier is gone: the next access
    # to the rank finds an IDLE bank and is classified empty.
    post_ref_rd_req = self.mk_rd_req(addr, 1, 0x602)
    self.env.sb.expect_page(0x602, hit=False, miss=False, empty=True)
    await self.send_checked(post_ref_rd_req)

    if self.env.dram.get_refresh_count() != 1:
      self.logger.error(
        f"ERROR [{self.tc_name}] refresh count = "
        f"{self.env.dram.get_refresh_count()}, expected 1")
