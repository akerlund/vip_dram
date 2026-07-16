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
## vip_dram_addr_pkg
##
## pyUVM port of vip_dram/sv/vip_dram_addr_pkg.sv.
##
## Address-mapping algorithms for the DRAM device model (SV §7.2): pure functions
## over the geometry/map types in vip_dram_types_pkg. Field LSBs come from the
## (overridable) address map; field widths come from the geometry (fixed).
##
##   - vip_dram_decode_addr() : byte addr -> {rank,bg,bank,row,col,byte_in_col}
##   - vip_dram_encode_addr() : the inverse
##   - vip_dram_bank_index() : flatten {bg,bank} to the linear per-rank bank id
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import (
  VipDramAddrMapT, VipDramCfgT, VipDramDecT, clog2,
)


# -----------------------------------------------------------------------------
# Slice `width` bits out of `addr` at `lsb`. Width 0 (e.g. single-rank) -> 0.
# -----------------------------------------------------------------------------
def vip_dram_addr_extract(addr: int, lsb: int, width: int) -> int:
  if width <= 0:
    return 0
  return int((int(addr) >> lsb) & ((1 << width) - 1))


# -----------------------------------------------------------------------------
# Place `value` (masked to `width` bits) at `lsb`. Width 0 contributes nothing.
# -----------------------------------------------------------------------------
def vip_dram_addr_place(value: int, lsb: int, width: int) -> int:
  if width <= 0:
    return 0
  m = (1 << width) - 1
  return (int(value) & m) << lsb


# -----------------------------------------------------------------------------
# Decode a byte address into geometry indices. LSBs from `map`, widths from `cfg`.
# -----------------------------------------------------------------------------
def vip_dram_decode_addr(addr: int, cfg: VipDramCfgT,
                         map_: VipDramAddrMapT) -> VipDramDecT:
  d             = VipDramDecT()
  d.byte_in_col = vip_dram_addr_extract(addr, map_.byte_lsb, clog2(cfg.ROW_BYTES_P))
  d.col         = vip_dram_addr_extract(addr, map_.col_lsb, cfg.COL_BITS_P)
  d.bank        = vip_dram_addr_extract(addr, map_.bank_lsb, clog2(cfg.BANKS_PER_BG_P))
  d.bg          = vip_dram_addr_extract(addr, map_.bg_lsb, clog2(cfg.N_BANK_GROUPS_P))
  d.row         = vip_dram_addr_extract(addr, map_.row_lsb, cfg.ROW_BITS_P)
  d.rank        = vip_dram_addr_extract(addr, map_.rank_lsb, clog2(cfg.N_RANKS_P))
  return d


# -----------------------------------------------------------------------------
# Inverse of vip_dram_decode_addr: rebuild the byte address from a decode. Each
# field is masked to its geometry width. Round-trips with decode for any
# in-range decode under the same (cfg, map).
# -----------------------------------------------------------------------------
def vip_dram_encode_addr(d: VipDramDecT, cfg: VipDramCfgT,
                         map_: VipDramAddrMapT) -> int:
  a  = vip_dram_addr_place(d.byte_in_col, map_.byte_lsb, clog2(cfg.ROW_BYTES_P))
  a |= vip_dram_addr_place(d.col, map_.col_lsb, cfg.COL_BITS_P)
  a |= vip_dram_addr_place(d.bank, map_.bank_lsb, clog2(cfg.BANKS_PER_BG_P))
  a |= vip_dram_addr_place(d.bg, map_.bg_lsb, clog2(cfg.N_BANK_GROUPS_P))
  a |= vip_dram_addr_place(d.row, map_.row_lsb, cfg.ROW_BITS_P)
  a |= vip_dram_addr_place(d.rank, map_.rank_lsb, clog2(cfg.N_RANKS_P))
  return a


# -----------------------------------------------------------------------------
# Linear per-rank bank id (bg-major, bank-minor), in
# [0, N_BANK_GROUPS_P*BANKS_PER_BG_P).
# -----------------------------------------------------------------------------
def vip_dram_bank_index(cfg: VipDramCfgT, d: VipDramDecT) -> int:
  return (d.bg * cfg.BANKS_PER_BG_P) + d.bank


# -----------------------------------------------------------------------------
# Total banks per rank (= N_BANK_GROUPS_P * BANKS_PER_BG_P).
# -----------------------------------------------------------------------------
def vip_dram_banks_per_rank(cfg: VipDramCfgT) -> int:
  return cfg.N_BANK_GROUPS_P * cfg.BANKS_PER_BG_P
