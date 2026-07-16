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
## vip_dram_types_pkg
##
## pyUVM port of vip_dram/sv/vip_dram_types_pkg.sv.
##
## Neutral, protocol-agnostic enums and the device CONFIG TYPE for the DRAM
## device model. The SV device geometry + channel widths are a compile-time
## parameter struct (vip_dram_cfg_t); the Python port carries the same struct as a
## runtime `VipDramCfgT` dataclass (widths become plain ints), so there are no
## parameterized classes. `vip_dram_types #(CFG_P)` (the width/typedef helper
## class) folds into the free width helpers (data_bits/strb_bits/addr_bits,
## mem_cfg_of) plus mask()/trunc()/clog2().
##
################################################################################

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum


# -----------------------------------------------------------------------------
# Bit helpers. Python ints are unbounded, so width truncation (implicit on SV
# packed vectors) is explicit here.
# -----------------------------------------------------------------------------
def mask(width: int) -> int:
  """All-ones mask for `width` bits ((1<<width)-1); 0 for width<=0."""
  return (1 << width) - 1 if width > 0 else 0


def trunc(value: int, width: int) -> int:
  """Truncate `value` to `width` bits."""
  return int(value) & mask(width)


def clog2(n: int) -> int:
  """$clog2(n): smallest k with 2**k >= n. clog2(1)=0, clog2(64)=6."""
  if n <= 1:
    return 0
  return (n - 1).bit_length()


# -----------------------------------------------------------------------------
# Simulation-time helpers. All device timing is absolute NANOSECONDS (SV
# realtime); the sim base unit is ps (1 ns / 1 ps top), so every preset value is
# an exact integer ps. sim_time_ns() returns 0.0 when called outside a running
# simulator (pure-Python unit checks of the scheduler at t=0).
# -----------------------------------------------------------------------------
def sim_time_ns() -> float:
  """Current $realtime in ns as a float (0.0 when no simulator is running)."""
  try:
    from pyuvm import get_sim_time
    return get_sim_time("ps") / 1000.0
  except Exception:
    return 0.0


async def delay_ns(dt_ns: float) -> None:
  """Advance sim time by `dt_ns` nanoseconds (no-op for dt<=0). Converts to
  integer ps at the Timer boundary (1 ps precision, exact for the presets)."""
  if dt_ns <= 0.0:
    return
  from cocotb.triggers import Timer
  await Timer(round(dt_ns * 1000.0), unit="ps")


# -----------------------------------------------------------------------------
# Operation carried by a neutral vip_dram_req. RD/WR carry a byte address the
# device decodes; REF carries no address/data and refreshes a whole rank.
# IntEnum so REF/RD/WR compare by value like the SV `enum logic [1:0]`.
# -----------------------------------------------------------------------------
class VipDramOp(IntEnum):
  RD  = 0
  WR  = 1
  REF = 2


# -----------------------------------------------------------------------------
# Device read-fault severity (SV §11 item 5). Ordered NONE < CORRECTABLE <
# UNCORRECTABLE so `row_fault > rsp.injected_fault` (worst-severity fold) works.
# -----------------------------------------------------------------------------
class VipDramFault(IntEnum):
  NONE          = 0
  CORRECTABLE   = 1
  UNCORRECTABLE = 2


# -----------------------------------------------------------------------------
# Page policy. OPEN keeps the row open after access; CLOSED/ADAPTIVE are accepted
# but behave as OPEN (only OPEN page is modelled by the scheduler today).
# -----------------------------------------------------------------------------
class VipDramPagePolicy(IntEnum):
  OPEN     = 0
  CLOSED   = 1
  ADAPTIVE = 2


# -----------------------------------------------------------------------------
# Per-bank FSM state (used by VipDramBankState / VipDramScheduler).
# -----------------------------------------------------------------------------
class VipDramBankFsm(IntEnum):
  IDLE       = 0 # precharged / closed
  ACTIVE     = 1 # a row is open
  REFRESHING = 2 # rank blocked by REF (tRFC)


# -----------------------------------------------------------------------------
# Device configuration — the SV CLASS PARAMETER type, here a runtime dataclass.
#
# The defaults ARE the SV VIP_DRAM_CFG_DEFAULT_C: DDR4-3200 x8, 8 Gb-density
# devices, 8 ganged to a 64-bit channel (BL8 -> 64 B per column access), 8 GiB
# channel (byte 6 + col 10 + bank 2 + bg 2 + row 13 + rank 0 = 33 addr bits).
# -----------------------------------------------------------------------------
@dataclass
class VipDramCfgT:
  ROW_BYTES_P:          int = 64 # bytes per DRAM column access (BL8) = neutral-TLM beat
  ADDR_WIDTH_P:         int = 33 # device byte-address width
  N_RANKS_P:            int = 1
  N_BANK_GROUPS_P:      int = 4
  BANKS_PER_BG_P:       int = 4
  ROW_BITS_P:           int = 13
  COL_BITS_P:           int = 10
  DEVICE_WIDTH_P:       int = 8  # per-device DQ width (geometry / informational)
  N_DEVICES_PER_RANK_P: int = 8  # devices ganged to form the channel


# The default preset device geometry (SV localparam VIP_DRAM_CFG_DEFAULT_C).
VIP_DRAM_CFG_DEFAULT = VipDramCfgT()


# -----------------------------------------------------------------------------
# Address-map slice descriptor. Only the LSB (bit offset) of each field is
# carried; the field WIDTHS are fixed by the geometry (recomputed by the decode),
# so a controller can REORDER fields but never resize them out of step.
# -----------------------------------------------------------------------------
@dataclass
class VipDramAddrMapT:
  byte_lsb: int = 0 # offset of the byte-in-column field (normally 0)
  col_lsb:  int = 0 # offset of the column-index field
  bank_lsb: int = 0 # offset of the bank field
  bg_lsb:   int = 0 # offset of the bank-group field
  row_lsb:  int = 0 # offset of the row field
  rank_lsb: int = 0 # offset of the rank field


# -----------------------------------------------------------------------------
# Default LSB-first slicing [byte][col][bank][bg][row][rank] from the geometry.
# rank/bank/bg widths are 0 when the count is 1.
# -----------------------------------------------------------------------------
def vip_dram_default_addr_map(cfg: VipDramCfgT) -> VipDramAddrMapT:
  byte_w = clog2(cfg.ROW_BYTES_P)
  col_w  = cfg.COL_BITS_P
  bank_w = clog2(cfg.BANKS_PER_BG_P)
  bg_w   = clog2(cfg.N_BANK_GROUPS_P)
  row_w  = cfg.ROW_BITS_P

  m          = VipDramAddrMapT()
  m.byte_lsb = 0
  m.col_lsb  = m.byte_lsb + byte_w
  m.bank_lsb = m.col_lsb + col_w
  m.bg_lsb   = m.bank_lsb + bank_w
  m.row_lsb  = m.bg_lsb + bg_w
  m.rank_lsb = m.row_lsb + row_w
  return m


# -----------------------------------------------------------------------------
# Decoded byte-address (result of vip_dram_decode_addr). All fields are
# zero-based indices; rank/bg/bank collapse to 0 when the geometry count is 1.
# -----------------------------------------------------------------------------
@dataclass
class VipDramDecT:
  rank:        int = 0
  bg:          int = 0
  bank:        int = 0
  row:         int = 0
  col:         int = 0
  byte_in_col: int = 0


# -----------------------------------------------------------------------------
# CFG-derived widths and storage descriptor — the SV `vip_dram_types #(CFG_P)`
# typedefs, as free helpers.
# -----------------------------------------------------------------------------
def data_bits(cfg: VipDramCfgT) -> int:
  """One column-access word width (bits)."""
  return 8 * cfg.ROW_BYTES_P


def strb_bits(cfg: VipDramCfgT) -> int:
  """One strobe bit per byte."""
  return cfg.ROW_BYTES_P


def addr_bits(cfg: VipDramCfgT) -> int:
  """Device byte-address width."""
  return cfg.ADDR_WIDTH_P


def mem_cfg_of(cfg: VipDramCfgT):
  """vip_mem storage descriptor derived from the geometry (backing row == one
  column access). Returns a vip_mem_cfg_t (from the vip_memory port)."""
  from vip_mem_types_pkg import vip_mem_cfg_t
  return vip_mem_cfg_t(
    addr_width  = cfg.ADDR_WIDTH_P,
    wdata_bytes = cfg.ROW_BYTES_P,
    rdata_bytes = cfg.ROW_BYTES_P,
    row_bytes   = cfg.ROW_BYTES_P,
  )
