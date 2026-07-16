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
## vip_dram_rsp
##
## pyUVM port of vip_dram/sv/vip_dram_rsp.sv.
##
## Neutral, protocol-agnostic response item published by vip_dram on its rsp_port
## after a request's scheduled latency elapses. The device echoes the caller's
## `tag`. The timing contract is two absolute times (ns): the readiness of the
## first and last column accesses (equal for beats == 1). rdata/corrupt_mask are
## plain int lists. Not a randomization item -- populated by the device.
##
################################################################################

from __future__ import annotations

from pyuvm import uvm_sequence_item

from vip_dram_types_pkg import VipDramFault, VipDramOp


class VipDramRsp(uvm_sequence_item):

  def __init__(self, name="vip_dram_rsp"):
    super().__init__(name)

    # Echo of vip_dram_req.tag.
    self.tag = 0

    # Operation this response completes (RD returns rdata; WR/REF carry none).
    self.op = VipDramOp.RD

    # Read payload -- one element per column access (RD only; empty for WR/REF).
    self.rdata = []

    # Timing contract -- absolute readiness times in NANOSECONDS (float).
    self.first_beat_ready_time = 0.0
    self.last_beat_ready_time  = 0.0

    # Page classification (mutually exclusive; all 0 for REF).
    self.was_page_hit   = False
    self.was_page_miss  = False
    self.was_page_empty = False

    # Device read-fault severity (set on RD). The payload IS physically
    # corrupted; corrupt_mask[i] is the per-beat XOR a SECDED decoder can repair
    # (single-bit flip of a correctable beat; 0 for an uncorrectable one).
    self.injected_fault = VipDramFault.NONE
    self.corrupt_mask = []

  # ---------------------------------------------------------------------------
  # Explicit do_copy -- house style avoids the field-automation macros.
  # ---------------------------------------------------------------------------
  def do_copy(self, rhs):
    super().do_copy(rhs)
    self.tag                   = rhs.tag
    self.op                    = rhs.op
    self.rdata                 = list(rhs.rdata)
    self.first_beat_ready_time = rhs.first_beat_ready_time
    self.last_beat_ready_time  = rhs.last_beat_ready_time
    self.was_page_hit          = rhs.was_page_hit
    self.was_page_miss         = rhs.was_page_miss
    self.was_page_empty        = rhs.was_page_empty
    self.injected_fault        = rhs.injected_fault
    self.corrupt_mask          = list(rhs.corrupt_mask)

  # ---------------------------------------------------------------------------
  # Explicit do_compare. Times/page flags are observables, not response
  # identity; identity covers tag/op/rdata.
  # ---------------------------------------------------------------------------
  def do_compare(self, rhs, comparer=None):
    result  = True
    result &= (self.tag == rhs.tag)
    result &= (self.op == rhs.op)
    result &= (len(self.rdata) == len(rhs.rdata))
    if result:
      for a, b in zip(self.rdata, rhs.rdata):
        result &= (a == b)
    return bool(result)

  # ---------------------------------------------------------------------------
  # Readable single-line summary.
  # ---------------------------------------------------------------------------
  def convert2string(self):
    page = ("hit" if self.was_page_hit else
            "miss" if self.was_page_miss else
            "empty" if self.was_page_empty else "n/a")
    return (f"RSP: op = {self.op.name} tag = {self.tag:x} "
            f"rdata.size = {len(self.rdata)} "
            f"first = {self.first_beat_ready_time:.3f} ns "
            f"last = {self.last_beat_ready_time:.3f} ns page = {page} "
            f"fault = {self.injected_fault.name}")
