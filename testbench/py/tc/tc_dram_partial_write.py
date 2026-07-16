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
## tc_dram_partial_write (SV §12.3 #9)
##
## pyUVM port of testbench/sv/tc/tc_dram_partial_write.sv.
##
## Seed a row with a base pattern, then frontdoor-write the SAME row with a new
## pattern but a non-all-ones wstrb (even bytes only). Reading back, the strobed
## (even) bytes must hold the new data and the masked (odd) bytes must retain the
## base -- exercising the vip_mem wr_be byte-enable merge.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import VipDramOp
from vip_dram_req import VipDramReq
from dram_base_test import dram_base_test


class tc_dram_partial_write(dram_base_test):

  async def body(self):
    row_bytes = self.row_bytes_c
    addr = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
    base_data = self.pattern(0x00)
    new_data = self.pattern(0xF0)

    # Byte-enable mask: strobe even bytes, mask odd bytes.
    strb = 0
    for b in range(row_bytes):
      if b % 2 == 0:
        strb |= (1 << b)

    # Seed the whole row with the base pattern via the backdoor (all bytes).
    self.env.dram.backdoor_write(addr, base_data)

    # Frontdoor write the NEW pattern but with the partial mask. mk_wr_req sets
    # all strobes, so build this request by hand to carry the custom wstrb.
    wr_req = VipDramReq("pw")
    wr_req.op = VipDramOp.WR
    wr_req.addr = addr
    wr_req.beats = 1
    wr_req.tag = 0x900
    wr_req.wdata = [new_data]
    wr_req.wstrb = [strb]
    await self.send_checked(wr_req)

    # Read the row back -- the merge must keep only the strobed bytes' new data.
    rd_req = self.mk_rd_req(addr, 1, 0x901)
    await self.send_checked(rd_req)
    rd_rsp = self.env.sb.get_rsp(0x901)

    # Expected = base with the even (strobed) bytes overwritten by new_data.
    expected_data = base_data
    for b in range(row_bytes):
      if b % 2 == 0:
        byte_mask = 0xFF << (8 * b)
        expected_data = (expected_data & ~byte_mask) | (new_data & byte_mask)
    if rd_rsp.rdata[0] != expected_data:
      self.logger.error(
        f"ERROR [{self.tc_name}] partial write readback {rd_rsp.rdata[0]:x} != "
        f"expected {expected_data:x}")
