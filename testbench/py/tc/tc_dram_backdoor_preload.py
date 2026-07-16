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
## tc_dram_backdoor_preload (SV §12.3 #8)
##
## pyUVM port of testbench/sv/tc/tc_dram_backdoor_preload.sv.
##
## Seed memory via the (timing-free) backdoor, then read it back both through the
## frontdoor (full timing) and the backdoor, verifying the data matches.
##
################################################################################

from __future__ import annotations

from dram_base_test import dram_base_test


class tc_dram_backdoor_preload(dram_base_test):

  async def body(self):
    addr0 = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
    addr1 = self.addr_of(rank=0, bg=1, bank=0, row=5, col=0)
    seeded_data0 = self.pattern(0xB0)
    seeded_data1 = self.pattern(0xB1)

    # Seed two rows with no timing at all (direct vip_mem writes).
    self.env.dram.backdoor_write(addr0, seeded_data0)
    self.env.dram.backdoor_write(addr1, seeded_data1)

    # Frontdoor read (full timing, opens the row) must return the seeded data.
    rd_req = self.mk_rd_req(addr0, 1, 0x800)
    await self.send_checked(rd_req)
    rd_rsp = self.env.sb.get_rsp(0x800)
    if rd_rsp.rdata[0] != seeded_data0:
      self.logger.error(
        f"ERROR [{self.tc_name}] frontdoor a0 {rd_rsp.rdata[0]:x} != "
        f"seeded {seeded_data0:x}")

    rd_req = self.mk_rd_req(addr1, 1, 0x801)
    await self.send_checked(rd_req)
    rd_rsp = self.env.sb.get_rsp(0x801)
    if rd_rsp.rdata[0] != seeded_data1:
      self.logger.error(
        f"ERROR [{self.tc_name}] frontdoor a1 {rd_rsp.rdata[0]:x} != "
        f"seeded {seeded_data1:x}")

    # And the backdoor read agrees with the backdoor write (no timing path).
    backdoor_data = self.env.dram.backdoor_read(addr0)
    if backdoor_data != seeded_data0:
      self.logger.error(f"ERROR [{self.tc_name}] backdoor_read a0 mismatch")
