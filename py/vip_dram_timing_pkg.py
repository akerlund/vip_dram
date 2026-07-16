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
## vip_dram_timing_pkg
##
## pyUVM port of vip_dram/sv/vip_dram_timing_pkg.sv.
##
## DRAM timing parameters (nanoseconds), timing presets, and the ns->cycles
## helper. Values are stored in ns; VipDramConfig converts to cycles via t_ck.
## Only the DDR4-3200 preset is authoritative (matches the plan table); the other
## presets are reasonable first-pass values flagged TODO in the SV.
##
################################################################################

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import IntEnum


# -----------------------------------------------------------------------------
# Timing presets. IDEAL collapses every delay to zero (sanity regression).
# -----------------------------------------------------------------------------
class VipDramPreset(IntEnum):
  DDR4_3200_CL22 = 0
  DDR4_2400_CL17 = 1
  DDR3_1600_CL11 = 2
  LPDDR4_3200    = 3
  DDR5_4800      = 4
  IDEAL          = 5


# -----------------------------------------------------------------------------
# DRAM generation. A preset selects the speed bin; the generation plus per-die
# density (from geometry) pick tRFC via vip_dram_trfc_ns().
# -----------------------------------------------------------------------------
class VipDramGen(IntEnum):
  DDR3   = 0
  DDR4   = 1
  LPDDR4 = 2
  DDR5   = 3
  IDEAL  = 4


# -----------------------------------------------------------------------------
# Timing record (nanoseconds). tRC, tBL, tRTW are DERIVED (see get_preset).
# -----------------------------------------------------------------------------
@dataclass
class VipDramTimingT:
  t_ck:   float = 0.0 # DRAM clock period
  tRCD:   float = 0.0 # ACT -> RD/WR
  tRP:    float = 0.0 # row precharge
  tRAS:   float = 0.0 # row active min
  tRC:    float = 0.0 # = tRAS + tRP (derived)
  tCL:    float = 0.0 # CAS read latency
  tWL:    float = 0.0 # write latency (CWL)
  tWR:    float = 0.0 # write recovery
  tRTP:   float = 0.0 # RD -> PRE
  tCCD_S: float = 0.0 # col-col, diff bankgrp
  tCCD_L: float = 0.0 # col-col, same bankgrp
  tRRD_S: float = 0.0 # ACT-ACT, diff bankgrp
  tRRD_L: float = 0.0 # ACT-ACT, same bankgrp
  tFAW:   float = 0.0 # four-activate window (rank)
  tWTR_S: float = 0.0 # WR -> RD, diff bankgrp
  tWTR_L: float = 0.0 # WR -> RD, same bankgrp
  tRTW:   float = 0.0 # RD -> WR turnaround (derived)
  tRFC:   float = 0.0 # refresh cycle (blocks rank)
  tBL:    float = 0.0 # burst length on bus (derived)
  tREFI:  float = 0.0 # average refresh interval (read-only for vip_mc)


# -----------------------------------------------------------------------------
# Round a nanosecond value up to whole DRAM clock cycles. Guards t_ck<=0 (0).
# -----------------------------------------------------------------------------
def vip_dram_ns_to_cycles(ns: float, t_ck: float) -> int:
  if t_ck <= 0.0:
    return 0
  return int(math.ceil(ns / t_ck))


# -----------------------------------------------------------------------------
# Controller-derived read-to-write bus turnaround.
#   tRTW = tCL + tBL + 2*t_ck - tWL
# -----------------------------------------------------------------------------
def vip_dram_derive_trtw(tCL: float, tBL: float, t_ck: float, tWL: float) -> float:
  return tCL + tBL + 2.0 * t_ck - tWL


# -----------------------------------------------------------------------------
# Populate a full timing record for a preset. DDR4-3200 CL22 is authoritative;
# the others are first-pass approximations (TODO in the SV).
# -----------------------------------------------------------------------------
def vip_dram_get_preset(preset: VipDramPreset) -> VipDramTimingT:
  t = VipDramTimingT()

  # IDEAL: all-zero delays (t_ck kept non-zero so ns->cycles stays defined).
  if preset == VipDramPreset.IDEAL:
    t.t_ck  = 0.625
    t.tREFI = 7800.0
    return t

  bl_clocks = 4  # burst length in DRAM clocks (BL8 -> 4, BL16 -> 8)

  if preset == VipDramPreset.DDR4_3200_CL22:
    t.t_ck    = 0.625
    t.tRCD    = 13.75; t.tRP = 13.75; t.tRAS = 32.0
    t.tCL     = 13.75; t.tWL = 10.0; t.tWR = 15.0; t.tRTP = 7.5
    t.tCCD_S  = 2.5; t.tCCD_L = 5.0
    t.tRRD_S  = 3.0; t.tRRD_L = 4.9; t.tFAW = 21.0
    t.tWTR_S  = 2.5; t.tWTR_L = 7.5
    t.tRFC    = 350.0; t.tREFI = 7800.0   # 8 Gb device
    bl_clocks = 4                       # BL8

  elif preset == VipDramPreset.DDR4_2400_CL17:
    t.t_ck    = 0.8333
    t.tRCD    = 14.16; t.tRP = 14.16; t.tRAS = 32.0
    t.tCL     = 14.16; t.tWL = 10.0; t.tWR = 15.0; t.tRTP = 7.5
    t.tCCD_S  = 3.33; t.tCCD_L = 5.0
    t.tRRD_S  = 3.3; t.tRRD_L = 4.9; t.tFAW = 21.0
    t.tWTR_S  = 2.5; t.tWTR_L = 7.5
    t.tRFC    = 350.0; t.tREFI = 7800.0
    bl_clocks = 4

  elif preset == VipDramPreset.DDR3_1600_CL11:
    # DDR3 has NO bank groups -> the _S and _L variants are equal.
    t.t_ck    = 1.25
    t.tRCD    = 13.75; t.tRP = 13.75; t.tRAS = 35.0
    t.tCL     = 13.75; t.tWL = 8.75; t.tWR = 15.0; t.tRTP = 7.5
    t.tCCD_S  = 5.0; t.tCCD_L = 5.0
    t.tRRD_S  = 6.0; t.tRRD_L = 6.0; t.tFAW = 30.0
    t.tWTR_S  = 7.5; t.tWTR_L = 7.5
    t.tRFC    = 260.0; t.tREFI = 7800.0
    bl_clocks = 4

  elif preset == VipDramPreset.LPDDR4_3200:
    t.t_ck    = 0.625
    t.tRCD    = 18.0; t.tRP = 18.0; t.tRAS = 42.0
    t.tCL     = 18.0; t.tWL = 10.0; t.tWR = 18.0; t.tRTP = 7.5
    t.tCCD_S  = 5.0; t.tCCD_L = 5.0
    t.tRRD_S  = 10.0; t.tRRD_L = 10.0; t.tFAW = 40.0
    t.tWTR_S  = 10.0; t.tWTR_L = 10.0
    t.tRFC    = 180.0; t.tREFI = 3904.0
    bl_clocks = 4

  elif preset == VipDramPreset.DDR5_4800:
    # NOTE: DDR5 is BL16; the neutral "one column access = BL8" mapping must be
    # revisited before this preset is used for real timing checks.
    t.t_ck    = 0.4167
    t.tRCD    = 16.0; t.tRP = 16.0; t.tRAS = 32.0
    t.tCL     = 16.67; t.tWL = 13.33; t.tWR = 30.0; t.tRTP = 7.5
    t.tCCD_S  = 2.0; t.tCCD_L = 3.33
    t.tRRD_S  = 2.0; t.tRRD_L = 4.0; t.tFAW = 13.33
    t.tWTR_S  = 2.5; t.tWTR_L = 10.0
    t.tRFC    = 295.0; t.tREFI = 3900.0
    bl_clocks = 8

  else:
    t.t_ck    = 0.625
    bl_clocks = 4

  # Derived fields, common to all non-IDEAL presets.
  t.tBL  = bl_clocks * t.t_ck
  t.tRC  = t.tRAS + t.tRP
  t.tRTW = vip_dram_derive_trtw(t.tCL, t.tBL, t.t_ck, t.tWL)

  # The t.tRFC above is only the preset's REFERENCE-density value;
  # VipDramConfig.apply_preset() re-derives it from the actual per-die density.
  return t


# -----------------------------------------------------------------------------
# Map a speed-bin preset to its DRAM generation (used to index the tRFC table).
# -----------------------------------------------------------------------------
def vip_dram_preset_gen(preset: VipDramPreset) -> VipDramGen:
  if preset in (VipDramPreset.DDR4_3200_CL22, VipDramPreset.DDR4_2400_CL17):
    return VipDramGen.DDR4
  if preset == VipDramPreset.DDR3_1600_CL11:
    return VipDramGen.DDR3
  if preset == VipDramPreset.LPDDR4_3200:
    return VipDramGen.LPDDR4
  if preset == VipDramPreset.DDR5_4800:
    return VipDramGen.DDR5
  return VipDramGen.IDEAL


# -----------------------------------------------------------------------------
# Density-driven refresh cycle time (tRFC1, ns). tRFC scales with the per-die
# DENSITY, not the speed bin. Off-table densities clamp to the nearest-larger
# entry (conservative = longer refresh). DDR4 is authoritative.
# -----------------------------------------------------------------------------
def vip_dram_trfc_ns(gen: VipDramGen, density_gbit: int) -> float:
  if gen == VipDramGen.DDR4:              # authoritative
    if density_gbit <= 2:
      return 160.0
    if density_gbit <= 4:
      return 260.0
    if density_gbit <= 8:
      return 350.0
    return 550.0                          # 16 Gb+
  if gen == VipDramGen.DDR3:              # JESD79-3 tRFC
    if density_gbit <= 1:
      return 110.0
    if density_gbit <= 2:
      return 160.0
    if density_gbit <= 4:
      return 260.0
    return 350.0                          # 8 Gb
  if gen == VipDramGen.DDR5:              # TODO: refine (tRFC1)
    if density_gbit <= 8:
      return 195.0
    if density_gbit <= 16:
      return 295.0
    return 410.0                          # 24/32 Gb
  if gen == VipDramGen.LPDDR4:            # TODO: refine (tRFCab)
    if density_gbit <= 4:
      return 130.0
    if density_gbit <= 8:
      return 180.0
    return 280.0                          # 12/16 Gb
  return 0.0                              # IDEAL


# -----------------------------------------------------------------------------
# Largest density (Gbit) the tRFC table tabulates for a generation. 0 for IDEAL.
# -----------------------------------------------------------------------------
def vip_dram_trfc_max_gbit(gen: VipDramGen) -> int:
  if gen == VipDramGen.DDR4:
    return 16
  if gen == VipDramGen.DDR3:
    return 8
  if gen == VipDramGen.DDR5:
    return 16
  if gen == VipDramGen.LPDDR4:
    return 16
  return 0
