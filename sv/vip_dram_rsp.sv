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
// vip_dram_rsp
//
// Neutral, protocol-agnostic response item published by vip_dram on its
// rsp_port after a request's scheduled latency elapses. The device echoes the
// caller's `tag` so the caller (typically vip_mc) can correlate the response
// with its originating vip_dram_req even when responses retire out of issue
// order.
//
// Parameterized by the same vip_dram_cfg_t as the request and the device so
// the rdata element width tracks the device channel width via
// vip_dram_types #(CFG_P). Not a randomization item — populated by the device.
//
// The timing contract is two absolute times (not durations): the readiness of
// the first and last column accesses. For beats == 1 the two are equal. See
// vip_dram/IMPLEMENTATION_PLAN.md "Neutral request/response API" and "Beat
// granularity & transaction semantics (the contract)".
//
////////////////////////////////////////////////////////////////////////////////

class vip_dram_rsp #(
  vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_sequence_item;

  typedef vip_dram_types #(CFG_P)::data_t data_t;

  // ---------------------------------------------------------------------------
  // Correlation + operation
  // ---------------------------------------------------------------------------

  // Echo of vip_dram_req.tag.
  longint unsigned tag = '0;

  // Operation this response completes (RD returns rdata; WR/REF carry none).
  vip_dram_op_t op = VIP_DRAM_OP_RD_E;

  // Read payload — one element per column access (RD only; empty for WR/REF).
  data_t rdata [];

  // ---------------------------------------------------------------------------
  // Timing contract — absolute readiness times in NANOSECONDS (realtime; see
  // §"Beat granularity"). The device models timing in ns, so sub-ns values are
  // exact (no truncation to integer sim-time units). first == readiness of
  // column access 0; last == readiness of access beats-1. Equal when beats == 1.
  // ---------------------------------------------------------------------------

  realtime first_beat_ready_time = 0.0;
  realtime last_beat_ready_time  = 0.0;

  // ---------------------------------------------------------------------------
  // Introspection — set on RD/WR completion. Mutually exclusive: exactly one of
  // these is asserted per access classification (row already open and matching
  // = hit; open but wrong row = miss; bank closed/precharged = empty).
  // ---------------------------------------------------------------------------

  logic was_page_hit   = 1'b0;
  logic was_page_miss  = 1'b0;
  logic was_page_empty = 1'b0;

  // ---------------------------------------------------------------------------
  // Device read-fault severity (§11 item 5). Set on RD completion from the
  // device's addressable fault map (default NONE). A controller-side SECDED
  // layer classifies it: CORRECTABLE is corrected to OKAY, UNCORRECTABLE becomes
  // a bus SLVERR.
  //
  // The payload IS physically corrupted now: on a faulted beat the device flips
  // one bit (CORRECTABLE) or two bits (UNCORRECTABLE) of rdata. `corrupt_mask`
  // is the per-beat XOR of the bits a SECDED decoder can *repair* — i.e. the
  // single-bit flip of a correctable beat; an uncorrectable beat is flipped but
  // carries a zero mask (unrepairable). A controller that runs ECC un-flips
  // `corrupt_mask` to restore correctable beats; a controller with ECC off sees
  // the corrupted bytes verbatim (silent data corruption). Empty on a clean read.
  // ---------------------------------------------------------------------------

  vip_dram_fault_e injected_fault = VIP_DRAM_FAULT_NONE_E;
  data_t           corrupt_mask [];

  `uvm_object_param_utils(vip_dram_rsp #(CFG_P))

  typedef vip_dram_rsp #(CFG_P) rsp_t;

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(string name = "vip_dram_rsp");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Explicit do_copy — house style avoids the uvm_field_* macros for speed.
  // ---------------------------------------------------------------------------
  function void do_copy(uvm_object rhs);

    rsp_t _rhs;
    super.do_copy(rhs);
    if (!$cast(_rhs, rhs)) begin
      `uvm_fatal("CASTFAIL", "do_copy cast failed")
    end

    this.tag                   = _rhs.tag;
    this.op                    = _rhs.op;
    this.rdata                 = _rhs.rdata;
    this.first_beat_ready_time = _rhs.first_beat_ready_time;
    this.last_beat_ready_time  = _rhs.last_beat_ready_time;
    this.was_page_hit          = _rhs.was_page_hit;
    this.was_page_miss         = _rhs.was_page_miss;
    this.was_page_empty        = _rhs.was_page_empty;
    this.injected_fault        = _rhs.injected_fault;
    this.corrupt_mask          = _rhs.corrupt_mask;
  endfunction

  // ---------------------------------------------------------------------------
  // Explicit do_compare. Times and page-classification flags are simulation
  // observables rather than response identity, so identity comparison covers
  // tag/op/rdata; a scoreboard compares timing separately against predict().
  // ---------------------------------------------------------------------------
  function bit do_compare(uvm_object rhs, uvm_comparer comparer);

    rsp_t _rhs;
    bit   result = super.do_compare(rhs, comparer);

    if (!$cast(_rhs, rhs)) begin
      return 0;
    end

    result &= (this.tag          == _rhs.tag);
    result &= (this.op           == _rhs.op);
    result &= (this.rdata.size() == _rhs.rdata.size());

    foreach (this.rdata[i]) begin
      result &= (this.rdata[i] == _rhs.rdata[i]);
    end

    return result;
  endfunction

  // ---------------------------------------------------------------------------
  // Readable single-line summary.
  // ---------------------------------------------------------------------------
  function string convert2string();

    string page;

    page = this.was_page_hit   ? "hit"   :
           this.was_page_miss  ? "miss"  :
           this.was_page_empty ? "empty" : "n/a";

    return $sformatf(
      "RSP: op = %s tag = %0h rdata.size = %0d first = %0.3f ns last = %0.3f ns page = %s fault = %s",
      this.op.name(), this.tag, this.rdata.size(),
      this.first_beat_ready_time, this.last_beat_ready_time, page,
      this.injected_fault.name());
  endfunction
endclass
