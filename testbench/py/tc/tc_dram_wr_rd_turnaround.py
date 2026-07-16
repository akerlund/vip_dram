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
## tc_dram_wr_rd_turnaround (SV §12.3 #13)
##
## pyUVM port of testbench/sv/tc/tc_dram_wr_rd_turnaround.sv.
##
## Pins the read/write bus-turnaround bubbles the scheduler layers on top of the
## row/column state machine:
##   - WR -> RD is gated by tWTR, referenced from the write DATA-burst end (_L vs
##     the same bank group, _S vs any other), and
##   - RD -> WR by the controller-derived tRTW, referenced from the read CAS.
##     Each pair is fire-and-forget send() so the turnaround floor -- not sim time --
##     binds. Scenarios are spaced by a large settle so one scenario's rank-level
##     reference edges age fully into the past before the next one measures.
##
## wr_cas = wr.first - tWL
## rd_cas = rd.first - tCL
## wr_data_end = wr.first + tBL (single-beat write: last == first)
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import delay_ns
from dram_base_test import dram_base_test


class tc_dram_wr_rd_turnaround(dram_base_test):

  # Far exceeds tRC / tWTR / tRTW, so a prior scenario's reference edges are long
  # in the past when the next scenario schedules (no refresh fires here).
  SETTLE_NS = 5000.0

  async def body(self):
    t = self.env.dram.cfg.timing

    # Column 0 / column 1 of (rank0, bg0, bank0, row0) -- same DRAM page, distinct
    # single-beat column accesses -- and column 0 of (rank0, bg1, bank0, row0).
    a_bg0_c0 = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
    a_bg0_c1 = self.addr_of(rank=0, bg=0, bank=0, row=0, col=1)
    a_bg1_c0 = self.addr_of(rank=0, bg=1, bank=0, row=0, col=0)
    n_target = 0

    # === Scenario 1: WR -> RD, same bank group (tWTR_L) =====================
    self.env.sb.expect_page(0xA00, hit=False, miss=False, empty=True)
    self.env.sb.expect_page(0xA01, hit=True, miss=False, empty=False)
    self.env.drv.send(self.mk_wr_req(a_bg0_c0, self.pattern(0xA0), 0xA00))
    self.env.drv.send(self.mk_rd_req(a_bg0_c1, 1, 0xA01))
    n_target += 2
    await self.env.sb.wait_for(n_target)

    wr_rsp = self.env.sb.get_rsp(0xA00)
    rd_rsp = self.env.sb.get_rsp(0xA01)
    self.chk_time(
      "WR->RD same-BG turnaround (tWTR_L)",
      (rd_rsp.first_beat_ready_time - t.tCL) - (wr_rsp.first_beat_ready_time + t.tBL),
      t.tWTR_L)

    await delay_ns(self.SETTLE_NS)

    # === Scenario 2: RD -> WR, same bank group (tRTW) =======================
    self.env.sb.expect_page(0xC00, hit=True, miss=False, empty=False)
    self.env.sb.expect_page(0xC01, hit=True, miss=False, empty=False)
    self.env.drv.send(self.mk_rd_req(a_bg0_c0, 1, 0xC00))
    self.env.drv.send(self.mk_wr_req(a_bg0_c1, self.pattern(0xC0), 0xC01))
    n_target += 2
    await self.env.sb.wait_for(n_target)

    rd_rsp = self.env.sb.get_rsp(0xC00)
    wr_rsp = self.env.sb.get_rsp(0xC01)
    self.chk_time(
      "RD->WR same-BG turnaround (tRTW)",
      (wr_rsp.first_beat_ready_time - t.tWL) - (rd_rsp.first_beat_ready_time - t.tCL),
      t.tRTW)

    await delay_ns(self.SETTLE_NS)

    # === Scenario 3: WR (bg0) -> RD (bg1), cross bank group (tWTR_S) =========
    self.env.sb.expect_page(0xB00, hit=False, miss=False, empty=True)
    self.env.drv.send(self.mk_rd_req(a_bg1_c0, 1, 0xB00))
    n_target += 1
    await self.env.sb.wait_for(n_target)

    await delay_ns(self.SETTLE_NS)

    self.env.sb.expect_page(0xB01, hit=True, miss=False, empty=False)   # bg0 row0 still open
    self.env.sb.expect_page(0xB02, hit=True, miss=False, empty=False)   # bg1 row0 pre-opened
    self.env.drv.send(self.mk_wr_req(a_bg0_c0, self.pattern(0xB0), 0xB01))
    self.env.drv.send(self.mk_rd_req(a_bg1_c0, 1, 0xB02))
    n_target += 2
    await self.env.sb.wait_for(n_target)

    wr_rsp = self.env.sb.get_rsp(0xB01)
    rd_rsp = self.env.sb.get_rsp(0xB02)
    self.chk_time(
      "WR->RD cross-BG turnaround (tWTR_S)",
      (rd_rsp.first_beat_ready_time - t.tCL) - (wr_rsp.first_beat_ready_time + t.tBL),
      t.tWTR_S)

    if not (t.tWTR_L > t.tWTR_S):
      self.logger.info(
        f"INFO [{self.tc_name}] note: tWTR_L ({t.tWTR_L:.3f}) == tWTR_S "
        f"({t.tWTR_S:.3f}) for this preset (no bank groups)")
