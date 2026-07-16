////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Åkerlund
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Description:
// vip_dram_addr_pkg
//
// Address-mapping algorithms for the DRAM device model (§7.2): pure functions
// over the geometry/map types defined in vip_dram_types_pkg. A package of free
// functions, exactly mirroring vip_dram_timing_pkg (functions over the timing
// types) — NOT an `include fragment, because these are plain functions, not the
// parameterized UVM class items that the umbrella vip_dram_pkg `include`s.
//
//   - vip_dram_decode_addr() : byte addr -> {rank,bg,bank,row,col,byte_in_col},
//     LSBs from cfg.addr_map (overridable), widths from the geometry (cfg, fixed)
//   - vip_dram_encode_addr()  : the inverse, used by the scheduler/TB to build an
//     address targeting a chosen {rank,bg,bank,row,col}
//   - vip_dram_bank_index()   : flatten {bg,bank} to the linear per-rank bank id
//     the vip_dram_bank_state array is indexed by (§7.3)
//
// The map TYPES and the default-map builder (vip_dram_default_addr_map) live in
// vip_dram_types_pkg with the rest of the type registry; this package imports
// them. No bus / UVM / vip_mem dependency.
//
////////////////////////////////////////////////////////////////////////////////

`ifndef VIP_DRAM_ADDR_PKG
`define VIP_DRAM_ADDR_PKG

package vip_dram_addr_pkg;

  import vip_dram_types_pkg::*;

  // ---------------------------------------------------------------------------
  // Slice `width` bits out of `addr` at `lsb`. Width 0 (e.g. single-rank) -> 0.
  // ---------------------------------------------------------------------------
  function automatic int vip_dram_addr_extract(
    input longint unsigned addr,
    input int              lsb,
    input int              width
  );
    if (width <= 0) return 0;
    return int'((addr >> lsb) & ((longint'(1) << width) - 1));
  endfunction

  // ---------------------------------------------------------------------------
  // Place `value` (masked to `width` bits) at `lsb`. Width 0 contributes nothing.
  // ---------------------------------------------------------------------------
  function automatic longint unsigned vip_dram_addr_place(
    input int value,
    input int lsb,
    input int width
  );
    longint unsigned mask;
    if (width <= 0) return '0;
    mask = (longint'(1) << width) - 1;
    return (longint'(value) & mask) << lsb;
  endfunction

  // ---------------------------------------------------------------------------
  // Decode a byte address into geometry indices. Field LSBs come from `map`
  // (overridable); field widths come from `cfg` (the geometry, fixed).
  // ---------------------------------------------------------------------------
  function automatic vip_dram_dec_t vip_dram_decode_addr(
    input longint unsigned    addr,
    input vip_dram_cfg_t      cfg,
    input vip_dram_addr_map_t map
  );
    vip_dram_dec_t d;
    d.byte_in_col = vip_dram_addr_extract(addr, map.byte_lsb, $clog2(cfg.ROW_BYTES_P));
    d.col         = vip_dram_addr_extract(addr, map.col_lsb,  cfg.COL_BITS_P);
    d.bank        = vip_dram_addr_extract(addr, map.bank_lsb, $clog2(cfg.BANKS_PER_BG_P));
    d.bg          = vip_dram_addr_extract(addr, map.bg_lsb,   $clog2(cfg.N_BANK_GROUPS_P));
    d.row         = vip_dram_addr_extract(addr, map.row_lsb,  cfg.ROW_BITS_P);
    d.rank        = vip_dram_addr_extract(addr, map.rank_lsb, $clog2(cfg.N_RANKS_P));
    return d;
  endfunction

  // ---------------------------------------------------------------------------
  // Inverse of vip_dram_decode_addr: rebuild the byte address from a decode.
  // Each field is masked to its geometry width, so an out-of-range index cannot
  // bleed into a neighbouring field. Round-trips with vip_dram_decode_addr for
  // any in-range decode under the same (cfg, map).
  // ---------------------------------------------------------------------------
  function automatic longint unsigned vip_dram_encode_addr(
    input vip_dram_dec_t      d,
    input vip_dram_cfg_t      cfg,
    input vip_dram_addr_map_t map
  );
    longint unsigned a;
    a  = vip_dram_addr_place(d.byte_in_col, map.byte_lsb, $clog2(cfg.ROW_BYTES_P));
    a |= vip_dram_addr_place(d.col,         map.col_lsb,  cfg.COL_BITS_P);
    a |= vip_dram_addr_place(d.bank,        map.bank_lsb, $clog2(cfg.BANKS_PER_BG_P));
    a |= vip_dram_addr_place(d.bg,          map.bg_lsb,   $clog2(cfg.N_BANK_GROUPS_P));
    a |= vip_dram_addr_place(d.row,         map.row_lsb,  cfg.ROW_BITS_P);
    a |= vip_dram_addr_place(d.rank,        map.rank_lsb, $clog2(cfg.N_RANKS_P));
    return a;
  endfunction

  // ---------------------------------------------------------------------------
  // Linear per-rank bank id (bg-major, bank-minor), in
  // [0, N_BANK_GROUPS_P*BANKS_PER_BG_P). The vip_dram_bank_state array indexes
  // by this; rank is tracked separately.
  // ---------------------------------------------------------------------------
  function automatic int vip_dram_bank_index(
    input vip_dram_cfg_t cfg,
    input vip_dram_dec_t d
  );
    return (d.bg * cfg.BANKS_PER_BG_P) + d.bank;
  endfunction

  // ---------------------------------------------------------------------------
  // Total banks per rank (= N_BANK_GROUPS_P * BANKS_PER_BG_P), the size of the
  // per-rank bank-state array vip_dram_bank_index() addresses.
  // ---------------------------------------------------------------------------
  function automatic int vip_dram_banks_per_rank(
    input vip_dram_cfg_t cfg
  );
    return cfg.N_BANK_GROUPS_P * cfg.BANKS_PER_BG_P;
  endfunction
endpackage

`endif
