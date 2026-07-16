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
## vip_dram_scheduler
##
## pyUVM port of vip_dram/sv/vip_dram_scheduler.sv.
##
## The timing core (SV §7.4). Given a neutral VipDramReq it computes the absolute
## readiness time of the first and last column accesses from the per-bank state
## and the cfg timing record, then commits the state update. All times are
## NANOSECONDS (float); the device computes against sim_time_ns() (no clock).
##
## Single source of truth: the formula lives ONLY in the pure, side-effect-free
## compute_latency(). predict() (MC/scoreboard) and schedule() (the device) both
## RETURN a ResultT (the two readiness times + page classification). schedule()
## additionally calls commit_state(), the ONLY place bank/rank state is mutated.
## Each delay is quantized UP to whole DRAM clock cycles via quantize().
##
################################################################################

from __future__ import annotations

from dataclasses import dataclass, field

from vip_dram_addr_pkg import vip_dram_bank_index, vip_dram_decode_addr
from vip_dram_bank_state import VipDramBankState
from vip_dram_types_pkg import VipDramBankFsm, VipDramOp, sim_time_ns

NEG_LARGE = VipDramBankState.NEG_LARGE


# -----------------------------------------------------------------------------
# Public result of predict()/schedule(): the timing contract (two absolute
# readiness times) plus the page classification. hit/miss/empty are mutually
# exclusive and all False for a REF (is_ref set instead).
# -----------------------------------------------------------------------------
@dataclass
class ResultT:
  first:  float = 0.0   # data ready, column access 0
  last:   float = 0.0   # data ready, column access beats-1 (== first when beats==1)
  hit:    bool  = False # bank was open on the requested row
  miss:   bool  = False # bank was open on a different row
  empty:  bool  = False # bank was precharged/closed
  is_ref: bool  = False # REF request (hit/miss/empty all False)


# -----------------------------------------------------------------------------
# Internal latency result -- everything compute_latency() produces, so
# commit_state() never recomputes.
# -----------------------------------------------------------------------------
@dataclass
class LatT:
  first:         float = 0.0
  last:          float = 0.0
  cas0:          float = 0.0
  cas_last:      float = 0.0
  act_time:      float = 0.0
  pre_at:        float = 0.0
  burst_end:     float = 0.0
  idx:           int   = 0
  rank:          int   = 0
  bg:            int   = 0
  row:           int   = 0
  is_read:       bool  = False
  did_activate:  bool  = False
  did_precharge: bool  = False
  is_ref:        bool  = False
  hit:           bool  = False
  miss:          bool  = False
  empty:         bool  = False


class VipDramScheduler:

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  def __init__(self, cfg):
    self.cfg            = cfg      # VipDramConfig (timing + addr_map + flags)
    self.geom           = cfg.geom # device geometry (SV CFG_P)
    self.BANKS_PER_RANK = self.geom.N_BANK_GROUPS_P * self.geom.BANKS_PER_BG_P
    self.N_RANKS        = self.geom.N_RANKS_P
    self.N_BG           = self.geom.N_BANK_GROUPS_P
    self.reset()

  # ---------------------------------------------------------------------------
  # Allocate + clear all state. Deterministic and seed-independent: every bank
  # IDLE, FAW rings empty, every timestamp -inf, counters zeroed.
  # ---------------------------------------------------------------------------
  def reset(self):
    n_banks   = self.N_RANKS * self.BANKS_PER_RANK
    self.bank = [VipDramBankState() for _ in range(n_banks)]

    # Rank-level activate tracking for tRRD / tFAW.
    self.last_act_any = [NEG_LARGE] * self.N_RANKS
    self.last_act_bg  = [[NEG_LARGE] * self.N_BG for _ in range(self.N_RANKS)]
    self.faw_ring     = [[NEG_LARGE] * 4 for _ in range(self.N_RANKS)]
    self.faw_wp       = [0] * self.N_RANKS

    # Rank-level CAS tracking for column spacing + bus turnaround.
    self.last_cas_any    = [NEG_LARGE] * self.N_RANKS
    self.last_cas_bg     = [[NEG_LARGE] * self.N_BG for _ in range(self.N_RANKS)]
    self.last_wr_end_any = [NEG_LARGE] * self.N_RANKS
    self.last_wr_end_bg  = [[NEG_LARGE] * self.N_BG for _ in range(self.N_RANKS)]
    self.last_rd_cas_any = [NEG_LARGE] * self.N_RANKS

    # Channel-level bus + per-rank refresh state.
    self.last_burst_end_chan = NEG_LARGE
    self.rank_busy = [NEG_LARGE] * self.N_RANKS

    # Debug counters (public reads).
    self.n_page_hit   = 0
    self.n_page_miss  = 0
    self.n_page_empty = 0
    self.n_ref        = 0

  # ---------------------------------------------------------------------------
  # Side-effect-free predictor (MC / scoreboard).
  # ---------------------------------------------------------------------------
  def predict(self, req):
    return self._pack(self.compute_latency(req))

  # ---------------------------------------------------------------------------
  # Scheduler: compute against live state, commit, bump counters, return the
  # timing + page classification.
  # ---------------------------------------------------------------------------
  def schedule(self, req):
    r = self.compute_latency(req)
    self.commit_state(r)
    if r.is_ref:
      self.n_ref += 1
    elif r.hit:
      self.n_page_hit += 1
    elif r.miss:
      self.n_page_miss += 1
    elif r.empty:
      self.n_page_empty += 1
    return self._pack(r)

  # ---------------------------------------------------------------------------
  # Project the internal LatT down to the public ResultT.
  # ---------------------------------------------------------------------------
  @staticmethod
  def _pack(r):
    return ResultT(first=r.first, last=r.last, hit=r.hit, miss=r.miss,
                   empty=r.empty, is_ref=r.is_ref)

  # ===========================================================================
  # The ONLY place the §7.4 formulas live. Pure: reads bank/rank arrays and
  # cfg.timing, returns the timing, mutates nothing.
  # ===========================================================================
  def compute_latency(self, req):
    r = LatT()
    t = self.cfg.timing

    # -- REF: blocks the whole rank for tRFC, then precharge-all -------------
    if req.op == VipDramOp.REF:
      rank = req.rank
      if rank >= self.N_RANKS:
        raise RuntimeError(
          f"vip_dram_scheduler: REF rank {rank} out of range "
          f"(N_RANKS_P = {self.N_RANKS})")
      r.is_ref = True
      r.rank   = rank
      now      = self._rank_last_op(rank)          # already folds in sim time
      r.first  = now + self._quantize(t.tRFC)
      r.last   = r.first
      return r

    # -- Decode address -> {rank,bg,bank,row}; flatten the bank index --------
    d = vip_dram_decode_addr(req.addr, self.geom, self.cfg.addr_map)
    r.rank = req.rank if req.has_explicit_rank else d.rank
    if r.rank >= self.N_RANKS:
      raise RuntimeError(
        f"vip_dram_scheduler: RD/WR rank {r.rank} out of range "
        f"(N_RANKS_P = {self.N_RANKS}); check has_explicit_rank/rank or addr_map")
    r.bg      = d.bg
    r.row     = d.row
    r.idx     = r.rank * self.BANKS_PER_RANK + vip_dram_bank_index(self.geom, d)
    r.is_read = (req.op == VipDramOp.RD)
    beats     = 1 if req.beats == 0 else req.beats   # contract: beats >= 1
    b         = self.bank[r.idx]

    # `now` floors every term and serves the REF block.
    now = self._maxr(sim_time_ns(), self.rank_busy[r.rank])

    # -- Classify the first column access ------------------------------------
    r.hit   = (b.state == VipDramBankFsm.ACTIVE) and (b.open_row == r.row)
    r.miss  = (b.state == VipDramBankFsm.ACTIVE) and (b.open_row != r.row)
    r.empty = (b.state != VipDramBankFsm.ACTIVE)

    if r.hit:
      r.act_time = b.t_last_act   # unchanged, no new ACT
      cas_floor = now
    else:
      r.did_activate = True
      if r.miss:
        # Different row open: PRE (respecting tRTP/tWR/tRAS) then ACT (+tRP).
        r.did_precharge = True
        r.pre_at = self._max3(b.t_last_rd + self._quantize(t.tRTP),
                              b.t_last_wr_end + self._quantize(t.tWR),
                              b.t_last_act + self._quantize(t.tRAS))
        r.pre_at = self._maxr(now, r.pre_at)
        act_ready = r.pre_at + self._quantize(t.tRP)
      else:
        # Bank closed/precharged: ACT can issue once the prior PRE settled.
        act_ready = self._maxr(now, b.t_last_pre + self._quantize(t.tRP))
      r.act_time = self._gate_activate(r.rank, r.bg, act_ready)  # tRRD + tFAW
      cas_floor = r.act_time + self._quantize(t.tRCD)

    # -- Rank-level CAS scheduling: column spacing (tCCD) + bus turnaround ----
    r.cas0 = self._max3(cas_floor,
                        self.last_cas_bg[r.rank][r.bg] + self._quantize(t.tCCD_L),
                        self.last_cas_any[r.rank] + self._quantize(t.tCCD_S))
    if r.is_read:
      r.cas0 = self._max3(r.cas0,
                          self.last_wr_end_bg[r.rank][r.bg] + self._quantize(t.tWTR_L),
                          self.last_wr_end_any[r.rank] + self._quantize(t.tWTR_S))
    else:
      r.cas0 = self._maxr(r.cas0,
                          self.last_rd_cas_any[r.rank] + self._quantize(t.tRTW))

    # -- Per-beat data readiness + bus contention ---------------------------
    add0 = self._quantize(t.tCL) if r.is_read else self._quantize(t.tWL)
    r.first = r.cas0 + add0

    # Bus contention: the channel DQ bus carries one burst (tBL) at a time.
    if self.cfg.enable_bus_contention:
      r.first = self._maxr(r.first, self.last_burst_end_chan)

    # Effective CAS after any bus delay keeps cas_last / commit consistent.
    r.cas0      = r.first - add0
    r.cas_last  = r.cas0 + float(beats - 1) * self._quantize(t.tCCD_L)
    r.last      = r.cas_last + add0
    r.burst_end = r.last + self._quantize(t.tBL)   # last data-burst end

    return r

  # ---------------------------------------------------------------------------
  # The ONLY mutation point. Applies compute_latency()'s result to live state.
  # ---------------------------------------------------------------------------
  def commit_state(self, r):
    # -- REF: precharge-all on the rank, mark it busy until tRFC completes ----
    if r.is_ref:
      for k in range(self.BANKS_PER_RANK):
        b                    = self.bank[r.rank * self.BANKS_PER_RANK + k]
        b.state              = VipDramBankFsm.IDLE
        b.open_row           = 0
        b.t_last_pre         = NEG_LARGE   # refreshed = fresh PRE
      self.rank_busy[r.rank] = r.first     # rank free again at REF end
      return

    b = self.bank[r.idx]

    if r.did_activate:
      if r.did_precharge:
        b.t_last_pre = r.pre_at
      b.t_last_act = r.act_time
      b.state      = VipDramBankFsm.ACTIVE
      b.open_row   = r.row

      # Rank ACT tracking for tRRD / tFAW.
      self.last_act_any[r.rank]      = r.act_time
      self.last_act_bg[r.rank][r.bg] = r.act_time
      self._faw_push(r.rank, r.act_time)

    if r.is_read:
      b.t_last_rd     = r.cas_last
      b.t_last_rd_end = r.burst_end   # read DATA-burst end (incl tBL)
    else:
      b.t_last_wr     = r.cas_last
      b.t_last_wr_end = r.burst_end   # tWTR/tWR reference the last WR DATA

    # Rank-level CAS spacing: both directions advance the column-access clock.
    self.last_cas_bg[r.rank][r.bg] = r.cas_last
    self.last_cas_any[r.rank]      = r.cas_last
    if r.is_read:
      self.last_rd_cas_any[r.rank] = r.cas_last          # tRTW reference (RD command)
    else:
      self.last_wr_end_bg[r.rank][r.bg] = r.burst_end    # tWTR reference (WR data end)
      self.last_wr_end_any[r.rank]      = r.burst_end

    # Channel-wide data-bus contention (shared by all ranks in the channel).
    self.last_burst_end_chan = r.burst_end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # Quantize a ns delay UP to whole DRAM clock cycles. Identity for the DDR4
  # preset; 0 for IDEAL.
  # ---------------------------------------------------------------------------
  def _quantize(self, ns):
    return float(self.cfg.ns_to_cycles(ns)) * self.cfg.timing.t_ck

  # ---------------------------------------------------------------------------
  # Real max helpers.
  # ---------------------------------------------------------------------------
  @staticmethod
  def _maxr(a, b):
    return a if a > b else b

  def _max3(self, a, b, c):
    return self._maxr(self._maxr(a, b), c)

  # ---------------------------------------------------------------------------
  # Gate an ACT by the rank ACT-spacing rules: tRRD_S, tRRD_L, tFAW.
  # ---------------------------------------------------------------------------
  def _gate_activate(self, rank, bg, earliest):
    t = self.cfg.timing
    g = earliest
    g = self._maxr(g, self.last_act_any[rank]    + self._quantize(t.tRRD_S))
    g = self._maxr(g, self.last_act_bg[rank][bg] + self._quantize(t.tRRD_L))
    g = self._maxr(g, self._faw_oldest(rank)     + self._quantize(t.tFAW))
    return g

  # ---------------------------------------------------------------------------
  # Oldest of the rank's last four ACT command times (the FAW window anchor).
  # ---------------------------------------------------------------------------
  def _faw_oldest(self, rank):
    m = self.faw_ring[rank][0]
    for k in range(1, 4):
      if self.faw_ring[rank][k] < m:
        m = self.faw_ring[rank][k]
    return m

  # ---------------------------------------------------------------------------
  # Push an ACT time into the rank's 4-deep ring (overwrites the oldest slot).
  # ---------------------------------------------------------------------------
  def _faw_push(self, rank, act_time):
    self.faw_ring[rank][self.faw_wp[rank]] = act_time
    self.faw_wp[rank] = (self.faw_wp[rank] + 1) % 4

  # ---------------------------------------------------------------------------
  # Latest activity on a rank (for the REF block).
  # ---------------------------------------------------------------------------
  def _rank_last_op(self, rank):
    m = self._maxr(sim_time_ns(), self.rank_busy[rank])
    for k in range(self.BANKS_PER_RANK):
      b = self.bank[rank * self.BANKS_PER_RANK + k]
      m = self._maxr(m, b.t_last_act)
      m = self._maxr(m, b.t_last_rd_end)
      m = self._maxr(m, b.t_last_wr_end)
      m = self._maxr(m, b.t_last_pre)
    return m
