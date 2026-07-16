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
// vip_dram_timing_pkg
//
// DRAM timing parameters (nanoseconds), timing presets, and the ns->cycles
// helper. See vip_dram/IMPLEMENTATION_PLAN.md "Timing parameters & realistic
// defaults". Values are stored in ns; vip_dram_config converts to cycles at
// start_of_simulation_phase using t_ck. Only the DDR4-3200 preset is
// authoritative (matches the plan table); the other presets are reasonable
// first-pass values flagged TODO and should be refined against datasheets.
//
////////////////////////////////////////////////////////////////////////////////

`ifndef VIP_DRAM_TIMING_PKG
`define VIP_DRAM_TIMING_PKG

package vip_dram_timing_pkg;

  // ---------------------------------------------------------------------------
  // Timing presets. IDEAL collapses every delay to zero (sanity regression).
  // ---------------------------------------------------------------------------
  typedef enum {
    VIP_DRAM_PRESET_DDR4_3200_CL22_E,
    VIP_DRAM_PRESET_DDR4_2400_CL17_E,
    VIP_DRAM_PRESET_DDR3_1600_CL11_E,
    VIP_DRAM_PRESET_LPDDR4_3200_E,
    VIP_DRAM_PRESET_DDR5_4800_E,
    VIP_DRAM_PRESET_IDEAL_E
  } vip_dram_preset_t;

  // ---------------------------------------------------------------------------
  // DRAM generation. A preset selects the speed bin (frequency-driven AC
  // timings); the generation plus the per-die DENSITY (derived from the
  // geometry, NOT the bin) together pick tRFC via vip_dram_trfc_ns(). See the
  // plan's "Timing parameters & realistic defaults" (density / tRFC split).
  // ---------------------------------------------------------------------------
  typedef enum {
    VIP_DRAM_GEN_DDR3_E,
    VIP_DRAM_GEN_DDR4_E,
    VIP_DRAM_GEN_LPDDR4_E,
    VIP_DRAM_GEN_DDR5_E,
    VIP_DRAM_GEN_IDEAL_E
  } vip_dram_gen_t;

  // ---------------------------------------------------------------------------
  // Timing record (nanoseconds). Unpacked struct because it carries `real`
  // fields (reals are illegal in packed structs). Reference edges for each
  // parameter are documented in the plan's "Timing parameters" section.
  // tRC, tBL, tRTW are DERIVED (see vip_dram_get_preset).
  // ---------------------------------------------------------------------------
  typedef struct {
    real t_ck;     // DRAM clock period
    real tRCD;     // ACT -> RD/WR
    real tRP;      // row precharge          (ref: PRE command)
    real tRAS;     // row active min         (ref: ACT command)
    real tRC;      // = tRAS + tRP           (derived)
    real tCL;      // CAS read latency
    real tWL;      // write latency (CWL)
    real tWR;      // write recovery         (ref: last WR data)
    real tRTP;     // RD -> PRE              (ref: RD command)
    real tCCD_S;   // col-col, diff bankgrp  (ref: prior CAS command)
    real tCCD_L;   // col-col, same bankgrp  (ref: prior CAS command)
    real tRRD_S;   // ACT-ACT, diff bankgrp  (ref: ACT command)
    real tRRD_L;   // ACT-ACT, same bankgrp  (ref: ACT command)
    real tFAW;     // four-activate window (rank)
    real tWTR_S;   // WR -> RD, diff bankgrp (ref: last WR data)
    real tWTR_L;   // WR -> RD, same bankgrp (ref: last WR data)
    real tRTW;     // RD -> WR turnaround    (derived, controller-derived)
    real tRFC;     // refresh cycle (blocks rank)
    real tBL;      // burst length on bus    (derived = bl_clocks * t_ck)
    real tREFI;    // average refresh interval (read-only for vip_mc)
  } vip_dram_timing_t;

  // ---------------------------------------------------------------------------
  // Round a nanosecond value up to whole DRAM clock cycles. Guards a
  // non-positive t_ck (returns 0) so IDEAL / mis-configured presets cannot
  // divide by zero.
  // ---------------------------------------------------------------------------
  function automatic int vip_dram_ns_to_cycles(real ns, real t_ck);
    if (t_ck <= 0.0) begin
      return 0;
    end
    return int'($ceil(ns / t_ck));
  endfunction

  // ---------------------------------------------------------------------------
  // Controller-derived read-to-write bus turnaround (JEDEC does not specify
  // tRTW as a device timing). Evaluated per preset so DDR5/LPDDR get a correct
  // value rather than a hard-coded number.
  //   tRTW = tCL + tBL + 2*t_ck - tWL
  // ---------------------------------------------------------------------------
  function automatic real vip_dram_derive_trtw(real tCL, real tBL, real t_ck, real tWL);
    return tCL + tBL + 2.0 * t_ck - tWL;
  endfunction

  // ---------------------------------------------------------------------------
  // Populate a full timing record for a preset. The DDR4-3200 CL22 row is
  // authoritative and matches the plan table exactly. Other presets are
  // first-pass approximations (TODO: refine against JEDEC datasheets).
  // ---------------------------------------------------------------------------
  function automatic vip_dram_timing_t vip_dram_get_preset(
    input vip_dram_preset_t preset
  );

    vip_dram_timing_t t;
    int               bl_clocks;   // burst length expressed in DRAM clocks (BL8 -> 4, BL16 -> 8)

    // IDEAL is special-cased to all-zero delays (t_ck kept non-zero only so
    // ns->cycles stays well-defined). Tests using IDEAL disable refresh.
    if (preset == VIP_DRAM_PRESET_IDEAL_E) begin
      t       = '{default: 0.0};
      t.t_ck  = 0.625;
      t.tREFI = 7800.0;
      return t;
    end

    case (preset)

      // -- Authoritative: matches IMPLEMENTATION_PLAN.md timing table --------
      VIP_DRAM_PRESET_DDR4_3200_CL22_E: begin
        t.t_ck  = 0.625;
        t.tRCD  = 13.75;  t.tRP   = 13.75;  t.tRAS = 32.0;
        t.tCL   = 13.75;  t.tWL   = 10.0;   t.tWR  = 15.0;   t.tRTP = 7.5;
        t.tCCD_S = 2.5;   t.tCCD_L = 5.0;
        t.tRRD_S = 3.0;   t.tRRD_L = 4.9;   t.tFAW = 21.0;
        t.tWTR_S = 2.5;   t.tWTR_L = 7.5;
        t.tRFC  = 350.0;  t.tREFI = 7800.0;            // 8 Gb device
        bl_clocks = 4;                                  // BL8
      end

      // -- TODO: refine the presets below against datasheets -----------------
      VIP_DRAM_PRESET_DDR4_2400_CL17_E: begin
        t.t_ck  = 0.8333;
        t.tRCD  = 14.16;  t.tRP   = 14.16;  t.tRAS = 32.0;
        t.tCL   = 14.16;  t.tWL   = 10.0;   t.tWR  = 15.0;   t.tRTP = 7.5;
        t.tCCD_S = 3.33;  t.tCCD_L = 5.0;
        t.tRRD_S = 3.3;   t.tRRD_L = 4.9;   t.tFAW = 21.0;
        t.tWTR_S = 2.5;   t.tWTR_L = 7.5;
        t.tRFC  = 350.0;  t.tREFI = 7800.0;
        bl_clocks = 4;
      end

      VIP_DRAM_PRESET_DDR3_1600_CL11_E: begin
        // DDR3 has NO bank groups -> the _S and _L variants are equal.
        t.t_ck  = 1.25;
        t.tRCD  = 13.75;  t.tRP   = 13.75;  t.tRAS = 35.0;
        t.tCL   = 13.75;  t.tWL   = 8.75;   t.tWR  = 15.0;   t.tRTP = 7.5;
        t.tCCD_S = 5.0;   t.tCCD_L = 5.0;
        t.tRRD_S = 6.0;   t.tRRD_L = 6.0;   t.tFAW = 30.0;
        t.tWTR_S = 7.5;   t.tWTR_L = 7.5;
        t.tRFC  = 260.0;  t.tREFI = 7800.0;
        bl_clocks = 4;
      end

      VIP_DRAM_PRESET_LPDDR4_3200_E: begin
        t.t_ck  = 0.625;
        t.tRCD  = 18.0;   t.tRP   = 18.0;   t.tRAS = 42.0;
        t.tCL   = 18.0;   t.tWL   = 10.0;   t.tWR  = 18.0;   t.tRTP = 7.5;
        t.tCCD_S = 5.0;   t.tCCD_L = 5.0;
        t.tRRD_S = 10.0;  t.tRRD_L = 10.0;  t.tFAW = 40.0;
        t.tWTR_S = 10.0;  t.tWTR_L = 10.0;
        t.tRFC  = 180.0;  t.tREFI = 3904.0;
        bl_clocks = 4;
      end

      VIP_DRAM_PRESET_DDR5_4800_E: begin
        // NOTE: DDR5 is BL16; the neutral "one column access = BL8" mapping
        // (plan "Beat granularity") must be revisited before this preset is
        // used for real timing checks.
        t.t_ck  = 0.4167;
        t.tRCD  = 16.0;   t.tRP   = 16.0;   t.tRAS = 32.0;
        t.tCL   = 16.67;  t.tWL   = 13.33;  t.tWR  = 30.0;   t.tRTP = 7.5;
        t.tCCD_S = 2.0;   t.tCCD_L = 3.33;
        t.tRRD_S = 2.0;   t.tRRD_L = 4.0;   t.tFAW = 13.33;
        t.tWTR_S = 2.5;   t.tWTR_L = 10.0;
        t.tRFC  = 295.0;  t.tREFI = 3900.0;
        bl_clocks = 8;
      end

      default: begin
        t         = '{default: 0.0};
        t.t_ck    = 0.625;
        bl_clocks = 4;
      end
    endcase

    // Derived fields, common to all non-IDEAL presets.
    t.tBL  = bl_clocks * t.t_ck;
    t.tRC  = t.tRAS + t.tRP;
    t.tRTW = vip_dram_derive_trtw(t.tCL, t.tBL, t.t_ck, t.tWL);

    // NOTE: the t.tRFC set above is only the preset's REFERENCE-density value.
    // vip_dram_config::apply_preset() re-derives the authoritative tRFC from the
    // actual per-die density (geometry) via vip_dram_trfc_ns() below, so a
    // re-sized device gets the correct refresh time automatically.
    return t;
  endfunction

  // ---------------------------------------------------------------------------
  // Map a speed-bin preset to its DRAM generation (used to index the tRFC
  // table). IDEAL maps to IDEAL so tRFC stays zero.
  // ---------------------------------------------------------------------------
  function automatic vip_dram_gen_t vip_dram_preset_gen(
    input vip_dram_preset_t preset
  );
    case (preset)
      VIP_DRAM_PRESET_DDR4_3200_CL22_E,
      VIP_DRAM_PRESET_DDR4_2400_CL17_E: return VIP_DRAM_GEN_DDR4_E;
      VIP_DRAM_PRESET_DDR3_1600_CL11_E: return VIP_DRAM_GEN_DDR3_E;
      VIP_DRAM_PRESET_LPDDR4_3200_E:    return VIP_DRAM_GEN_LPDDR4_E;
      VIP_DRAM_PRESET_DDR5_4800_E:      return VIP_DRAM_GEN_DDR5_E;
      default:                          return VIP_DRAM_GEN_IDEAL_E;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Density-driven refresh cycle time (tRFC1, ns). tRFC scales with the per-die
  // DENSITY, not the speed bin — so it is a function of (generation, density),
  // looked up here and applied by vip_dram_config from the geometry-derived
  // density. Off-table densities clamp to the nearest-larger entry (conservative
  // = longer refresh); vip_dram_config warns when it clamps.
  //
  // DDR4 values are the authoritative JEDEC tRFC1 figures; DDR3/DDR5/LPDDR4 are
  // first-pass and flagged TODO with the rest of those presets.
  // ---------------------------------------------------------------------------
  function automatic real vip_dram_trfc_ns(
    input vip_dram_gen_t gen,
    input int            density_gbit
  );
    case (gen)
      VIP_DRAM_GEN_DDR4_E: begin           // authoritative
        if (density_gbit <= 2) return 160.0;
        if (density_gbit <= 4) return 260.0;
        if (density_gbit <= 8) return 350.0;
        return 550.0;                       // 16 Gb+
      end
      VIP_DRAM_GEN_DDR3_E: begin            // JESD79-3 tRFC
        if (density_gbit <= 1) return 110.0;  // 512 Mb also 90 ns; 1 Gb = 110
        if (density_gbit <= 2) return 160.0;
        if (density_gbit <= 4) return 260.0;
        return 350.0;                       // 8 Gb
      end
      VIP_DRAM_GEN_DDR5_E: begin            // TODO: refine (tRFC1)
        if (density_gbit <= 8)  return 195.0;
        if (density_gbit <= 16) return 295.0;
        return 410.0;                       // 24/32 Gb
      end
      VIP_DRAM_GEN_LPDDR4_E: begin          // TODO: refine (tRFCab)
        if (density_gbit <= 4) return 130.0;
        if (density_gbit <= 8) return 180.0;
        return 280.0;                       // 12/16 Gb
      end
      default: return 0.0;                  // IDEAL
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Largest density (Gbit) the tRFC table above tabulates for a generation.
  // vip_dram_config warns when the configured density exceeds this (tRFC was
  // clamped, so the refresh time is approximate). 0 for IDEAL.
  // ---------------------------------------------------------------------------
  function automatic int vip_dram_trfc_max_gbit(
    input vip_dram_gen_t gen
  );
    case (gen)
      VIP_DRAM_GEN_DDR4_E:   return 16;
      VIP_DRAM_GEN_DDR3_E:   return 8;
      VIP_DRAM_GEN_DDR5_E:   return 16;
      VIP_DRAM_GEN_LPDDR4_E: return 16;
      default:               return 0;
    endcase
  endfunction

endpackage

`endif
