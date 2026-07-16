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
// vip_dram_config
//
// Runtime (non-geometry) device properties for vip_dram: the timing record,
// the address-map slicing, page policy, behavioural flags, and the storage
// primitive's X-handling. Geometry and channel widths are NOT here — they are
// the compile-time CFG_P parameter (vip_dram_types_pkg). This object is
// parameterized by the same CFG_P so validate() can check the geometry and the
// default address map can be derived from it.
//
// Timing is stored in nanoseconds (the vip_dram_timing_pkg record); callers
// convert to whole DRAM clock cycles via ns_to_cycles() using the stored t_ck.
// apply_preset() loads the speed-bin AC timings and then re-derives tRFC from
// the per-die density implied by CFG_P — tRFC scales with die size, not the
// speed bin, so a re-sized device gets the right refresh time without a manual
// edit. Field overrides are still free afterwards. tREFI is carried here purely
// so vip_mc can read it when arming its refresh timer — vip_dram never uses it.
//
// See vip_dram/IMPLEMENTATION_PLAN.md "Timing parameters & realistic defaults"
// and "vip_dram_config (uvm_object)".
//
////////////////////////////////////////////////////////////////////////////////

class vip_dram_config #(
  vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_object;

  // Geometry-derived default address map (LSB-first). Constant-folded from the
  // parameter so it can seed the field initializer below.
  localparam vip_dram_addr_map_t DEFAULT_ADDR_MAP_C = vip_dram_default_addr_map(CFG_P);

  localparam real TIMING_EPS_C = 1.0e-9;   // real-compare slack (ns)

  // ---------------------------------------------------------------------------
  // Timing (ns) — source of truth. Loaded by apply_preset(); overridable.
  // ---------------------------------------------------------------------------
  vip_dram_timing_t timing;

  // The speed-bin preset last applied. Retained so validate() can recover the
  // generation for the tRFC density-table check and convert2string can report
  // it. Set by apply_preset() (and by new() via the default preset).
  vip_dram_preset_t preset = VIP_DRAM_PRESET_DDR4_3200_CL22_E;

  // ---------------------------------------------------------------------------
  // Address-map slicing. Defaults to the CFG_P-derived LSB-first layout; the MC
  // may overwrite it to impose its own interleaving (§7.2).
  // ---------------------------------------------------------------------------
  vip_dram_addr_map_t addr_map = DEFAULT_ADDR_MAP_C;

  // ---------------------------------------------------------------------------
  // Policy / behavioural flags
  // ---------------------------------------------------------------------------
  vip_dram_page_policy_t page_policy            = VIP_DRAM_PAGE_OPEN_E;
  bit                    enable_bus_contention  = 1'b1;   // channel-level tBL spacing
  bit                    enable_bank_scoreboard = 1'b0;   // debug logging
  bit                    randomize_mem_on_reset = 1'b0;

  // Deliver the response (with the full data + both ready-time stamps) when the
  // FIRST beat is ready instead of at last_beat_ready_time. The data is known at
  // any time (it is read from storage), so handing it over at first_beat_ready_
  // time lets a clocked protocol adapter (e.g. vip_mc) pace the beats first->last
  // per §5.4. Default 0 preserves the original "deliver complete at last"
  // behaviour for existing consumers; the timing stamps in the rsp are identical
  // either way.
  bit deliver_at_first_beat  = 1'b0;

  // ---------------------------------------------------------------------------
  // Device-storage X-handling for the vip_mem array vip_dram owns (§7.5). This
  // is a storage property of the device, NOT a bus/controller property — it is
  // set directly on the vip_dram instance and is never sourced from a
  // controller-side config (vip_mc Finding-4).
  // ---------------------------------------------------------------------------
  vip_mem_config mem_cfg;

  `uvm_object_param_utils(vip_dram_config #(CFG_P))

  // ---------------------------------------------------------------------------
  // mem_cfg is allocated here and never null thereafter; timing is seeded to
  // the DDR4-3200 default (the plan's reference preset). Both are freely
  // overridable afterwards.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_dram_config");
    super.new(name);
    this.mem_cfg = vip_mem_config::type_id::create("mem_cfg");
    apply_preset(VIP_DRAM_PRESET_DDR4_3200_CL22_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Load the speed-bin AC timings from a preset, then re-derive tRFC from the
  // per-die density (geometry). tRFC scales with die size, not the speed bin,
  // so this keeps it correct when CFG_P is re-sized. Derived fields (tRC/tBL/
  // tRTW) are computed inside vip_dram_get_preset(); overrides applied
  // afterwards are the caller's responsibility (validate() rechecks tRC).
  // ---------------------------------------------------------------------------
  function void apply_preset(vip_dram_preset_t preset);
    this.preset      = preset;
    this.timing      = vip_dram_get_preset(preset);
    this.timing.tRFC = vip_dram_trfc_ns(vip_dram_preset_gen(preset), density_gbit());
  endfunction

  // ---------------------------------------------------------------------------
  // Per-die density in Gbit, derived from the geometry. The channel holds
  // 2^ADDR_WIDTH_P bytes shared across N_RANKS_P*N_DEVICES_PER_RANK_P dies, so
  // one die is (2^ADDR_WIDTH_P * 8) / (devices * ranks) bits. This is what
  // selects tRFC (vip_dram_trfc_ns). Always a power of two in this model, since
  // every geometry field is a bit-width. longint math so the shift is 64-bit.
  // ---------------------------------------------------------------------------
  function int density_gbit();
    longint per_die_bits;
    per_die_bits = ((longint'(1) << CFG_P.ADDR_WIDTH_P) * 8)
                 / (CFG_P.N_DEVICES_PER_RANK_P * CFG_P.N_RANKS_P);
    return int'(per_die_bits >> 30);   // bits -> Gbit
  endfunction

  // ---------------------------------------------------------------------------
  // Round a nanosecond timing value up to whole DRAM clock cycles using the
  // stored t_ck. Centralizes the §6 "converted ... using cfg.t_ck" rule so the
  // scheduler and device share one quantization. Returns 0 for the IDEAL /
  // mis-configured t_ck<=0 case (guarded in the helper).
  // ---------------------------------------------------------------------------
  function int unsigned ns_to_cycles(real ns);
    return vip_dram_ns_to_cycles(ns, this.timing.t_ck);
  endfunction

  // ---------------------------------------------------------------------------
  // Sanity checks (§7.1). Geometry checks read the compile-time CFG_P fields;
  // timing checks read the runtime record. uvm_fatal on hard violations; the
  // address-width coverage check is a uvm_warning because a system address
  // width that is narrower than the full geometry decode is a (legal but
  // lossy) configuration the caller may have chosen deliberately.
  // ---------------------------------------------------------------------------
  function void validate();

    int            channel_bits;
    int            byte_w, col_w, bank_w, bg_w, row_w, rank_w;
    int            addr_bits;
    vip_dram_gen_t gen;
    int            max_gbit;
    int            dens;

    // -- Geometry positivity (CFG_P) ------------------------------------------
    if (CFG_P.ROW_BYTES_P          < 1 ||
        CFG_P.ADDR_WIDTH_P         < 1 ||
        CFG_P.N_RANKS_P            < 1 ||
        CFG_P.N_BANK_GROUPS_P      < 1 ||
        CFG_P.BANKS_PER_BG_P       < 1 ||
        CFG_P.ROW_BITS_P           < 1 ||
        CFG_P.COL_BITS_P           < 1 ||
        CFG_P.DEVICE_WIDTH_P       < 1 ||
        CFG_P.N_DEVICES_PER_RANK_P < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Invalid geometry in CFG_P: every field must be >= 1 (got ROW_BYTES_P=%0d ADDR_WIDTH_P=%0d N_RANKS_P=%0d N_BANK_GROUPS_P=%0d BANKS_PER_BG_P=%0d ROW_BITS_P=%0d COL_BITS_P=%0d DEVICE_WIDTH_P=%0d N_DEVICES_PER_RANK_P=%0d)",
        CFG_P.ROW_BYTES_P, CFG_P.ADDR_WIDTH_P, CFG_P.N_RANKS_P, CFG_P.N_BANK_GROUPS_P,
        CFG_P.BANKS_PER_BG_P, CFG_P.ROW_BITS_P, CFG_P.COL_BITS_P, CFG_P.DEVICE_WIDTH_P,
        CFG_P.N_DEVICES_PER_RANK_P))
    end

    // -- Channel width is a power of two --------------------------------------
    channel_bits = CFG_P.N_DEVICES_PER_RANK_P * CFG_P.DEVICE_WIDTH_P;
    if (!is_pow2(channel_bits)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Channel width N_DEVICES_PER_RANK_P*DEVICE_WIDTH_P = %0d*%0d = %0d is not a power of two",
        CFG_P.N_DEVICES_PER_RANK_P, CFG_P.DEVICE_WIDTH_P, channel_bits))
    end

    // -- Count-valued geometry fields must be powers of two -------------------
    // The decode (vip_dram_addr_pkg) derives the rank/bg/bank/byte field WIDTHS
    // with $clog2 of these counts. A non-power-of-two count reserves more codes
    // than there are entities, so the surplus encodings either alias address
    // space or index the per-rank bank-state array out of range
    // (vip_dram_bank_index -> this.bank[]). COL_BITS_P/ROW_BITS_P are already
    // bit-widths (not counts), so only the $clog2-encoded counts are checked.
    if (!is_pow2(CFG_P.ROW_BYTES_P)     ||
        !is_pow2(CFG_P.N_RANKS_P)       ||
        !is_pow2(CFG_P.N_BANK_GROUPS_P) ||
        !is_pow2(CFG_P.BANKS_PER_BG_P)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Geometry counts must be powers of two for the address decode (got ROW_BYTES_P=%0d N_RANKS_P=%0d N_BANK_GROUPS_P=%0d BANKS_PER_BG_P=%0d)",
        CFG_P.ROW_BYTES_P, CFG_P.N_RANKS_P, CFG_P.N_BANK_GROUPS_P, CFG_P.BANKS_PER_BG_P))
    end

    // -- Timing sanity --------------------------------------------------------
    if (this.timing.t_ck <= 0.0) begin
      `uvm_fatal(get_name(), $sformatf(
        "t_ck must be > 0 (got %0.4f ns)", this.timing.t_ck))
    end

    if (this.timing.tRC + TIMING_EPS_C < this.timing.tRAS + this.timing.tRP) begin
      `uvm_fatal(get_name(), $sformatf(
        "tRC (%0.3f ns) < tRAS + tRP (%0.3f + %0.3f = %0.3f ns)",
        this.timing.tRC, this.timing.tRAS, this.timing.tRP,
        this.timing.tRAS + this.timing.tRP))
    end

    // -- Geometry must exactly fill the declared address width ----------------
    // ADDR_WIDTH_P is an explicit interface parameter (the controller carries
    // the same address width), and it must equal the sum of the decode-field
    // widths so the byte address is fully partitioned — no unused high bits and
    // no truncated geometry. Width-0 fields (e.g. rank when N_RANKS_P == 1)
    // contribute nothing. This is what keeps the geometry and the declared
    // capacity from silently disagreeing (e.g. a 17-bit row field against a
    // 33-bit, 8 GiB device).
    byte_w    = $clog2(CFG_P.ROW_BYTES_P);
    col_w     = CFG_P.COL_BITS_P;
    bank_w    = $clog2(CFG_P.BANKS_PER_BG_P);
    bg_w      = $clog2(CFG_P.N_BANK_GROUPS_P);
    row_w     = CFG_P.ROW_BITS_P;
    rank_w    = $clog2(CFG_P.N_RANKS_P);
    addr_bits = byte_w + col_w + bank_w + bg_w + row_w + rank_w;

    if (addr_bits != CFG_P.ADDR_WIDTH_P) begin
      `uvm_fatal(get_name(), $sformatf(
        "Geometry decodes to %0d address bits (byte %0d + col %0d + bank %0d + bg %0d + row %0d + rank %0d) but CFG_P.ADDR_WIDTH_P = %0d; they must be equal",
        addr_bits, byte_w, col_w, bank_w, bg_w, row_w, rank_w, CFG_P.ADDR_WIDTH_P))
    end

    // -- tRFC density-table coverage (warning) --------------------------------
    // tRFC is derived from the per-die density; warn if that density is past the
    // largest tabulated entry for the generation (tRFC was clamped, so it is
    // approximate). IDEAL has no table (max 0) and is skipped.
    gen      = vip_dram_preset_gen(this.preset);
    max_gbit = vip_dram_trfc_max_gbit(gen);
    dens     = density_gbit();
    if (max_gbit > 0 && dens > max_gbit) begin
      `uvm_warning(get_name(), $sformatf(
        "Per-die density %0d Gbit exceeds the %s tRFC table max (%0d Gbit); tRFC clamped to %0.1f ns (approximate)",
        dens, gen.name(), max_gbit, this.timing.tRFC))
    end

    // -- Page policy coverage (warning) ---------------------------------------
    // Only OPEN page is implemented by the scheduler today; CLOSED/ADAPTIVE are
    // accepted as enum values but behave as OPEN (no auto-precharge). Warn so a
    // caller is not silently surprised.
    if (this.page_policy != VIP_DRAM_PAGE_OPEN_E) begin
      `uvm_warning(get_name(), $sformatf(
        "page_policy = %s is not yet modelled; the scheduler behaves as OPEN page",
        this.page_policy.name()))
    end
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  protected function bit is_pow2(int n);
    return (n > 0) && ((n & (n - 1)) == 0);
  endfunction

  // ---------------------------------------------------------------------------
  // Readable single-line summary of the key timing + policy knobs.
  // ---------------------------------------------------------------------------
  function string convert2string();
    return $sformatf(
      "preset=%s density=%0dGb t_ck=%0.3f tRCD=%0.2f tRP=%0.2f tCL=%0.2f tWL=%0.2f tRC=%0.2f tRFC=%0.1f tREFI=%0.1f page=%s bus_contention=%s",
      this.preset.name(), density_gbit(), this.timing.t_ck, this.timing.tRCD,
      this.timing.tRP, this.timing.tCL, this.timing.tWL, this.timing.tRC,
      this.timing.tRFC, this.timing.tREFI,
      this.page_policy.name(), (this.enable_bus_contention ? "TRUE" : "FALSE"));
  endfunction
endclass
