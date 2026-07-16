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
// vip_dram_req
//
// Neutral, protocol-agnostic memory-request item carried into vip_dram over a
// TLM analysis FIFO (no virtual interface, no bus, no clock). The caller —
// typically vip_mc — owns the AXI4->DRAM translation and hands the device a
// request already expressed in DRAM column-access ("beat") granularity.
//
// Parameterized by the device config struct vip_dram_cfg_t so the wdata/wstrb
// element widths track the device channel width via vip_dram_types #(CFG_P);
// a consumer instantiates vip_dram_req #(CFG_P) for the same CFG_P it used to
// parameterize the vip_dram device.
//
// Not a randomization item: the MC/sequence populates the fields directly, so
// there are no `rand` fields or constraints (mirrors how the neutral contract
// is driven, not solved). See vip_dram/IMPLEMENTATION_PLAN.md
// "Neutral request/response API" and "Beat granularity & transaction
// semantics (the contract)".
//
////////////////////////////////////////////////////////////////////////////////

class vip_dram_req #(
  vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_sequence_item;

  // Per-CFG_P channel-row aliases. One element of wdata/wstrb is one DRAM
  // column access (8 * CFG_P.ROW_BYTES_P bits / CFG_P.ROW_BYTES_P strobe bits).
  typedef vip_dram_types #(CFG_P)::data_t data_t;
  typedef vip_dram_types #(CFG_P)::strb_t strb_t;

  // ---------------------------------------------------------------------------
  // Request payload
  // ---------------------------------------------------------------------------

  // Byte address (RD/WR only; ignored for REF). The device decodes it to
  // {rank,bg,bank,row,col} via its addr_map unless has_explicit_rank is set.
  longint unsigned addr = '0;

  // Operation. REF ignores addr/wdata/wstrb; it refreshes the rank named by
  // `rank` directly (see `rank` below).
  vip_dram_op_t op = VIP_DRAM_OP_RD_E;

  // Number of DRAM column accesses (BL8 bursts) in this request — NOT the AXI4
  // awlen+1/arlen+1 bus-beat count. One column access moves
  // vip_dram_types #(CFG_P)::DATA_BITS bits. Successive accesses advance the
  // column index on the same open row (page hits spaced by tCCD_x). beats >= 1
  // for RD/WR; ignored for REF.
  int unsigned beats = 1;

  // Rank selection for RD/WR. has_explicit_rank == 0 (default): the device
  // derives the rank from addr via its addr_map (including the ordinary
  // decode-to-rank-0 case). has_explicit_rank == 1: the caller forces `rank`
  // verbatim and the device skips address slicing. The validity bit is what
  // distinguishes "normal traffic that happens to land on rank 0" from
  // "explicitly forced rank 0" — the rank value alone cannot.
  //
  // For REF this bit is irrelevant: REF has no address to decode, so the
  // scheduler always refreshes `rank` directly (set `rank`; has_explicit_rank
  // is not consulted).
  bit          has_explicit_rank = 1'b0;
  int unsigned rank = '0;

  // Write payload — one element per column access (`beats` elements). Element
  // width is the device channel width derived from CFG_P. Empty for RD/REF.
  data_t wdata [];
  strb_t wstrb [];

  // Caller's private tag — vip_dram echoes it on the response so the caller
  // can correlate the (possibly reordered) rsp with its original request.
  longint unsigned tag = '0;

  // Filled by vip_dram on accept (request arrival into the device). Absolute
  // time in NANOSECONDS (realtime) — the device models timing in ns, not in
  // integer sim-time units, so sub-ns values (e.g. tRCD=13.75 ns) are exact.
  realtime arrival_time = 0.0;

  `uvm_object_param_utils(vip_dram_req #(CFG_P))

  typedef vip_dram_req #(CFG_P) req_t;

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(string name = "vip_dram_req");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Explicit do_copy — house style avoids the uvm_field_* macros for speed.
  // ---------------------------------------------------------------------------
  function void do_copy(uvm_object rhs);

    req_t _rhs;
    super.do_copy(rhs);
    if (!$cast(_rhs, rhs)) begin
      `uvm_fatal("CASTFAIL", "do_copy cast failed")
    end

    this.addr              = _rhs.addr;
    this.op                = _rhs.op;
    this.beats             = _rhs.beats;
    this.has_explicit_rank = _rhs.has_explicit_rank;
    this.rank              = _rhs.rank;
    this.wdata             = _rhs.wdata;
    this.wstrb             = _rhs.wstrb;
    this.tag               = _rhs.tag;
    this.arrival_time      = _rhs.arrival_time;
  endfunction

  // ---------------------------------------------------------------------------
  // Explicit do_compare. arrival_time is device-assigned bookkeeping, not part
  // of the request's identity, so it is deliberately excluded.
  // ---------------------------------------------------------------------------
  function bit do_compare(uvm_object rhs, uvm_comparer comparer);

    req_t _rhs;
    bit   result = super.do_compare(rhs, comparer);
    if (!$cast(_rhs, rhs)) begin
      return 0;
    end

    result &= (this.addr              == _rhs.addr);
    result &= (this.op                == _rhs.op);
    result &= (this.beats             == _rhs.beats);
    result &= (this.has_explicit_rank == _rhs.has_explicit_rank);
    result &= (this.rank              == _rhs.rank);
    result &= (this.tag               == _rhs.tag);

    result &= (this.wdata.size()      == _rhs.wdata.size());
    result &= (this.wstrb.size()      == _rhs.wstrb.size());
    foreach (this.wdata[i]) begin
      result &= (this.wdata[i] == _rhs.wdata[i]);
    end
    foreach (this.wstrb[i]) begin
      result &= (this.wstrb[i] == _rhs.wstrb[i]);
    end

    return result;
  endfunction

  // ---------------------------------------------------------------------------
  // Readable single-line summary.
  // ---------------------------------------------------------------------------
  function string convert2string();

    string s;

    if (this.op == VIP_DRAM_OP_REF_E) begin
      s = $sformatf("REQ: op = %s rank = %0d tag = %0h", this.op.name(), this.rank, this.tag);
    end
    else begin
      s = $sformatf(
        "REQ: op = %s addr = 0x%0h beats = %0d %s tag = %0h wdata.size = %0d",
        this.op.name(), this.addr, this.beats,
        this.has_explicit_rank ? $sformatf("rank = %0d (forced)", this.rank) : "rank = (decode)",
        this.tag, this.wdata.size());
    end
    return s;
  endfunction
endclass
