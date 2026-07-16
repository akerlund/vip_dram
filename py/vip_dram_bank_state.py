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
## vip_dram_bank_state
##
## pyUVM port of vip_dram/sv/vip_dram_bank_state.sv.
##
## Per-bank FSM record (SV §7.3): the open row plus the command/data timestamps
## the scheduler's latency formulas reference. All timestamps are absolute times
## in NANOSECONDS (float), matching the clockless ns model. On construction and
## reset() every timestamp is NEG_LARGE (<= -tRC, effectively -inf) -- NOT 0 -- so
## every "max(now, t_last_* + tXX)" floor collapses to `now` for the first access
## to a freshly-reset bank.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import VipDramBankFsm


class VipDramBankState:

  # -inf sentinel for timestamps. -1e9 ns = -1 s, far below any real -tRC.
  NEG_LARGE = -1.0e9

  def __init__(self):
    self.reset()

  # ---------------------------------------------------------------------------
  # Deterministic, seed-independent initial/post-reset state: IDLE, no open row,
  # every timestamp at -inf.
  # ---------------------------------------------------------------------------
  def reset(self):
    self.state = VipDramBankFsm.IDLE
    self.open_row      = 0
    self.t_last_act    = VipDramBankState.NEG_LARGE # last ACT command (tRAS/tRC/tRRD ref)
    self.t_last_rd     = VipDramBankState.NEG_LARGE # last RD command (tCCD/tRTP/tRTW ref)
    self.t_last_rd_end = VipDramBankState.NEG_LARGE # last RD data-burst end (incl tBL)
    self.t_last_wr     = VipDramBankState.NEG_LARGE # last WR command (tCCD ref)
    self.t_last_wr_end = VipDramBankState.NEG_LARGE # last WR data-burst end (tWTR/tWR ref)
    self.t_last_pre    = VipDramBankState.NEG_LARGE # last PRE command (tRP ref)
    self.pending_pre   = False                      # reserved (closed-page path)
    self.pending_ref   = False                      # reserved
