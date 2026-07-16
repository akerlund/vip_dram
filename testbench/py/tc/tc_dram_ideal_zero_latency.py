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
## tc_dram_ideal_zero_latency (SV §12.3 #12)
##
## pyUVM port of testbench/sv/tc/tc_dram_ideal_zero_latency.sv.
##
## The IDEAL preset collapses every timing parameter to zero, so a read's data is
## ready at its arrival time -- first == last == arrival. A sanity regression that
## the zero-delay path behaves and the response still carries the data.
##
################################################################################

from __future__ import annotations

from vip_dram_timing_pkg import VipDramPreset
from dram_base_test import dram_base_test


class tc_dram_ideal_zero_latency(dram_base_test):

  async def body(self):
    # IDEAL zeroes every delay. Apply it, then clear state so the read sees a
    # fresh device.
    self.env.dram.cfg.apply_preset(VipDramPreset.IDEAL)
    self.env.dram.cfg.validate()
    await self.env.dram.reset()

    addr = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
    seeded_data = self.pattern(0xD0)

    # Seed via backdoor so the read returns known data at zero latency.
    self.env.dram.backdoor_write(addr, seeded_data)

    rd_req = self.mk_rd_req(addr, 1, 0xC00)
    await self.send_checked(rd_req)
    rd_rsp = self.env.sb.get_rsp(0xC00)

    # With every delay zero the data is ready the instant the request arrives.
    self.chk_time("ideal first == arrival", rd_rsp.first_beat_ready_time,
                  rd_req.arrival_time)
    self.chk_time("ideal last == arrival", rd_rsp.last_beat_ready_time,
                  rd_req.arrival_time)
    if rd_rsp.rdata[0] != seeded_data:
      self.logger.error(
        f"ERROR [{self.tc_name}] ideal read {rd_rsp.rdata[0]:x} != "
        f"seeded {seeded_data:x}")
