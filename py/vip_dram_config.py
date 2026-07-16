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
## vip_dram_config
##
## pyUVM port of vip_dram/sv/vip_dram_config.sv.
##
## Runtime (non-geometry) device properties for vip_dram: the timing record, the
## address-map slicing, page policy, behavioural flags, and the storage
## primitive's X-handling (mem_cfg). Geometry/channel widths are the SV compile-
## time CFG_P; the Python port carries them as `self.geom` (a VipDramCfgT), so
## validate() and the default address map can be derived from them.
##
## Timing is stored in ns; callers convert to whole DRAM clock cycles via
## ns_to_cycles(). apply_preset() loads the speed-bin AC timings, then re-derives
## tRFC from the per-die density implied by the geometry. uvm_fatal violations
## raise RuntimeError; uvm_warnings go to the module logger.
##
################################################################################

from __future__ import annotations

import logging

from vip_mem_config import vip_mem_config

from vip_dram_timing_pkg import (
  VipDramPreset, VipDramTimingT, vip_dram_get_preset, vip_dram_ns_to_cycles,
  vip_dram_preset_gen, vip_dram_trfc_max_gbit, vip_dram_trfc_ns,
)
from vip_dram_types_pkg import (
  VIP_DRAM_CFG_DEFAULT, VipDramPagePolicy, clog2, vip_dram_default_addr_map,
)

_logger = logging.getLogger("vip_dram_config")

TIMING_EPS = 1.0e-9  # real-compare slack (ns)


class VipDramConfig:

  # ---------------------------------------------------------------------------
  # mem_cfg is allocated here and never None thereafter; timing is seeded to the
  # DDR4-3200 default. `geom` is the device geometry (SV CFG_P). Both timing and
  # geom are freely overridable afterwards.
  # ---------------------------------------------------------------------------
  def __init__(self, name="vip_dram_config", geom=VIP_DRAM_CFG_DEFAULT):

    self.name = name
    self.geom = geom

    # Timing (ns) -- source of truth. Loaded by apply_preset(); overridable.
    self.timing = VipDramTimingT()

    # The speed-bin preset last applied.
    self.preset = VipDramPreset.DDR4_3200_CL22

    # Address-map slicing. Defaults to the geometry-derived LSB-first layout.
    self.addr_map = vip_dram_default_addr_map(geom)

    # Policy / behavioural flags.
    self.page_policy = VipDramPagePolicy.OPEN
    self.enable_bus_contention = True     # channel-level tBL spacing
    self.enable_bank_scoreboard = False   # debug logging
    self.randomize_mem_on_reset = False

    # Deliver the response when the FIRST beat is ready (vs at last).
    self.deliver_at_first_beat = False

    # Device-storage X-handling for the owned vip_mem.
    self.mem_cfg = vip_mem_config("mem_cfg")
    self.apply_preset(VipDramPreset.DDR4_3200_CL22)

  # ---------------------------------------------------------------------------
  # Load the speed-bin AC timings from a preset, then re-derive tRFC from the
  # per-die density (geometry). tRFC scales with die size, not the speed bin.
  # ---------------------------------------------------------------------------
  def apply_preset(self, preset):
    self.preset = preset
    self.timing = vip_dram_get_preset(preset)
    self.timing.tRFC = vip_dram_trfc_ns(vip_dram_preset_gen(preset),
                                        self.density_gbit())

  # ---------------------------------------------------------------------------
  # Per-die density in Gbit, derived from the geometry.
  # ---------------------------------------------------------------------------
  def density_gbit(self):
    g = self.geom
    per_die_bits = ((1 << g.ADDR_WIDTH_P) * 8) // (g.N_DEVICES_PER_RANK_P * g.N_RANKS_P)
    return per_die_bits >> 30   # bits -> Gbit

  # ---------------------------------------------------------------------------
  # Round a nanosecond timing value up to whole DRAM clock cycles using t_ck.
  # ---------------------------------------------------------------------------
  def ns_to_cycles(self, ns):
    return vip_dram_ns_to_cycles(ns, self.timing.t_ck)

  # ---------------------------------------------------------------------------
  # Sanity checks (SV §7.1). Fatal violations raise RuntimeError; the address-
  # width coverage / page-policy checks are warnings.
  # ---------------------------------------------------------------------------
  def validate(self):
    g = self.geom

    # -- Geometry positivity --------------------------------------------------
    if (g.ROW_BYTES_P < 1 or g.ADDR_WIDTH_P < 1 or g.N_RANKS_P < 1 or
        g.N_BANK_GROUPS_P < 1 or g.BANKS_PER_BG_P < 1 or g.ROW_BITS_P < 1 or
        g.COL_BITS_P < 1 or g.DEVICE_WIDTH_P < 1 or g.N_DEVICES_PER_RANK_P < 1):
      raise RuntimeError(
        f"[{self.name}] Invalid geometry: every field must be >= 1 (got {g})")

    # -- Channel width is a power of two --------------------------------------
    channel_bits = g.N_DEVICES_PER_RANK_P * g.DEVICE_WIDTH_P
    if not self._is_pow2(channel_bits):
      raise RuntimeError(
        f"[{self.name}] Channel width {g.N_DEVICES_PER_RANK_P}*"
        f"{g.DEVICE_WIDTH_P} = {channel_bits} is not a power of two")

    # -- Count-valued geometry fields must be powers of two -------------------
    if not (self._is_pow2(g.ROW_BYTES_P) and self._is_pow2(g.N_RANKS_P) and
            self._is_pow2(g.N_BANK_GROUPS_P) and self._is_pow2(g.BANKS_PER_BG_P)):
      raise RuntimeError(
        f"[{self.name}] Geometry counts must be powers of two for the address "
        f"decode (got ROW_BYTES_P={g.ROW_BYTES_P} N_RANKS_P={g.N_RANKS_P} "
        f"N_BANK_GROUPS_P={g.N_BANK_GROUPS_P} BANKS_PER_BG_P={g.BANKS_PER_BG_P})")

    # -- Timing sanity --------------------------------------------------------
    if self.timing.t_ck <= 0.0:
      raise RuntimeError(
        f"[{self.name}] t_ck must be > 0 (got {self.timing.t_ck:.4f} ns)")

    if self.timing.tRC + TIMING_EPS < self.timing.tRAS + self.timing.tRP:
      raise RuntimeError(
        f"[{self.name}] tRC ({self.timing.tRC:.3f} ns) < tRAS + tRP "
        f"({self.timing.tRAS:.3f} + {self.timing.tRP:.3f})")

    # -- Geometry must exactly fill the declared address width ----------------
    byte_w = clog2(g.ROW_BYTES_P)
    col_w = g.COL_BITS_P
    bank_w = clog2(g.BANKS_PER_BG_P)
    bg_w = clog2(g.N_BANK_GROUPS_P)
    row_w = g.ROW_BITS_P
    rank_w = clog2(g.N_RANKS_P)
    addr_bits = byte_w + col_w + bank_w + bg_w + row_w + rank_w
    if addr_bits != g.ADDR_WIDTH_P:
      raise RuntimeError(
        f"[{self.name}] Geometry decodes to {addr_bits} address bits "
        f"(byte {byte_w} + col {col_w} + bank {bank_w} + bg {bg_w} + "
        f"row {row_w} + rank {rank_w}) but ADDR_WIDTH_P = {g.ADDR_WIDTH_P}")

    # -- tRFC density-table coverage (warning) --------------------------------
    gen = vip_dram_preset_gen(self.preset)
    max_gbit = vip_dram_trfc_max_gbit(gen)
    dens = self.density_gbit()
    if max_gbit > 0 and dens > max_gbit:
      _logger.warning(
        "[%s] Per-die density %d Gbit exceeds the %s tRFC table max (%d Gbit); "
        "tRFC clamped to %.1f ns (approximate)",
        self.name, dens, gen.name, max_gbit, self.timing.tRFC)

    # -- Page policy coverage (warning) ---------------------------------------
    if self.page_policy != VipDramPagePolicy.OPEN:
      _logger.warning(
        "[%s] page_policy = %s is not yet modelled; the scheduler behaves as "
        "OPEN page", self.name, self.page_policy.name)

  # ---------------------------------------------------------------------------
  #
  # ---------------------------------------------------------------------------
  @staticmethod
  def _is_pow2(n):
    return (n > 0) and ((n & (n - 1)) == 0)

  # ---------------------------------------------------------------------------
  # Readable single-line summary of the key timing + policy knobs.
  # ---------------------------------------------------------------------------
  def convert2string(self):
    t = self.timing
    return (f"preset={self.preset.name} density={self.density_gbit()}Gb "
            f"t_ck={t.t_ck:.3f} tRCD={t.tRCD:.2f} tRP={t.tRP:.2f} "
            f"tCL={t.tCL:.2f} tWL={t.tWL:.2f} tRC={t.tRC:.2f} "
            f"tRFC={t.tRFC:.1f} tREFI={t.tREFI:.1f} page={self.page_policy.name} "
            f"bus_contention={'TRUE' if self.enable_bus_contention else 'FALSE'}")
