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
## tc_dram_smoke (SV §12.3 #1)
##
## pyUVM port of testbench/sv/tc/tc_dram_smoke.sv.
##
## One write then one read to the same row of a fresh bank. Checks:
##   - the write to the empty bank is classified `empty` and rises EXACTLY at
##     tRCD + tWL (no spurious tRP term -- t_last_pre starts at -LARGE),
##   - the follow-up read to the now-open row is classified `hit`,
##   - the read returns the written data (frontdoor round-trip),
##   - predict() matches the observed timing for both (scoreboard).
##
################################################################################

from __future__ import annotations

from dram_base_test import dram_base_test


class tc_dram_smoke(dram_base_test):

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  async def body(self):
    t = self.env.dram.cfg.timing

    # Target the very first column of bank 0 in a freshly-reset device, and a
    # known data row to write/read back.
    addr = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
    data = self.pattern(0xC0)

    # -- Write to the empty bank --------------------------------------------
    # The bank is IDLE, so this access ACTIVATEs the row first: classified EMPTY
    # and its data lands at exactly tRCD (ACT->CAS) + tWL (CAS->write-data). No
    # extra tRP term (a fresh bank's t_last_pre starts at -LARGE).
    wr_req = self.mk_wr_req(addr, data, 0x10)
    self.env.sb.expect_page(0x10, hit=False, miss=False, empty=True)
    await self.send_checked(wr_req)          # single outstanding -> predict is exact
    wr_rsp = self.env.sb.get_rsp(0x10)
    self.chk_time("write first (tRCD+tWL)", wr_rsp.first_beat_ready_time,
                  t.tRCD + t.tWL)            # no tRP on a first access

    # -- Read the now-open row ----------------------------------------------
    # The write left the row open, so reading the same row is a page HIT and must
    # return the data the write committed (frontdoor round-trip through vip_mem).
    rd_req = self.mk_rd_req(addr, 1, 0x11)
    self.env.sb.expect_page(0x11, hit=True, miss=False, empty=False)
    await self.send_checked(rd_req)
    rd_rsp = self.env.sb.get_rsp(0x11)
    if rd_rsp.rdata[0] != data:
      self.logger.error(
        f"ERROR [{self.tc_name}] read data {rd_rsp.rdata[0]:x} != written {data:x}")
    else:
      self.logger.info(f"INFO [{self.tc_name}] frontdoor round-trip ok")
