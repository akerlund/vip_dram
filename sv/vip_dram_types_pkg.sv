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
// vip_dram_types_pkg
//
// Neutral, protocol-agnostic enums and the device CONFIG TYPE for the DRAM
// device model. The device geometry + channel widths are supplied as a
// compile-time parameter struct (vip_dram_cfg_t) used to parameterize the
// vip_dram component and the neutral vip_dram_req/rsp items — there are no
// fixed package width constants. No bus dependency; imports only
// vip_mem_types_pkg (for the vip_mem_cfg_t storage descriptor).
// See vip_dram/IMPLEMENTATION_PLAN.md "Neutral request/response API" and
// "Device geometry — defaults".
//
////////////////////////////////////////////////////////////////////////////////

`ifndef VIP_DRAM_TYPES_PKG
`define VIP_DRAM_TYPES_PKG

package vip_dram_types_pkg;

  // Storage descriptor type (vip_mem_cfg_t). vip_mem itself (the class) is
  // pulled in by the umbrella vip_dram_pkg; here we only need the cfg struct.
  import vip_mem_types_pkg::*;

  // ---------------------------------------------------------------------------
  // Operation carried by a neutral vip_dram_req. RD/WR carry a byte address that
  // the device decodes to {rank,bg,bank,row,col}. REF carries no address or data
  // and refreshes a whole rank: the scheduler takes the target rank straight
  // from vip_dram_req.rank (the address is never decoded for REF, and the
  // has_explicit_rank bit — a RD/WR-only knob — is not consulted).
  // ---------------------------------------------------------------------------
  typedef enum logic [1 : 0] {
    VIP_DRAM_OP_RD_E  = 2'd0,
    VIP_DRAM_OP_WR_E  = 2'd1,
    VIP_DRAM_OP_REF_E = 2'd2
  } vip_dram_op_t;

  // ---------------------------------------------------------------------------
  // Device read-fault severity (§11 item 5). A deterministic, addressable model
  // of a device/channel data fault — NOT probabilistic bus injection. Severity
  // maps to what a 64+8 SECDED controller layer would decide: NONE / CORRECTABLE
  // (single-bit, corrected -> OKAY) / UNCORRECTABLE (double-bit DUE -> SLVERR).
  // The value is carried behaviorally on the read response; no ECC bits stored.
  // ---------------------------------------------------------------------------
  typedef enum logic [1 : 0] {
    VIP_DRAM_FAULT_NONE_E          = 2'd0,
    VIP_DRAM_FAULT_CORRECTABLE_E   = 2'd1,
    VIP_DRAM_FAULT_UNCORRECTABLE_E = 2'd2
  } vip_dram_fault_e;

  // ---------------------------------------------------------------------------
  // Page policy. OPEN keeps the row open after access (page-hit friendly);
  // CLOSED auto-precharges; ADAPTIVE is a future row-hit-rate tuner.
  // ---------------------------------------------------------------------------
  typedef enum logic [1 : 0] {
    VIP_DRAM_PAGE_OPEN_E     = 2'd0,
    VIP_DRAM_PAGE_CLOSED_E   = 2'd1,
    VIP_DRAM_PAGE_ADAPTIVE_E = 2'd2
  } vip_dram_page_policy_t;

  // ---------------------------------------------------------------------------
  // Per-bank FSM state (used by vip_dram_bank_state / vip_dram_scheduler).
  // ---------------------------------------------------------------------------
  typedef enum logic [1 : 0] {
    VIP_DRAM_BANK_IDLE_E       = 2'd0,  // precharged / closed
    VIP_DRAM_BANK_ACTIVE_E     = 2'd1,  // a row is open
    VIP_DRAM_BANK_REFRESHING_E = 2'd2   // rank blocked by REF (tRFC)
  } vip_dram_bank_fsm_t;

  // ---------------------------------------------------------------------------
  // Device configuration — the CLASS PARAMETER type.
  //
  // Compile-time device geometry and channel widths. Supplied as the parameter
  // of the vip_dram component and the neutral vip_dram_req/rsp items, e.g.
  //   vip_dram     #(MY_DRAM_CFG_C)
  //   vip_dram_req #(MY_DRAM_CFG_C)
  // so a testbench can size the device (and the neutral-TLM data width) per
  // instance. This replaces the former fixed package localparams.
  //
  // `ROW_BYTES_P` is the bytes moved by one DRAM column access (BL8 payload) and
  // is therefore the width of one neutral-TLM beat; the vip_mem backing-store
  // row equals one column access (see vip_dram_types::MEM_CFG below).
  // ---------------------------------------------------------------------------
  typedef struct packed {
    int ROW_BYTES_P;          // bytes per DRAM column access (BL8 payload) = neutral-TLM beat
    int ADDR_WIDTH_P;         // device byte-address width
    int N_RANKS_P;
    int N_BANK_GROUPS_P;
    int BANKS_PER_BG_P;
    int ROW_BITS_P;
    int COL_BITS_P;
    int DEVICE_WIDTH_P;       // per-device DQ width (informational / geometry)
    int N_DEVICES_PER_RANK_P; // devices ganged to form the channel
  } vip_dram_cfg_t;

  // Default: DDR4-3200 x8, 8 Gb-density devices, 8 ganged to a 64-bit channel
  // (BL8 -> 64 B per column access). The channel is 8 GiB = 2^33 B, so the
  // byte-address decode must sum to ADDR_WIDTH_P = 33:
  //   byte 6 + col 10 + bank 2 + bg 2 + row 13 + rank 0 = 33.
  // ADDR_WIDTH_P is an explicit field (it mirrors the controller-side address
  // width) and vip_dram_config::validate() fatals if the geometry does not sum
  // to it. tRFC = 350 ns matches the 8 Gb per-device density (timing_pkg).
  localparam vip_dram_cfg_t VIP_DRAM_CFG_DEFAULT_C = '{
    ROW_BYTES_P          : 64,
    ADDR_WIDTH_P         : 33,
    N_RANKS_P            : 1,
    N_BANK_GROUPS_P      : 4,
    BANKS_PER_BG_P       : 4,
    ROW_BITS_P           : 13,
    COL_BITS_P           : 10,
    DEVICE_WIDTH_P       : 8,
    N_DEVICES_PER_RANK_P : 8
  };

  // ---------------------------------------------------------------------------
  // Address-map slice descriptor.
  //
  // The runtime-overridable bit slicing of the request byte-address. Only the
  // LSB (bit offset) of each field is carried — the field WIDTHS are fixed by
  // the geometry (CFG_P) and recomputed by the decode (vip_dram_decode_addr in
  // vip_dram_addr_pkg, §7.2), so a controller can REORDER fields but never resize
  // them out of step with the device. vip_dram_config defaults this from CFG_P
  // (LSB-first) and the MC may override it. See IMPLEMENTATION_PLAN.md §7.2
  // "vip_dram_addr_pkg" and the
  // worked decode example under "Beat granularity & transaction semantics".
  // ---------------------------------------------------------------------------
  typedef struct packed {
    int byte_lsb;   // offset of the byte-in-column field (normally 0)
    int col_lsb;    // offset of the column-index field
    int bank_lsb;   // offset of the bank field
    int bg_lsb;     // offset of the bank-group field
    int row_lsb;    // offset of the row field
    int rank_lsb;   // offset of the rank field
  } vip_dram_addr_map_t;

  // Default LSB-first slicing [byte][col][bank][bg][row][rank] derived from the
  // geometry. A constant function so it can seed a localparam (the field widths
  // are clog2 of the geometry counts; rank/bank/bg widths are 0 when the count
  // is 1). Matches the worked decode example in the plan exactly.
  function automatic vip_dram_addr_map_t vip_dram_default_addr_map(vip_dram_cfg_t cfg);
    vip_dram_addr_map_t m;
    int byte_w = $clog2(cfg.ROW_BYTES_P);
    int col_w  = cfg.COL_BITS_P;
    int bank_w = $clog2(cfg.BANKS_PER_BG_P);
    int bg_w   = $clog2(cfg.N_BANK_GROUPS_P);
    int row_w  = cfg.ROW_BITS_P;
    m.byte_lsb = 0;
    m.col_lsb  = m.byte_lsb + byte_w;
    m.bank_lsb = m.col_lsb  + col_w;
    m.bg_lsb   = m.bank_lsb + bank_w;
    m.row_lsb  = m.bg_lsb   + bg_w;
    m.rank_lsb = m.row_lsb  + row_w;
    return m;
  endfunction

  // ---------------------------------------------------------------------------
  // Decoded byte-address — the result of vip_dram_decode_addr (vip_dram_addr_pkg,
  // §7.2). All fields
  // are zero-based indices into the geometry; `byte_in_col` is the offset within
  // the ROW_BYTES_P-wide column access. rank/bg/bank fields collapse to a
  // constant 0 when the corresponding geometry count is 1 (their slice width is
  // $clog2(1) = 0). Packed struct of int, matching vip_dram_addr_map_t.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    int rank;
    int bg;
    int bank;
    int row;
    int col;
    int byte_in_col;
  } vip_dram_dec_t;

  // ---------------------------------------------------------------------------
  // CFG_P-derived widths and storage descriptor. Consumers alias what they
  // need, e.g.  typedef vip_dram_types #(CFG_P)::data_t data_t;  so the widths
  // are computed once and stay consistent across the items, scheduler, and
  // vip_mem. (The vip_mem class typedef itself lives in the umbrella
  // vip_dram_pkg, which imports vip_memory_pkg and uses MEM_CFG below.)
  // ---------------------------------------------------------------------------
  class vip_dram_types #(
    vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
  );

    localparam int DATA_BITS = 8 * CFG_P.ROW_BYTES_P;  // one column-access word
    localparam int STRB_BITS = CFG_P.ROW_BYTES_P;       // one strobe bit per byte
    localparam int ADDR_BITS = CFG_P.ADDR_WIDTH_P;      // device byte-address width

    typedef logic [DATA_BITS-1 : 0] data_t;
    typedef logic [STRB_BITS-1 : 0] strb_t;
    typedef logic [ADDR_BITS-1 : 0] addr_t;  // narrowed device byte address (vip_mem facing)

    // vip_mem storage descriptor derived from CFG_P. All four vip_mem_cfg_t
    // fields are set (never leaving WDATA_BYTES_P / RDATA_BYTES_P at 0); the
    // backing row equals one column access.
    localparam vip_mem_cfg_t MEM_CFG = '{
      ADDR_WIDTH_P  : CFG_P.ADDR_WIDTH_P,
      WDATA_BYTES_P : CFG_P.ROW_BYTES_P,
      RDATA_BYTES_P : CFG_P.ROW_BYTES_P,
      ROW_BYTES_P   : CFG_P.ROW_BYTES_P
    };
  endclass

endpackage

`endif
