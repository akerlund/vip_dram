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
## dram_driver
##
## pyUVM port of testbench/sv/tb/dram_driver.sv.
##
## Tiny TLM driver for the device-only contract tests. It owns the analysis port
## wired into vip_dram.req_fifo and offers two ways to push a request:
##   - send(req) : fire-and-forget (back-to-back tests that assert on the
##     relationships between collected responses).
##   - issue(req) : the §12.2 checked path -- ask the device's predict() for the
##     expected first/last beat times, register them with the
##     scoreboard (keyed by req.tag), then send. Valid only with a
##     single outstanding request (predict() reads the current
##     committed state), so a test must let the prior response retire.
##
## Handles to the device and scoreboard are wired by the env in connect_phase.
##
################################################################################

from __future__ import annotations

from pyuvm import uvm_analysis_port, uvm_component


class dram_driver(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.req_ap = None
    # Wired by the env (connect_phase).
    self.dram = None
    self.sb = None

  def build_phase(self):
    self.req_ap = uvm_analysis_port("req_ap", self)

  # ---------------------------------------------------------------------------
  # Fire-and-forget send (no expectation registered).
  # ---------------------------------------------------------------------------
  def send(self, req):
    self.req_ap.write(req)

  # ---------------------------------------------------------------------------
  # Checked send: predict the timing now (single-outstanding only), register it
  # with the scoreboard, then push the request.
  # ---------------------------------------------------------------------------
  def issue(self, req):
    first, last = self.dram.predict(req)
    self.sb.expect_timed(req.tag, first, last)
    self.req_ap.write(req)
