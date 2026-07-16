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
## dram_scoreboard
##
## pyUVM port of testbench/sv/tb/dram_scoreboard.sv.
##
## Predictor-vs-observed checker for the vip_dram device-only contract tests
## (SV §12.2). Subscribes to the device's rsp_port (via the uvm_subscriber
## analysis_export) and, for any response whose tag has a registered expectation,
## compares the timing (first/last beat ready, within a 1-cycle t_ck tolerance)
## and the page classification (hit/miss/empty), logging a uvm_error on mismatch.
## Responses are stored by tag so a test can fetch one and assert on it directly.
##
################################################################################

from __future__ import annotations

from cocotb.triggers import Event

from pyuvm import uvm_subscriber


class dram_scoreboard(uvm_subscriber):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self._exp = {}   # tag -> expectation dict
    self._got = {}   # tag -> rsp
    # 1-cycle timing tolerance (set from cfg.t_ck by the env).
    self.tol = 0.0
    # Observed-response count (tests wait on it) and check tallies.
    self.n_recv = 0
    self.n_time_ok = 0
    self.n_time_bad = 0
    self.n_page_ok = 0
    self.n_page_bad = 0
    self._recv_ev = Event()

  @staticmethod
  def _blank():
    return dict(first=0.0, last=0.0, check_time=False,
                hit=False, miss=False, empty=False, check_page=False)

  # ---------------------------------------------------------------------------
  # Register expected first/last beat times for a tag (from predict()).
  # ---------------------------------------------------------------------------
  def expect_timed(self, tag, first, last):
    e = self._exp.setdefault(tag, self._blank())
    e["first"] = first
    e["last"] = last
    e["check_time"] = True

  # ---------------------------------------------------------------------------
  # Register expected page classification for a tag (the scenario knows it).
  # ---------------------------------------------------------------------------
  def expect_page(self, tag, hit, miss, empty):
    e = self._exp.setdefault(tag, self._blank())
    e["hit"] = bool(hit)
    e["miss"] = bool(miss)
    e["empty"] = bool(empty)
    e["check_page"] = True

  # ---------------------------------------------------------------------------
  # Analysis write: store + compare against any registered expectation.
  # ---------------------------------------------------------------------------
  def write(self, rsp):
    self._got[rsp.tag] = rsp
    self.n_recv += 1

    if rsp.tag in self._exp:
      e = self._exp[rsp.tag]

      if e["check_time"]:
        if (self._approx(rsp.first_beat_ready_time, e["first"]) and
            self._approx(rsp.last_beat_ready_time, e["last"])):
          self.n_time_ok += 1
        else:
          self.n_time_bad += 1
          self.logger.error(
            f"ERROR [{self.get_name()}] tag {rsp.tag:x} TIMING: got "
            f"first={rsp.first_beat_ready_time:.3f} "
            f"last={rsp.last_beat_ready_time:.3f}, expected "
            f"first={e['first']:.3f} last={e['last']:.3f} (tol={self.tol:.3f})")

      if e["check_page"]:
        if (bool(rsp.was_page_hit) == e["hit"] and
            bool(rsp.was_page_miss) == e["miss"] and
            bool(rsp.was_page_empty) == e["empty"]):
          self.n_page_ok += 1
        else:
          self.n_page_bad += 1
          self.logger.error(
            f"ERROR [{self.get_name()}] tag {rsp.tag:x} PAGE: got hit/miss/empty="
            f"{int(bool(rsp.was_page_hit))}/{int(bool(rsp.was_page_miss))}/"
            f"{int(bool(rsp.was_page_empty))}, expected "
            f"{int(e['hit'])}/{int(e['miss'])}/{int(e['empty'])}")

    self._recv_ev.set()

  # ---------------------------------------------------------------------------
  # Fetch a stored response by tag (None if not yet received).
  # ---------------------------------------------------------------------------
  def get_rsp(self, tag):
    return self._got.get(tag)

  # ---------------------------------------------------------------------------
  # Block until at least `n` responses have been observed.
  # ---------------------------------------------------------------------------
  async def wait_for(self, n):
    while self.n_recv < n:
      self._recv_ev.clear()
      if self.n_recv >= n:
        return
      await self._recv_ev.wait()

  # ---------------------------------------------------------------------------
  # |a - b| <= tol.
  # ---------------------------------------------------------------------------
  def _approx(self, a, b):
    return abs(a - b) <= self.tol

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def report_phase(self):
    self.logger.info(
      f"INFO [{self.get_name()}] responses={self.n_recv}  "
      f"timing ok/bad={self.n_time_ok}/{self.n_time_bad}  "
      f"page ok/bad={self.n_page_ok}/{self.n_page_bad}")
