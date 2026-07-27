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
## vip_dram
##
## pyUVM port of vip_dram/sv/vip_dram.sv.
##
## The protocol-agnostic DDR device model (SV §7.5): a passive uvm_component that
## owns the runtime config, the timing scheduler, and a vip_mem backing store. It
## has NO virtual interface and NO bus dependency; it is driven entirely over a
## neutral TLM contract:
##   - req_fifo : MC -> device, VipDramReq items (DRAM column-access grain)
##   - rsp_port : device -> MC, VipDramRsp items, published after the scheduled
##     latency elapses (echoes req.tag for correlation)
##
## All timing is absolute NANOSECONDS computed against sim_time_ns(). The SV
## fork/join_any/join_none/disable-fork reset dance ports to cocotb tasks: a
## worker drains the fifo, each response is a start_soon task tracked in
## _inflight, and a reset cancels the worker AND every in-flight response task
## before flushing state.
##
################################################################################

from __future__ import annotations

import cocotb
from cocotb.triggers import Event, First

from pyuvm import (
  ConfigDB, UVMConfigItemNotFound, uvm_analysis_port, uvm_component,
  uvm_tlm_analysis_fifo,
)

from vip_mem import vip_mem

from vip_dram_config import VipDramConfig
from vip_dram_rsp import VipDramRsp
from vip_dram_scheduler import VipDramScheduler
from vip_dram_types_pkg import (
  VIP_DRAM_CFG_DEFAULT, VipDramFault, VipDramOp, clog2, data_bits, delay_ns,
  mask, mem_cfg_of, sim_time_ns,
)


# -----------------------------------------------------------------------------
# Persistent-trigger event -- pyUVM has no uvm_event, so this stands in for the
# reset handshake. wait_ptrigger() returns immediately if currently triggered
# (persistent); wait_trigger() waits for the next edge; reset() clears the ON
# state. Mirrors the uvm_event methods vip_dram.sv uses.
# -----------------------------------------------------------------------------
class _UvmEvent:

  def __init__(self):
    self._on = False
    self._ev = Event()

  def trigger(self):
    self._on = True
    self._ev.set()

  def reset(self):
    self._on = False
    self._ev.clear()

  async def wait_ptrigger(self):
    if self._on:
      return
    await self._ev.wait()

  async def wait_trigger(self):
    self._ev.clear()
    await self._ev.wait()


class vip_dram(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg               = None
    self.geom              = None
    self.req_fifo          = None
    self.rsp_port          = None
    self.reset_event       = None
    self._scheduler        = None
    self._mem              = None
    self._reset_done_event = None
    self._inflight         = set()
    # Device read-fault map: row-aligned address -> VipDramFault. Persists across
    # controller reset (a physical device fault does not clear on rst_n).
    self._fault_by_addr = {}

  # ---------------------------------------------------------------------------
  # Build: resolve config, validate it, allocate the store/scheduler/TLM.
  # ---------------------------------------------------------------------------
  def build_phase(self):
    try:
      self.cfg = ConfigDB().get(self, "", "cfg")
    except UVMConfigItemNotFound:
      self.cfg = VipDramConfig("cfg", VIP_DRAM_CFG_DEFAULT)
    self.geom = self.cfg.geom
    self.cfg.validate()

    self._mem = vip_mem("mem", row_bytes=self.geom.ROW_BYTES_P,
                        addr_width=self.geom.ADDR_WIDTH_P)
    self._mem.cfg = self.cfg.mem_cfg          # share the device storage X-handling

    self._scheduler        = VipDramScheduler(self.cfg)
    self.req_fifo          = uvm_tlm_analysis_fifo("req_fifo", self)
    self.rsp_port          = uvm_analysis_port("rsp_port", self)
    self.reset_event       = _UvmEvent()
    self._reset_done_event = _UvmEvent()

    if self.cfg.randomize_mem_on_reset:
      self._mem.randomize_memory()

  # ---------------------------------------------------------------------------
  # Consumer (SV §7.5). A worker drains requests forever; on_reset waits for a
  # reset. First() returns ONLY on reset (work never completes), so we cancel
  # the worker AND every in-flight response task before flushing state.
  # ---------------------------------------------------------------------------
  async def run_phase(self):
    while True:
      work     = cocotb.start_soon(self._work())
      on_reset = cocotb.start_soon(self.reset_event.wait_ptrigger())

      await First(work, on_reset)
      # Reset fired (work never finishes): cancel work + all delayed responses.
      work.cancel()
      if not on_reset.done():
        on_reset.cancel()
      for t in list(self._inflight):
        if not t.done():
          t.cancel()
      self._inflight.clear()

      self.flush_in_flight()
      self.reset_event.reset()          # clear the persistent trigger for next time
      self._reset_done_event.trigger()

  # ---------------------------------------------------------------------------
  # Worker: drain requests forever.
  # ---------------------------------------------------------------------------
  async def _work(self):
    while True:
      req = await self.req_fifo.get()
      self.drive_one(req)

  # ---------------------------------------------------------------------------
  # Schedule one request against live state and fork the time-delayed response.
  # ---------------------------------------------------------------------------
  def drive_one(self, req):

    req.arrival_time = sim_time_ns()
    s = self._scheduler.schedule(req)

    # Prune finished response tasks, then fork this one.
    self._inflight = {t for t in self._inflight if not t.done()}
    t              = cocotb.start_soon(self._drive_response(req, s))
    self._inflight.add(t)

  # ---------------------------------------------------------------------------
  # Sleep until the last (or first) beat is ready, perform the memory access,
  # then publish the response. Cancelled wholesale by reset.
  # ---------------------------------------------------------------------------
  async def _drive_response(self, req, s):
    # §5.4: optionally hand the response over when the first beat is ready.
    deliver_at = s.first if self.cfg.deliver_at_first_beat else s.last
    await delay_ns(deliver_at - sim_time_ns())

    rsp = VipDramRsp("rsp")
    rsp.tag = req.tag
    rsp.op = req.op
    rsp.first_beat_ready_time = s.first
    rsp.last_beat_ready_time = s.last
    rsp.was_page_hit = s.hit
    rsp.was_page_miss = s.miss
    rsp.was_page_empty = s.empty

    self.do_mem_access(req, rsp)
    self.rsp_port.write(rsp)

  # ---------------------------------------------------------------------------
  # Frontdoor memory access. Each column access is one vip_mem row
  # (ROW_BYTES_P); successive beats advance one row. RD returns `beats` rows; WR
  # applies per-beat wstrb. REF touches no memory.
  # ---------------------------------------------------------------------------
  def do_mem_access(self, req, rsp):
    if req.op == VipDramOp.REF:
      return

    a = self._row_align(req.addr)

    # Contract: beats >= 1. Mirror the scheduler's clamp.
    beats_eff = 1 if req.beats == 0 else req.beats

    if req.op == VipDramOp.RD:
      d = self._mem.rd(a, beats_eff)
      rsp.rdata = [int(x) for x in d]

      # Device read-fault: tag the response with the worst fault severity across
      # every row this access touched (one row per beat) and physically corrupt
      # each faulted beat.
      row_bytes = self.geom.ROW_BYTES_P
      DATA_BITS = data_bits(self.geom)
      data_mask = mask(DATA_BITS)
      n_ecc_words = (DATA_BITS // 64) if DATA_BITS >= 64 else 1
      rsp.injected_fault = VipDramFault.NONE
      rsp.corrupt_mask = [0] * beats_eff

      for i in range(beats_eff):
        row_addr = self._row_align(a + (i * row_bytes))
        row_fault = self._fault_by_addr.get(row_addr, VipDramFault.NONE)
        if row_fault > rsp.injected_fault:
          rsp.injected_fault = row_fault

        # Corrupted bit position, varied per row. Choose the low bit INSIDE one
        # 64-bit SECDED word so the UNCORRECTABLE pair (lo, lo^1) lands in that
        # same 64-bit word (a genuine double-bit DUE).
        row_num = row_addr >> clog2(row_bytes)
        ecc_word = row_num % n_ecc_words
        lo = ecc_word * 64 + (row_num % (64 if DATA_BITS >= 64 else DATA_BITS))

        if row_fault == VipDramFault.CORRECTABLE:
          rsp.corrupt_mask[i] = (1 << lo)                 # single-bit, repairable
          rsp.rdata[i] = (rsp.rdata[i] ^ rsp.corrupt_mask[i]) & data_mask
        elif row_fault == VipDramFault.UNCORRECTABLE:
          rsp.rdata[i] ^= (1 << lo)                        # double-bit DUE:
          rsp.rdata[i] ^= (1 << (lo ^ 1))                 # flipped, mask stays 0
          rsp.rdata[i] &= data_mask
    else:  # VipDramOp.WR
      # Contract: one wdata/wstrb element per column access (beats elements).
      if len(req.wdata) != req.beats:
        self.logger.error(
          f"WR beats = {req.beats} but wdata.size = {len(req.wdata)} "
          f"(expected equal); timing modelled for beats")

      if len(req.wstrb) != len(req.wdata):
        self.logger.error(
          f"WR wstrb.size = {len(req.wstrb)} != wdata.size = {len(req.wdata)}; "
          f"missing strobes default to all-enable")

      all_strb = mask(self.geom.ROW_BYTES_P)
      d = []
      be = []
      for i in range(len(req.wdata)):
        d.append(req.wdata[i])
        be.append(req.wstrb[i] if i < len(req.wstrb) else all_strb)

      self._mem.wr_be(a, d, be)

  # ---------------------------------------------------------------------------
  # On reset: empty the request queue, reset all scheduler state, and
  # (optionally) re-randomize memory. In-flight responses were already killed.
  # ---------------------------------------------------------------------------
  def flush_in_flight(self):
    self.req_fifo.flush()
    self._scheduler.reset()
    if self.cfg.randomize_mem_on_reset:
      self._mem.randomize_memory()

  # ---------------------------------------------------------------------------
  # Reset (SV §8). Triggers reset_event (which the consumer waits on) and blocks
  # until the drain completes.
  # ---------------------------------------------------------------------------
  async def reset(self):
    self.reset_event.trigger()
    await self._reset_done_event.wait_trigger()

  # ---------------------------------------------------------------------------
  # Side-effect-free latency predictor for the MC / scoreboard. Returns
  # (first_beat_ready, last_beat_ready).
  # ---------------------------------------------------------------------------
  def predict(self, req):
    s = self._scheduler.predict(req)
    return s.first, s.last

  # ---------------------------------------------------------------------------
  # Debug counters (events EXECUTED BY THE DEVICE).
  # ---------------------------------------------------------------------------
  def get_page_hit_count(self):
    return self._scheduler.n_page_hit

  def get_page_miss_count(self):
    return self._scheduler.n_page_miss

  def get_page_empty_count(self):
    return self._scheduler.n_page_empty

  def get_refresh_count(self):
    return self._scheduler.n_ref

  # ===========================================================================
  # Backdoor API (SV §4) -- bypasses timing; operates directly on the store.
  # ===========================================================================

  # Write one column-access row at the row containing `addr` (all bytes).
  def backdoor_write(self, addr, data):
    a = self._row_align(addr)
    self._mem.wr(a, [data])

  # Read the column-access row at the row containing `addr`.
  def backdoor_read(self, addr):
    a = self._row_align(addr)
    return self._mem.rd_addr(a)

  # Randomize the whole image (or a byte range).
  def memory_randomize(self, addr_lo=0, addr_hi=None):
    if addr_hi is None:
      addr_hi = (1 << self.geom.ADDR_WIDTH_P) - 1
    self._mem.randomize_memory(addr_lo, addr_hi)

  # Clear the whole image.
  def memory_reset(self):
    self._mem.reset()

  # Whole-image dump/load.
  def backdoor_dump(self):
    return self._mem.get()

  def backdoor_load(self, img):
    self._mem.set(img)

  # ===========================================================================
  # Device read-fault injection (SV §11 item 5) -- deterministic, addressable.
  # ===========================================================================

  # Mark the row containing `addr` as returning `fault` severity on reads.
  def inject_fault(self, addr, fault):
    a = self._row_align(addr)
    if fault == VipDramFault.NONE:
      self._fault_by_addr.pop(a, None)
    else:
      self._fault_by_addr[a] = fault

  # Clear any injected fault on the row containing `addr`.
  def clear_fault(self, addr):
    a = self._row_align(addr)
    self._fault_by_addr.pop(a, None)

  # Remove every injected fault.
  def clear_all_faults(self):
    self._fault_by_addr.clear()

  # Read back the injected fault severity for the row containing `addr`.
  def get_fault(self, addr):
    a = self._row_align(addr)
    return self._fault_by_addr.get(a, VipDramFault.NONE)

  # ---------------------------------------------------------------------------
  # Row-align a byte address to the column-access (ROW_BYTES_P) granularity.
  # ---------------------------------------------------------------------------
  def _row_align(self, addr):
    sh = clog2(self.geom.ROW_BYTES_P)
    return (int(addr) >> sh) << sh
