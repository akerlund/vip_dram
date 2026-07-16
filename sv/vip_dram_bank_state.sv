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
// vip_dram_bank_state
//
// Per-bank FSM record (§7.3): the open row plus the command/data timestamps the
// scheduler's latency formulas (§7.4) reference. A plain (non-parameterized)
// class — it holds only state, no geometry; the scheduler owns an array of them
// sized from CFG_P. `include`d into the umbrella vip_dram_pkg.
//
// All timestamps are absolute times in NANOSECONDS (realtime), matching the
// clockless ns model (the device computes against $realtime, not a clock). On
// construction and reset() every timestamp is NEG_LARGE_C (<= -tRC, effectively
// -inf) — NOT 0 — so every "max(now, t_last_* + tXX)" floor in §7.4 collapses to
// `now` for the first access to a freshly-reset bank (Q1): the smoke test sees
// exactly now + tRCD + tCL with no spurious tRP/tCCD term.
//
////////////////////////////////////////////////////////////////////////////////

class vip_dram_bank_state;

  // -inf sentinel for timestamps. -1e9 ns = -1 s, far below any real -tRC, so
  // adding any tXX (tens/hundreds of ns) still lands well below $realtime.
  localparam realtime NEG_LARGE_C = -1.0e9;

  // FSM state (IDLE = precharged/closed, ACTIVE = a row is open,
  // REFRESHING = rank blocked by REF; the scheduler models REF at rank level,
  // so REFRESHING is reserved for future per-bank refresh).
  vip_dram_bank_fsm_t state = VIP_DRAM_BANK_IDLE_E;

  // Row currently open when state == ACTIVE (meaningless when IDLE).
  int open_row = 0;

  // Command/data reference timestamps (ns). See the §6 reference-edge table:
  //   t_last_act    : last ACT command         (tRAS/tRC/tRRD reference)
  //   t_last_rd     : last RD  command         (tCCD/tRTP/tRTW reference)
  //   t_last_rd_end : last RD  data-burst end  (read burst completion, incl tBL)
  //   t_last_wr     : last WR  command         (tCCD reference)
  //   t_last_wr_end : last WR  data-burst end  (tWTR/tWR reference, incl tBL)
  //   t_last_pre    : last PRE command         (tRP reference, empty-bank ACT)
  realtime t_last_act;
  realtime t_last_rd;
  realtime t_last_rd_end;
  realtime t_last_wr;
  realtime t_last_wr_end;
  realtime t_last_pre;

  // Reserved for the (future) closed-page / explicit-precharge paths; unused by
  // the open-page scheduler but part of the §7.3 state.
  bit pending_pre = 1'b0;
  bit pending_ref = 1'b0;

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new();
    this.reset();
  endfunction

  // ---------------------------------------------------------------------------
  // Deterministic, seed-independent initial/post-reset state (§"Determinism"):
  // IDLE, no open row, every timestamp at -inf.
  // ---------------------------------------------------------------------------
  function void reset();
    this.state         = VIP_DRAM_BANK_IDLE_E;
    this.open_row      = 0;
    this.t_last_act    = NEG_LARGE_C;
    this.t_last_rd     = NEG_LARGE_C;
    this.t_last_rd_end = NEG_LARGE_C;
    this.t_last_wr     = NEG_LARGE_C;
    this.t_last_wr_end = NEG_LARGE_C;
    this.t_last_pre    = NEG_LARGE_C;
    this.pending_pre   = 1'b0;
    this.pending_ref   = 1'b0;
  endfunction
endclass
