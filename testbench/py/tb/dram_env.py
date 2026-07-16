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
## dram_env
##
## pyUVM port of testbench/sv/tb/dram_env.sv.
##
## The device-only verification environment (SV §12.1): the vip_dram device under
## test, a tiny dram_driver, and a dram_scoreboard, wired over the neutral TLM
## contract --
##
## driver.req_ap --> dram.req_fifo.analysis_export (requests in)
## dram.rsp_port --> scoreboard.analysis_export (responses out)
##
## No DUT RTL, no clock, no bus. A test reaches `dram` (predict/backdoor/reset/
## counters), `drv` (issue/send), and `sb` (expect/wait/fetch).
##
################################################################################

from __future__ import annotations

from pyuvm import uvm_env

from vip_dram import vip_dram
from dram_driver import dram_driver
from dram_scoreboard import dram_scoreboard


class dram_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.dram = None
    self.drv  = None
    self.sb   = None

  def build_phase(self):
    self.dram = vip_dram("dram", self)
    self.drv  = dram_driver("drv", self)
    self.sb   = dram_scoreboard("sb", self)

  def connect_phase(self):
    self.drv.req_ap.connect(self.dram.req_fifo.analysis_export)
    self.dram.rsp_port.connect(self.sb.analysis_export)
    self.drv.dram = self.dram
    self.drv.sb   = self.sb
    self.sb.tol   = self.dram.cfg.timing.t_ck   # 1-cycle tolerance
