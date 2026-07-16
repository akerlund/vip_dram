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
// vip_dram_scheduler
//
// The timing core (§7.4). Given a neutral vip_dram_req it computes the absolute
// readiness time of the first and last column accesses from the per-bank state
// and the cfg timing record, then commits the state update. All times are
// NANOSECONDS (realtime); the device computes against $realtime (no clock).
//
// Single source of truth (M9): the ~one-screen formula lives ONLY in the pure,
// side-effect-free compute_latency(). predict() (MC/scoreboard) and schedule()
// (the device) are thin wrappers over it that both RETURN a result_t (the two
// readiness times + the page classification), so the predicted and the
// committed timing can never drift and the caller needs no side-channel state.
// schedule() additionally calls commit_state(), the ONLY place bank/rank state
// is mutated.
//
// Each timing delay is quantized UP to whole DRAM clock cycles via cfg.t_ck
// (the §6 "stored in ns, converted to cycles" rule) by quantize(); for the
// authoritative DDR4-3200 preset every value is already a whole-cycle multiple
// so quantize() is an identity there.
//
// Internal members/helpers are `protected` (only the device/scoreboard-facing
// predict/schedule/reset and the debug counters are public) and every
// member/method reference is via this.* (house style).
//
// Parameterized by CFG_P: geometry sizes the bank array and drives the address
// decode (vip_dram_addr_pkg). `include`d into the umbrella vip_dram_pkg.
//
////////////////////////////////////////////////////////////////////////////////

class vip_dram_scheduler #(
  vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
);

  typedef vip_dram_req #(CFG_P) req_t;

  localparam int BANKS_PER_RANK_C = CFG_P.N_BANK_GROUPS_P * CFG_P.BANKS_PER_BG_P;
  localparam int N_RANKS_C        = CFG_P.N_RANKS_P;
  localparam int N_BG_C           = CFG_P.N_BANK_GROUPS_P;

  // Runtime config (timing record + addr_map + policy/flags). Set in new().
  protected vip_dram_config #(CFG_P) cfg;

  // Per-(rank,bank) state, flattened: idx = rank*BANKS_PER_RANK_C + bank_index.
  protected vip_dram_bank_state bank [];

  // Rank-level activate tracking for tRRD / tFAW.
  protected realtime last_act_any [];    // [rank]      most recent ACT, any bank group
  protected realtime last_act_bg  [][];  // [rank][bg]  most recent ACT, that bank group
  protected realtime faw_ring     [][];  // [rank][0..3] last four ACT command times
  protected int      faw_wp       [];    // [rank]      ring write pointer

  // Rank-level CAS tracking for column spacing (tCCD_S/L) and bus turnaround
  // (tWTR_S/L, tRTW). These make the cross-bank-group constraints live: the _L
  // variant applies vs the same bank group, the _S variant vs any other (and
  // since _L >= _S, the _S term only binds when the prior CAS really was to a
  // different bank group). tWTR is data-end-referenced; tCCD/tRTW are
  // command-referenced (§6 reference-edge table).
  protected realtime last_cas_any    [];    // [rank]      most recent RD/WR CAS command, any bg
  protected realtime last_cas_bg     [][];  // [rank][bg]  most recent RD/WR CAS command, that bg
  protected realtime last_wr_end_any [];    // [rank]      most recent WR data-burst end, any bg
  protected realtime last_wr_end_bg  [][];  // [rank][bg]  most recent WR data-burst end, that bg
  protected realtime last_rd_cas_any [];    // [rank]      most recent RD CAS command, any bg (tRTW ref)

  // Channel-level bus + per-rank refresh state. The DQ data bus is shared by
  // every rank in the channel, so burst contention is ONE channel-wide edge
  // (not per-rank); REF blocks only its own rank.
  protected realtime last_burst_end_chan;   //        last data-burst end on the channel (tBL contention)
  protected realtime rank_busy [];          // [rank] busy-until (REF blocks the rank)

  // Public result of predict()/schedule(): the timing contract (two absolute
  // readiness times) plus the page classification, returned BY VALUE so callers
  // need no side-channel state. hit/miss/empty are mutually exclusive and all 0
  // for a REF (is_ref set instead).
  typedef struct {
    realtime first;   // data ready, column access 0
    realtime last;    // data ready, column access beats-1 (== first when beats==1)
    bit      hit;     // bank was open on the requested row
    bit      miss;    // bank was open on a different row
    bit      empty;   // bank was precharged/closed
    bit      is_ref;  // REF request (hit/miss/empty all 0)
  } result_t;

  // Debug counters (§"Debug counters"). Public reads.
  longint unsigned n_page_hit;
  longint unsigned n_page_miss;
  longint unsigned n_page_empty;
  longint unsigned n_ref;

  // Internal latency result — everything compute_latency() produces, so
  // commit_state() never recomputes. Unpacked (carries realtime fields).
  typedef struct {
    realtime first;        // data ready, column access 0
    realtime last;         // data ready, column access beats-1
    realtime cas0;         // first CAS command time (effective, after any bus delay)
    realtime cas_last;     // last  CAS command time
    realtime act_time;     // ACT command time (valid when did_activate)
    realtime pre_at;       // PRE command time (valid when did_precharge)
    realtime burst_end;    // data-burst end of the last access (tBL contention)
    int      idx;          // flat bank index
    int      rank;
    int      bg;
    int      row;
    bit      is_read;
    bit      did_activate; // a new ACT issued (miss or empty)
    bit      did_precharge;// an implicit PRE issued (miss only)
    bit      is_ref;       // REF request (idx/bg/row unused)
    bit      hit;
    bit      miss;
    bit      empty;
  } lat_t;

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(vip_dram_config #(CFG_P) cfg);
    this.cfg = cfg;
    this.reset();
  endfunction

  // ---------------------------------------------------------------------------
  // Allocate + clear all state. Deterministic and seed-independent (§"Reset"):
  // every bank IDLE, FAW rings empty, every timestamp -inf, counters zeroed.
  // ---------------------------------------------------------------------------
  function void reset();
    int n_banks = N_RANKS_C * BANKS_PER_RANK_C;

    this.bank            = new[n_banks];
    this.last_act_any    = new[N_RANKS_C];
    this.last_act_bg     = new[N_RANKS_C];
    this.faw_ring        = new[N_RANKS_C];
    this.faw_wp          = new[N_RANKS_C];
    this.last_cas_any    = new[N_RANKS_C];
    this.last_cas_bg     = new[N_RANKS_C];
    this.last_wr_end_any = new[N_RANKS_C];
    this.last_wr_end_bg  = new[N_RANKS_C];
    this.last_rd_cas_any = new[N_RANKS_C];
    this.rank_busy       = new[N_RANKS_C];

    foreach (this.bank[i]) begin
      this.bank[i] = new();
    end

    for (int r = 0; r < N_RANKS_C; r++) begin

      this.last_act_any[r]    = vip_dram_bank_state::NEG_LARGE_C;
      this.last_cas_any[r]    = vip_dram_bank_state::NEG_LARGE_C;
      this.last_wr_end_any[r] = vip_dram_bank_state::NEG_LARGE_C;
      this.last_rd_cas_any[r] = vip_dram_bank_state::NEG_LARGE_C;
      this.rank_busy[r]       = vip_dram_bank_state::NEG_LARGE_C;
      this.faw_wp[r]          = 0;
      this.last_act_bg[r]     = new[N_BG_C];
      this.last_cas_bg[r]     = new[N_BG_C];
      this.last_wr_end_bg[r]  = new[N_BG_C];
      this.faw_ring[r]        = new[4];

      foreach (this.last_act_bg[r][g]) begin
        this.last_act_bg[r][g] = vip_dram_bank_state::NEG_LARGE_C;
      end

      foreach (this.last_cas_bg[r][g]) begin
        this.last_cas_bg[r][g] = vip_dram_bank_state::NEG_LARGE_C;
      end

      foreach (this.last_wr_end_bg[r][g]) begin
        this.last_wr_end_bg[r][g] = vip_dram_bank_state::NEG_LARGE_C;
      end

      foreach (this.faw_ring[r][k]) begin
        this.faw_ring[r][k] = vip_dram_bank_state::NEG_LARGE_C;
      end
    end

    this.last_burst_end_chan = vip_dram_bank_state::NEG_LARGE_C;

    this.n_page_hit   = '0;
    this.n_page_miss  = '0;
    this.n_page_empty = '0;
    this.n_ref        = '0;
  endfunction

  // ---------------------------------------------------------------------------
  // Side-effect-free predictor (MC / scoreboard). Computes against the CURRENT
  // bank state at the current $realtime; mutates nothing. Returns the timing +
  // page classification.
  // ---------------------------------------------------------------------------
  function result_t predict(input req_t req);
    return this.pack(this.compute_latency(req));
  endfunction

  // ---------------------------------------------------------------------------
  // Scheduler: compute against live state, commit the state update, bump the
  // debug counters, and return the timing + page classification (no side-channel
  // member state — the caller uses the return value).
  // ---------------------------------------------------------------------------
  function result_t schedule(input req_t req);
    lat_t r = this.compute_latency(req);
    this.commit_state(r);
    if      (r.is_ref) this.n_ref++;
    else if (r.hit)    this.n_page_hit++;
    else if (r.miss)   this.n_page_miss++;
    else if (r.empty)  this.n_page_empty++;
    return this.pack(r);
  endfunction

  // ---------------------------------------------------------------------------
  // Project the internal lat_t down to the public result_t (the caller-facing
  // timing + classification; the rest of lat_t is commit bookkeeping).
  // ---------------------------------------------------------------------------
  protected function result_t pack(input lat_t r);
    pack = '{first:  r.first, last:   r.last,
             hit:    r.hit,   miss:   r.miss,
             empty:  r.empty, is_ref: r.is_ref};
  endfunction

  // ===========================================================================
  // The ONLY place the §7.4 formulas live. Pure: reads this.bank / rank arrays
  // and this.cfg.timing, returns the timing, mutates nothing.
  // ===========================================================================
  protected function lat_t compute_latency(input req_t req);

    lat_t               r;
    vip_dram_timing_t   t = this.cfg.timing;
    vip_dram_dec_t      d;
    vip_dram_bank_state b;
    realtime            now;
    realtime            act_ready;
    realtime            cas_floor;
    realtime            add0;
    int unsigned        beats;

    r = '{default: 0};

    // -- REF: blocks the whole rank for tRFC, then precharge-all -------------
    if (req.op == VIP_DRAM_OP_REF_E) begin
      int rank = req.rank;  // REF refreshes this rank directly (no addr decode)
      if (rank >= N_RANKS_C) begin
        `uvm_fatal("vip_dram_scheduler", $sformatf(
          "REF rank %0d out of range (N_RANKS_P = %0d)", rank, N_RANKS_C))
      end
      r.is_ref = 1'b1;
      r.rank   = rank;
      now      = this.rank_last_op(rank);          // already folds in $realtime
      r.first  = now + this.quantize(t.tRFC);
      r.last   = r.first;
      return r;
    end

    // -- Decode address -> {rank,bg,bank,row}; flatten the bank index --------
    d         = vip_dram_decode_addr(req.addr, CFG_P, this.cfg.addr_map);
    r.rank    = req.has_explicit_rank ? req.rank : d.rank;
    if (r.rank >= N_RANKS_C) begin
      `uvm_fatal("vip_dram_scheduler", $sformatf(
        "RD/WR rank %0d out of range (N_RANKS_P = %0d); check has_explicit_rank/rank or the addr_map",
        r.rank, N_RANKS_C))
    end
    r.bg      = d.bg;
    r.row     = d.row;
    r.idx     = r.rank * BANKS_PER_RANK_C + vip_dram_bank_index(CFG_P, d);
    r.is_read = (req.op == VIP_DRAM_OP_RD_E);
    beats     = (req.beats == 0) ? 1 : req.beats;  // contract: beats >= 1 (guard underflow)
    b         = this.bank[r.idx];

    // `now` floors every term and also serves the REF block: an access cannot
    // start before the rank is free again.
    now = this.maxr($realtime, this.rank_busy[r.rank]);

    // -- Classify the first column access ------------------------------------
    r.hit   = (b.state == VIP_DRAM_BANK_ACTIVE_E) && (b.open_row == r.row);
    r.miss  = (b.state == VIP_DRAM_BANK_ACTIVE_E) && (b.open_row != r.row);
    r.empty = (b.state != VIP_DRAM_BANK_ACTIVE_E);

    // `cas_floor` is the earliest the first CAS could issue based purely on the
    // ROW state (hit -> now; miss/empty -> ACT + tRCD). The cross-bank-group
    // column-spacing and bus-turnaround constraints are layered on top below, so
    // they apply uniformly to hits, misses and empties.
    if (r.hit) begin
      r.act_time = b.t_last_act;   // unchanged, no new ACT
      cas_floor  = now;
    end
    else begin
      r.did_activate = 1'b1;
      if (r.miss) begin
        // Different row open: PRE (respecting tRTP/tWR/tRAS) then ACT (+tRP).
        r.did_precharge = 1'b1;
        r.pre_at  = this.max3(b.t_last_rd     + this.quantize(t.tRTP),
                              b.t_last_wr_end  + this.quantize(t.tWR),
                              b.t_last_act     + this.quantize(t.tRAS));
        r.pre_at  = this.maxr(now, r.pre_at);
        act_ready = r.pre_at + this.quantize(t.tRP);
      end
      else begin
        // Bank closed/precharged: ACT can issue once the prior PRE settled.
        act_ready = this.maxr(now, b.t_last_pre + this.quantize(t.tRP));
      end
      r.act_time = this.gate_activate(r.rank, r.bg, act_ready);  // tRRD + tFAW
      cas_floor  = r.act_time + this.quantize(t.tRCD);
    end

    // -- Rank-level CAS scheduling: column spacing (tCCD) + bus turnaround ----
    // Column-to-column: tCCD_L vs the most recent CAS to THIS bank group (which
    // includes the same bank), tCCD_S vs the most recent CAS to ANY bank group.
    // Direction turnaround (a rank/bus-level constraint, not per-bank): WR->RD =
    // tWTR (last WR DATA referenced; _L same bg / _S any bg), RD->WR = tRTW (RD
    // COMMAND referenced). For a freshly-reset rank every term is -inf, so the
    // first access collapses to cas_floor.
    r.cas0 = this.max3(cas_floor,
                       this.last_cas_bg[r.rank][r.bg] + this.quantize(t.tCCD_L),
                       this.last_cas_any[r.rank]      + this.quantize(t.tCCD_S));
    if (r.is_read) begin
      r.cas0 = this.max3(r.cas0,
                         this.last_wr_end_bg[r.rank][r.bg] + this.quantize(t.tWTR_L),
                         this.last_wr_end_any[r.rank]      + this.quantize(t.tWTR_S));
    end
    else begin
      r.cas0 = this.maxr(r.cas0,
                         this.last_rd_cas_any[r.rank] + this.quantize(t.tRTW));
    end

    // -- Per-beat data readiness + bus contention ---------------------------
    // Data ready of access 0 is CAS + tCL (read) / + tWL (write). Subsequent
    // accesses on the now-open row are page hits spaced by tCCD_L, and since CAS
    // latency is constant the DATA spacing is exactly tCCD_L (test #2: per-access
    // ~ tCCD_L, NOT tBL and NOT another tCL).
    add0    = r.is_read ? this.quantize(t.tCL) : this.quantize(t.tWL);
    r.first = r.cas0 + add0;

    // Bus contention: the channel DQ bus carries one burst (tBL) at a time, so
    // the next data word — on ANY rank in this channel — cannot begin before the
    // previous burst has cleared. Gate the DATA (not the command) so an idle bus
    // adds nothing (last_burst_end_chan is -inf after reset).
    if (this.cfg.enable_bus_contention) begin
      r.first = this.maxr(r.first, this.last_burst_end_chan);
    end

    // Effective CAS after any bus delay keeps cas_last / commit consistent.
    r.cas0      = r.first - add0;
    r.cas_last  = r.cas0 + realtime'(beats - 1) * this.quantize(t.tCCD_L);
    r.last      = r.cas_last + add0;
    r.burst_end = r.last + this.quantize(t.tBL);   // last data-burst end

    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // The ONLY mutation point. Applies the result of compute_latency() to live
  // bank/rank state.
  // ---------------------------------------------------------------------------
  protected function void commit_state(input lat_t r);

    vip_dram_bank_state b;

    // -- REF: precharge-all on the rank, mark it busy until tRFC completes ----
    if (r.is_ref) begin
      for (int k = 0; k < BANKS_PER_RANK_C; k++) begin
        b = this.bank[r.rank * BANKS_PER_RANK_C + k];
        b.state      = VIP_DRAM_BANK_IDLE_E;
        b.open_row   = 0;
        b.t_last_pre = vip_dram_bank_state::NEG_LARGE_C; // refreshed = fresh PRE
      end
      this.rank_busy[r.rank] = r.first;   // rank free again at REF end
      return;
    end

    b = this.bank[r.idx];

    if (r.did_activate) begin
      if (r.did_precharge) b.t_last_pre = r.pre_at;
      b.t_last_act = r.act_time;
      b.state      = VIP_DRAM_BANK_ACTIVE_E;
      b.open_row   = r.row;
      // Rank ACT tracking for tRRD / tFAW.
      this.last_act_any[r.rank]      = r.act_time;
      this.last_act_bg[r.rank][r.bg] = r.act_time;
      this.faw_push(r.rank, r.act_time);
    end

    if (r.is_read) begin
      b.t_last_rd     = r.cas_last;
      b.t_last_rd_end = r.burst_end;   // read DATA-burst end (incl tBL), like writes
    end
    else begin
      b.t_last_wr     = r.cas_last;
      b.t_last_wr_end = r.burst_end;   // tWTR/tWR reference the last WR DATA
    end

    // Rank-level CAS spacing: both directions advance the column-access clock
    // (tCCD is CAS-to-CAS). Use the LAST CAS command of this request (cas_last).
    this.last_cas_bg[r.rank][r.bg] = r.cas_last;
    this.last_cas_any[r.rank]      = r.cas_last;
    if (r.is_read) begin
      this.last_rd_cas_any[r.rank]      = r.cas_last;   // tRTW reference (RD command)
    end
    else begin
      this.last_wr_end_bg[r.rank][r.bg] = r.burst_end;  // tWTR reference (WR data end)
      this.last_wr_end_any[r.rank]      = r.burst_end;
    end

    // Channel-wide data-bus contention (shared by all ranks in the channel).
    this.last_burst_end_chan = r.burst_end;
  endfunction

  // ===========================================================================
  // Helpers
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Quantize a ns delay UP to whole DRAM clock cycles (§6). Identity for the
  // authoritative DDR4 preset (all values whole-cycle multiples); 0 for IDEAL.
  // ---------------------------------------------------------------------------
  protected function realtime quantize(real ns);
    return realtime'(this.cfg.ns_to_cycles(ns)) * this.cfg.timing.t_ck;
  endfunction

  // ---------------------------------------------------------------------------
  // Real max helpers.
  // ---------------------------------------------------------------------------
  protected function realtime maxr(realtime a, realtime b);
    return (a > b) ? a : b;
  endfunction

  protected function realtime max3(realtime a, realtime b, realtime c);
    return this.maxr(this.maxr(a, b), c);
  endfunction

  // ---------------------------------------------------------------------------
  // Gate an ACT by the rank ACT-spacing rules: tRRD_S (any prior ACT this rank),
  // tRRD_L (prior ACT same bank group), and tFAW (>= oldest-of-last-4 + tFAW).
  // ---------------------------------------------------------------------------
  protected function realtime gate_activate(input int rank, input int bg,
                                            input realtime earliest);
    realtime g = earliest;
    g = this.maxr(g, this.last_act_any[rank]    + this.quantize(this.cfg.timing.tRRD_S));
    g = this.maxr(g, this.last_act_bg[rank][bg] + this.quantize(this.cfg.timing.tRRD_L));
    g = this.maxr(g, this.faw_oldest(rank)      + this.quantize(this.cfg.timing.tFAW));
    return g;
  endfunction

  // ---------------------------------------------------------------------------
  // Oldest of the rank's last four ACT command times (the FAW window anchor).
  // ---------------------------------------------------------------------------
  protected function realtime faw_oldest(input int rank);
    realtime m = this.faw_ring[rank][0];
    for (int k = 1; k < 4; k++) begin
      if (this.faw_ring[rank][k] < m) m = this.faw_ring[rank][k];
    end
    return m;
  endfunction

  // ---------------------------------------------------------------------------
  // Push an ACT time into the rank's 4-deep ring (overwrites the oldest slot).
  // ---------------------------------------------------------------------------
  protected function void faw_push(input int rank, input realtime act_time);
    this.faw_ring[rank][this.faw_wp[rank]] = act_time;
    this.faw_wp[rank] = (this.faw_wp[rank] + 1) % 4;
  endfunction

  // ---------------------------------------------------------------------------
  // Latest activity on a rank (for the REF block): max over all bank command/
  // data timestamps and the current rank-busy / $realtime.
  // ---------------------------------------------------------------------------
  protected function realtime rank_last_op(input int rank);
    realtime m = this.maxr($realtime, this.rank_busy[rank]);
    for (int k = 0; k < BANKS_PER_RANK_C; k++) begin
      vip_dram_bank_state b = this.bank[rank * BANKS_PER_RANK_C + k];
      m = this.maxr(m, b.t_last_act);
      m = this.maxr(m, b.t_last_rd_end);
      m = this.maxr(m, b.t_last_wr_end);
      m = this.maxr(m, b.t_last_pre);
    end
    return m;
  endfunction
endclass
