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
## tc_dram_predict_matches_schedule (SV §12.2)
##
## pyUVM port of testbench/sv/tc/tc_dram_predict_matches_schedule.sv.
##
## Assert the public predict() contract directly. For a short sequence that walks
## page-empty / page-hit / page-miss / write:
## 1. predict() is side-effect-free -- three back-to-back calls return identical
## times and do not perturb committed state.
## 2. predict() == schedule() -- the fire-and-forget send() commits the access
## and the response's first/last beat times match the pre-committed predict.
## Single-outstanding throughout (predict() reads sim time + committed state).
##
################################################################################

from __future__ import annotations

from dram_base_test import dram_base_test


class tc_dram_predict_matches_schedule(dram_base_test):

  # ---------------------------------------------------------------------------
  # Predict thrice (assert purity), then commit via send() and check the
  # observed timing against the first predict.
  # ---------------------------------------------------------------------------
  async def check_op(self, req, label):
    f0, l0 = self.env.dram.predict(req)
    f1, l1 = self.env.dram.predict(req)
    f2, l2 = self.env.dram.predict(req)

    if (f0 != f1) or (f0 != f2) or (l0 != l1) or (l0 != l2):
      self.logger.error(
        f"ERROR [{self.tc_name}] {label} predict() not side-effect-free: "
        f"({f0:.3f},{l0:.3f})/({f1:.3f},{l1:.3f})/({f2:.3f},{l2:.3f})")

    # Fire-and-forget (no scoreboard expectation): the test owns the check.
    target = self.env.sb.n_recv + 1
    self.env.drv.send(req)
    await self.env.sb.wait_for(target)
    rsp = self.env.sb.get_rsp(req.tag)

    self.chk_time(f"{label}.first", rsp.first_beat_ready_time, f0)
    self.chk_time(f"{label}.last", rsp.last_beat_ready_time, l0)

  async def body(self):
    a_r0 = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
    a_r1 = self.addr_of(rank=0, bg=0, bank=0, row=1, col=0)
    a_wr = self.addr_of(rank=0, bg=1, bank=0, row=0, col=0)

    # page-empty read (bank closed -> ACT + CAS)
    await self.check_op(self.mk_rd_req(a_r0, 1, 0xA00), "rd_empty")
    # page-hit read (row still open -> CAS only)
    await self.check_op(self.mk_rd_req(a_r0, 1, 0xA01), "rd_hit")
    # page-miss read (open row differs -> PRE + ACT + CAS)
    await self.check_op(self.mk_rd_req(a_r1, 1, 0xA02), "rd_miss")
    # write to a different bank group
    await self.check_op(self.mk_wr_req(a_wr, self.pattern(0xD0), 0xA03), "wr")
