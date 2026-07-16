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
## dram_base_test
##
## pyUVM port of testbench/sv/tc/dram_base_test.sv.
##
## Base for every vip_dram device-only test case. Builds the dram_env and provides
## the request builders and the issue/wait helpers the test cases share. Each test
## overrides body(); the base raises/drops the run-phase objection around it.
##
## pyUVM has no UVM_ERROR exit code, so an ErrorCounter logging handler is
## attached hierarchically over the whole component tree; check_phase raises if
## any component logged an error -- i.e. "0 UVM_ERROR == pass", like the SV run.
##
################################################################################

from __future__ import annotations

import logging

from pyuvm import uvm_test

from vip_dram_addr_pkg import vip_dram_encode_addr
from vip_dram_types_pkg import VipDramDecT, VipDramOp, mask
from vip_dram_req import VipDramReq
from dram_env import dram_env


class _ErrorCounter(logging.Handler):
  """Counts ERROR+ log records across the whole component tree."""

  def __init__(self):
    super().__init__(level=logging.ERROR)
    self.count = 0

  def emit(self, record):
    if record.levelno >= logging.ERROR:
      self.count += 1


class dram_base_test(uvm_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.env = None
    self.tc_name = type(self).__name__
    self._err_handler = None

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def build_phase(self):
    self.env = dram_env("env", self)

  # ---------------------------------------------------------------------------
  # Attach the error counter over the fully-built tree.
  # ---------------------------------------------------------------------------
  def end_of_elaboration_phase(self):
    self._err_handler = _ErrorCounter()
    self.add_logging_handler_hier(self._err_handler)

  # Geometry / channel-row byte width shared by the request builders.
  @property
  def _geom(self):
    return self.env.dram.geom

  @property
  def row_bytes_c(self):
    return self.env.dram.geom.ROW_BYTES_P

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  async def body(self):
    pass

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  async def run_phase(self):
    self.raise_objection()
    await self.body()
    self.drop_objection()

  # ---------------------------------------------------------------------------
  # Fail the cocotb test if any component logged a uvm_error.
  # ---------------------------------------------------------------------------
  def check_phase(self):
    n = self._err_handler.count if self._err_handler else 0
    if n > 0:
      raise AssertionError(f"[{self.tc_name}] {n} UVM_ERROR(s) logged")

  # ===========================================================================
  # Request builders
  # ===========================================================================

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def addr_of(self, rank, bg, bank, row, col):
    d = VipDramDecT(rank=rank, bg=bg, bank=bank, row=row, col=col, byte_in_col=0)
    return vip_dram_encode_addr(d, self._geom, self.env.dram.cfg.addr_map)

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def pattern(self, seed):
    p = 0
    for b in range(self.row_bytes_c):
      p |= ((seed + b) & 0xFF) << (8 * b)
    return p

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def mk_rd_req(self, addr, beats, tag):
    q = VipDramReq(f"rd_{tag:x}")
    q.op = VipDramOp.RD
    q.addr = addr
    q.beats = beats
    q.tag = tag
    return q

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def mk_wr_req(self, addr, data, tag):
    q = VipDramReq(f"wr_{tag:x}")
    q.op = VipDramOp.WR
    q.addr = addr
    q.beats = 1
    q.tag = tag
    q.wdata = [data]
    q.wstrb = [mask(self.row_bytes_c)]
    return q

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def mk_ref(self, rank, tag):
    q = VipDramReq(f"ref_{tag:x}")
    q.op = VipDramOp.REF
    q.rank = rank
    q.has_explicit_rank = True
    q.tag = tag
    return q

  # ===========================================================================
  # Issue helpers
  # ===========================================================================

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  async def send_checked(self, req):
    target = self.env.sb.n_recv + 1
    self.env.drv.issue(req)
    await self.env.sb.wait_for(target)

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def chk_time(self, nm, got, exp):
    d = abs(got - exp)
    if d <= self.env.sb.tol:
      self.logger.info(f"INFO [{self.tc_name}] {nm} = {got:.3f} ns (ok)")
    else:
      self.logger.error(
        f"ERROR [{self.tc_name}] {nm} = {got:.3f} ns, expected {exp:.3f} ns")
