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
## vip_dram_req
##
## pyUVM port of vip_dram/sv/vip_dram_req.sv.
##
## Neutral, protocol-agnostic memory-request item carried into vip_dram over a
## TLM analysis FIFO (no virtual interface, no bus, no clock). The caller owns the
## AXI4->DRAM translation and hands the device a request already expressed in DRAM
## column-access ("beat") granularity. Not a randomization item: fields are
## populated directly (no `rand`). wdata/wstrb are plain Python int lists (the SV
## width typedefs collapse to unbounded ints).
##
################################################################################

from __future__ import annotations

from pyuvm import uvm_sequence_item

from vip_dram_types_pkg import VipDramOp


class VipDramReq(uvm_sequence_item):

  def __init__(self, name="vip_dram_req"):
    super().__init__(name)

    # Byte address (RD/WR only; ignored for REF).
    self.addr = 0

    # Operation. REF ignores addr/wdata/wstrb; it refreshes the rank named by
    # `rank` directly.
    self.op = VipDramOp.RD

    # Number of DRAM column accesses (BL8 bursts) -- NOT AXI4 bus beats. >= 1 for
    # RD/WR; ignored for REF.
    self.beats = 1

    # Rank selection for RD/WR. has_explicit_rank False: derive rank from addr.
    # True: force `rank` verbatim (the device skips address slicing).
    self.has_explicit_rank = False
    self.rank = 0

    # Write payload -- one element per column access (`beats` elements). Empty
    # for RD/REF. Lists of ints (each one column-access word / strobe).
    self.wdata = []
    self.wstrb = []

    # Caller's private tag -- echoed on the response for correlation.
    self.tag = 0

    # Filled by vip_dram on accept. Absolute time in NANOSECONDS (float).
    self.arrival_time = 0.0

  # ---------------------------------------------------------------------------
  # Explicit do_copy -- house style avoids the field-automation macros.
  # ---------------------------------------------------------------------------
  def do_copy(self, rhs):
    super().do_copy(rhs)
    self.addr              = rhs.addr
    self.op                = rhs.op
    self.beats             = rhs.beats
    self.has_explicit_rank = rhs.has_explicit_rank
    self.rank              = rhs.rank
    self.wdata             = list(rhs.wdata)
    self.wstrb             = list(rhs.wstrb)
    self.tag               = rhs.tag
    self.arrival_time      = rhs.arrival_time

  # ---------------------------------------------------------------------------
  # Explicit do_compare. arrival_time is device bookkeeping, not identity.
  # ---------------------------------------------------------------------------
  def do_compare(self, rhs, comparer=None):
    result = True
    result &= (self.addr == rhs.addr)
    result &= (self.op == rhs.op)
    result &= (self.beats == rhs.beats)
    result &= (self.has_explicit_rank == rhs.has_explicit_rank)
    result &= (self.rank == rhs.rank)
    result &= (len(self.wdata) == len(rhs.wdata))
    result &= (len(self.wstrb) == len(rhs.wstrb))
    if result:
      for a, b in zip(self.wdata, rhs.wdata):
        result &= (a == b)
      for a, b in zip(self.wstrb, rhs.wstrb):
        result &= (a == b)
    return bool(result)

  # ---------------------------------------------------------------------------
  # Readable single-line summary.
  # ---------------------------------------------------------------------------
  def convert2string(self):
    if self.op == VipDramOp.REF:
      return (f"REQ: op = {self.op.name} rank = {self.rank} "
              f"tag = {self.tag:x}")
    rank_s = (f"rank = {self.rank} (forced)" if self.has_explicit_rank
              else "rank = (decode)")
    return (f"REQ: op = {self.op.name} addr = 0x{self.addr:x} "
            f"beats = {self.beats} {rank_s} tag = {self.tag:x} "
            f"wdata.size = {len(self.wdata)}")
