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
// vip_dram
//
// The protocol-agnostic DDR device model (§7.5): a passive uvm_component that
// owns the runtime config, the timing scheduler, and a vip_mem backing store.
// It has NO virtual interface, NO clocking block and NO bus dependency, so it
// drops into any UVM env (with or without vip_mc) and is driven entirely over a
// neutral TLM contract:
//   - req_fifo  : MC -> device, vip_dram_req items (DRAM column-access grain)
//   - rsp_port  : device -> MC, vip_dram_rsp items, published after the
//                 scheduled latency elapses (echoes req.tag for correlation)
//
// The consumer drains req_fifo, asks the scheduler for the access timing AND the
// page classification, performs the actual vip_mem read/write, and forks a
// time-delayed response that fires at last_beat_ready_time. A reset cancels
// every in-flight forked response (B5) via `disable fork` so no stale beat can
// fire afterwards. REF arrives as an ordinary request — the device forks no
// internal refresh loop.
//
// All timing is absolute NANOSECONDS (realtime) computed against $realtime.
// Internal members/helpers are `protected`; member/method references use this.*
// (house style). `include`d into the umbrella vip_dram_pkg.
//
////////////////////////////////////////////////////////////////////////////////

class vip_dram #(
  vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_component;

  typedef vip_dram_req #(CFG_P) req_t;
  typedef vip_dram_rsp #(CFG_P) rsp_t;
  typedef vip_dram_types #(CFG_P)::data_t data_t;
  typedef vip_dram_types #(CFG_P)::strb_t strb_t;
  typedef vip_dram_types #(CFG_P)::addr_t addr_t;
  // Timing + page classification returned by the scheduler (by value).
  typedef vip_dram_scheduler #(CFG_P)::result_t sched_result_t;

  localparam vip_mem_cfg_t MEM_CFG = vip_dram_types #(CFG_P)::MEM_CFG;

  // Bits in one column-access word (one neutral-TLM beat). Used by the read-fault
  // model to place the corrupted bit(s) within a 64-bit SECDED word.
  localparam int DATA_BITS_C = 8 * CFG_P.ROW_BYTES_P;

  // vip_mem instance type and its whole-image type, declared CLASS-LOCAL (per
  // CFG_P) so no width-specific symbol leaks into the package namespace (§4).
  typedef vip_mem #(MEM_CFG)      mem_t;
  typedef mem_t::mem_get_type_t   image_t;

  // -- Public surface ---------------------------------------------------------
  // Runtime config (geometry is the CFG_P parameter). Sourced from the
  // config_db if present, else defaulted.
  vip_dram_config #(CFG_P)        cfg;
  // Neutral TLM endpoints. The MC connects its analysis port to
  // req_fifo.analysis_export and subscribes to rsp_port.
  uvm_tlm_analysis_fifo #(req_t)  req_fifo;
  uvm_analysis_port #(rsp_t)      rsp_port;
  // Reset handshake (§8): callers may trigger reset_event directly instead of
  // calling reset(); the consumer drains on either.
  uvm_event                       reset_event;

  // -- Internal ---------------------------------------------------------------
  protected vip_dram_scheduler #(CFG_P) scheduler;
  protected mem_t                       mem;
  protected uvm_event                   reset_done_event;

  // Device read-fault map (§11 item 5): row-aligned address -> fault severity.
  // A deterministic, addressable defect model (not probabilistic bus injection).
  // Persists across controller reset — a physical device fault does not clear on
  // rst_n; tests remove it explicitly via clear_fault()/clear_all_faults().
  protected vip_dram_fault_e            fault_by_addr[addr_t];

  `uvm_component_param_utils(vip_dram #(CFG_P))

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Build: resolve config, validate it, allocate the store/scheduler/TLM. The
  // scheduler is a plain object (not a component) constructed with the cfg
  // handle; it reads cfg.timing lazily at schedule() time.
  // ---------------------------------------------------------------------------
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(vip_dram_config #(CFG_P))::get(this, "", "cfg", this.cfg)) begin
      this.cfg = vip_dram_config #(CFG_P)::type_id::create("cfg");
    end
    this.cfg.validate();

    this.mem = new("mem");                    // vip_mem is not factory-registered
    this.mem.set_addr_width(CFG_P.ADDR_WIDTH_P);
    this.mem.cfg = this.cfg.mem_cfg;          // share the device storage X-handling

    this.scheduler        = new(this.cfg);
    this.req_fifo         = new("req_fifo", this);
    this.rsp_port         = new("rsp_port", this);
    this.reset_event      = new("reset_event");
    this.reset_done_event = new("reset_done_event");

    if (this.cfg.randomize_mem_on_reset) begin
      this.mem.randomize_memory();
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Consumer (§7.5). `work` drains requests forever; `on_reset` waits for a
  // reset. join_any returns ONLY on reset (work never completes), so the
  // disable fork that follows cancels work AND every delayed response forked
  // beneath it (B5) before the state is flushed.
  //
  // on_reset uses wait_PTRIGGER (persistent), so a reset() issued before this
  // consumer has armed its wait — e.g. at time 0, before run_phase scheduled —
  // is still caught rather than lost to a missed edge. The persistent state is
  // cleared (reset_event.reset()) after draining so the NEXT loop iteration
  // blocks again instead of spinning.
  // ---------------------------------------------------------------------------
  task run_phase(uvm_phase phase);

    forever begin

      fork

        begin : work

          forever begin

            req_t req;
            this.req_fifo.get(req);
            this.drive_one(req);
          end
        end

        begin : on_reset

          this.reset_event.wait_ptrigger();
        end
      join_any
      disable fork;                 // kills `work` + all in-flight delayed responses

      this.flush_in_flight();
      this.reset_event.reset();     // clear the persistent trigger for next time
      this.reset_done_event.trigger();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Schedule one request against live state and fork the time-delayed response.
  // schedule() returns the timing + page classification by value, so it is
  // carried into the fork directly — no scheduler member to read back.
  // ---------------------------------------------------------------------------
  protected task drive_one(req_t req);

    sched_result_t s;

    req.arrival_time = $realtime;
    s = this.scheduler.schedule(req);

    fork
      this.drive_response(req, s);
    join_none
  endtask

  // ---------------------------------------------------------------------------
  // Sleep until the last beat is ready, perform the memory access, then publish
  // the response. Cancelled wholesale by reset (disable fork in run_phase).
  // ---------------------------------------------------------------------------
  protected task drive_response(req_t req, sched_result_t s);

    rsp_t    rsp;
    realtime deliver_at;

    // §5.4 (vip_mc): optionally hand the response over when the first beat is
    // ready so a clocked adapter can pace beats first->last. The data is read at
    // delivery time and both ready-time stamps are carried regardless.
    deliver_at = this.cfg.deliver_at_first_beat ? s.first : s.last;
    if (deliver_at > $realtime) begin
      #(deliver_at - $realtime);
    end

    rsp                       = rsp_t::type_id::create("rsp");
    rsp.tag                   = req.tag;
    rsp.op                    = req.op;
    rsp.first_beat_ready_time = s.first;
    rsp.last_beat_ready_time  = s.last;
    rsp.was_page_hit          = s.hit;
    rsp.was_page_miss         = s.miss;
    rsp.was_page_empty        = s.empty;

    this.do_mem_access(req, rsp);
    this.rsp_port.write(rsp);
  endtask

  // ---------------------------------------------------------------------------
  // Frontdoor memory access. Each column access is one vip_mem row
  // (ROW_BYTES_P), and successive beats advance one row; the byte address is
  // row-aligned (the within-row byte offset is not part of a column access).
  // RD returns `beats` rows; WR applies per-beat wstrb. REF touches no memory.
  // ---------------------------------------------------------------------------
  protected function void do_mem_access(req_t req, rsp_t rsp);

    addr_t a;
    data_t d  [$];
    strb_t be [$];
    int    len;
    int    beats_eff;

    if (req.op == VIP_DRAM_OP_REF_E) begin
      return;
    end

    a = this.row_align(req.addr);

    // Contract: beats >= 1. Mirror the scheduler's clamp (vip_dram_scheduler
    // compute_latency) so a malformed beats == 0 request never leaves the memory
    // transfer size disagreeing with the one beat of timing the scheduler already
    // modelled for it.
    beats_eff = (req.beats == 0) ? 1 : req.beats;

    if (req.op == VIP_DRAM_OP_RD_E) begin

      len = beats_eff;
      this.mem.rd(a, d, len);
      rsp.rdata = new[beats_eff];

      foreach (rsp.rdata[i]) begin

        rsp.rdata[i] = d[i];
      end

      // Device read-fault (§11 item 5): tag the response with the worst fault
      // severity across every row this access touched (one row per beat) and
      // physically corrupt each faulted beat. A CORRECTABLE beat gets one bit
      // flipped and records that flip in corrupt_mask (the SECDED-repairable
      // syndrome); an UNCORRECTABLE beat gets two bits flipped and leaves its
      // mask zero (a double-bit error the decoder cannot repair). Bit positions
      // are derived from the row address so corruption is deterministic. The
      // flip happens in the device regardless of any controller ECC policy.
      rsp.injected_fault = VIP_DRAM_FAULT_NONE_E;
      rsp.corrupt_mask   = new[beats_eff];
      for (int i = 0; i < beats_eff; i++) begin
        addr_t           row_addr;
        vip_dram_fault_e row_fault;
        longint unsigned row_num;
        int              n_ecc_words;
        int              ecc_word;
        int              lo;

        rsp.corrupt_mask[i] = '0;
        row_addr  = this.row_align(a + (i * CFG_P.ROW_BYTES_P));
        row_fault = this.fault_by_addr.exists(row_addr) ?
                    this.fault_by_addr[row_addr] : VIP_DRAM_FAULT_NONE_E;
        if (row_fault > rsp.injected_fault) begin
          rsp.injected_fault = row_fault;
        end

        // Corrupted bit position, varied per row instead of pinned to bit 0.
        // row_addr is row-aligned, so shift out the within-column byte offset to
        // recover the column-access (row) number, which does vary, and fold it
        // onto a bit index. Choose the low bit INSIDE one 64-bit SECDED word
        // (ecc_word*64 + offset) so the UNCORRECTABLE pair (lo, lo^1) lands in
        // that same 64-bit word — a genuine double-bit DUE, not two separately
        // correctable single-bit errors in different words.
        row_num     = row_addr >> $clog2(CFG_P.ROW_BYTES_P);
        n_ecc_words = (DATA_BITS_C >= 64) ? (DATA_BITS_C / 64) : 1;
        ecc_word    = int'(row_num % n_ecc_words);
        lo          = ecc_word * 64 +
                      int'(row_num % ((DATA_BITS_C >= 64) ? 64 : DATA_BITS_C));

        if (row_fault == VIP_DRAM_FAULT_CORRECTABLE_E) begin
          rsp.corrupt_mask[i][lo] = 1'b1;                 // single-bit, repairable
          rsp.rdata[i] ^= rsp.corrupt_mask[i];
        end
        else if (row_fault == VIP_DRAM_FAULT_UNCORRECTABLE_E) begin
          rsp.rdata[i][lo]       ^= 1'b1;                 // double-bit DUE:
          rsp.rdata[i][lo ^ 1]   ^= 1'b1;                 // flipped, mask stays 0
        end
      end
    end
    else begin  // VIP_DRAM_OP_WR_E

      // Contract: one wdata/wstrb element per column access (beats elements). A
      // wstrb shorter than wdata would index out of range below (so guard it and
      // default missing strobes to all-enable); a beats vs wdata mismatch only
      // mis-models timing, so flag it but proceed.
      if (req.wdata.size() != req.beats) begin
        `uvm_error(get_name(), $sformatf(
        "WR beats = %0d but wdata.size = %0d (expected equal); timing modelled for beats",
        req.beats, req.wdata.size()))
      end

      if (req.wstrb.size() != req.wdata.size()) begin
        `uvm_error(get_name(), $sformatf(
        "WR wstrb.size = %0d != wdata.size = %0d; missing strobes default to all-enable",
        req.wstrb.size(), req.wdata.size()))
      end

      foreach (req.wdata[i]) begin

        d.push_back(req.wdata[i]);
        be.push_back((i < req.wstrb.size()) ? req.wstrb[i] : '1);
      end

      this.mem.wr_be(a, d, be);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // On reset: empty the request queue, reset all bank/rank scheduler state to
  // its deterministic post-reset values, and (optionally) re-randomize memory.
  // The in-flight responses were already cancelled by run_phase's disable fork.
  // ---------------------------------------------------------------------------
  protected function void flush_in_flight();

    this.req_fifo.flush();
    this.scheduler.reset();

    if (this.cfg.randomize_mem_on_reset) begin

      this.mem.randomize_memory();
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Reset (§8). A TASK, not a function: it must cancel in-flight forked
  // responses and block until the consumer has drained. Triggers reset_event
  // (which the consumer waits on) and waits for the drain to complete.
  // ---------------------------------------------------------------------------
  task reset();

    this.reset_event.trigger();
    this.reset_done_event.wait_trigger();
  endtask

  // ---------------------------------------------------------------------------
  // Side-effect-free latency predictor for the MC / scoreboard. Delegates to
  // the scheduler's single source of truth (shared with schedule()).
  // ---------------------------------------------------------------------------
  function void predict(
    input  req_t    req,
    output realtime first_beat_ready,
    output realtime last_beat_ready
  );
    sched_result_t s = this.scheduler.predict(req);
    first_beat_ready = s.first;
    last_beat_ready  = s.last;
  endfunction

  // ---------------------------------------------------------------------------
  // Debug counters (§4 / M5). These count events EXECUTED BY THE DEVICE — one
  // per request consumed — and are a different object from any controller-side
  // count (e.g. vip_mc.get_refresh_count() counts REF the controller EMITS).
  // The tallies live in the scheduler; these expose them on the public surface.
  // ---------------------------------------------------------------------------
  function int get_page_hit_count();   return int'(this.scheduler.n_page_hit);   endfunction
  function int get_page_miss_count();  return int'(this.scheduler.n_page_miss);  endfunction
  function int get_page_empty_count(); return int'(this.scheduler.n_page_empty); endfunction
  function int get_refresh_count();    return int'(this.scheduler.n_ref);        endfunction

  // ===========================================================================
  // Backdoor API (§4) — bypasses timing; operates directly on the store.
  // ===========================================================================

  // Write one column-access row at the row containing `addr` (all bytes).
  function void backdoor_write(longint unsigned addr, data_t data);
    addr_t a = this.row_align(addr);
    data_t q [$];
    q.push_back(data);
    this.mem.wr(a, q);
  endfunction

  // Read the column-access row at the row containing `addr`.
  function data_t backdoor_read(longint unsigned addr);
    addr_t a = this.row_align(addr);
    return this.mem.rd_addr(a);
  endfunction

  // Randomize the whole image (or a byte range).
  function void memory_randomize(longint unsigned addr_lo = '0,
                                 longint unsigned addr_hi = '1);
    addr_t lo = addr_lo;
    addr_t hi = addr_hi;
    this.mem.randomize_memory(lo, hi);
  endfunction

  // Clear the whole image (every row reads back 0 / X per cfg.mem_cfg).
  function void memory_reset();
    this.mem.reset();
  endfunction

  // Whole-image dump/load (class-local image_t — no leaked package symbol).
  function image_t backdoor_dump();
    return this.mem.get();
  endfunction
  function void backdoor_load(image_t img);
    this.mem.set(img);
  endfunction

  // ===========================================================================
  // Device read-fault injection (§11 item 5) — deterministic, addressable.
  // ===========================================================================

  // Mark the row containing `addr` as returning `fault` severity on reads. NONE
  // clears it. On a faulted read the device physically flips one bit
  // (CORRECTABLE) or two bits (UNCORRECTABLE) of that beat's rdata and reports
  // the repairable syndrome in the response's corrupt_mask/injected_fault fields
  // for a SECDED consumer (see vip_dram_rsp). The backing store is untouched —
  // only the response payload is corrupted.
  function void inject_fault(longint unsigned addr, vip_dram_fault_e fault);
    addr_t a = this.row_align(addr);
    if (fault == VIP_DRAM_FAULT_NONE_E) begin
      if (this.fault_by_addr.exists(a)) begin
        this.fault_by_addr.delete(a);
      end
    end
    else begin
      this.fault_by_addr[a] = fault;
    end
  endfunction

  // Clear any injected fault on the row containing `addr`.
  function void clear_fault(longint unsigned addr);
    addr_t a = this.row_align(addr);
    if (this.fault_by_addr.exists(a)) begin
      this.fault_by_addr.delete(a);
    end
  endfunction

  // Remove every injected fault.
  function void clear_all_faults();
    this.fault_by_addr.delete();
  endfunction

  // Read back the injected fault severity for the row containing `addr`.
  function vip_dram_fault_e get_fault(longint unsigned addr);
    addr_t a = this.row_align(addr);
    return this.fault_by_addr.exists(a) ? this.fault_by_addr[a]
                                        : VIP_DRAM_FAULT_NONE_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Row-align a byte address to the column-access (ROW_BYTES_P) granularity.
  // ---------------------------------------------------------------------------
  protected function addr_t row_align(longint unsigned addr);
    int sh = $clog2(CFG_P.ROW_BYTES_P);
    return (addr >> sh) << sh;
  endfunction
endclass
