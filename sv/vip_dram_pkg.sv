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
// vip_dram_pkg
//
// Umbrella package for the vip_dram VIP. Imports the standalone type/function
// packages (vip_dram_types_pkg / vip_dram_timing_pkg / vip_dram_addr_pkg) and
// the dependencies (UVM, bool_pkg, the vip_memory VIP), then `include`s the
// parameterized UVM class items.
//
// The `include-a-.sv-file idiom is used ONLY for the parameterized class items
// below — they share this single compilation unit so they can cross-reference
// each other's #(CFG_P) types without inter-package ordering pain. Free
// functions are NOT included here; they live in their own packages
// (vip_dram_addr_pkg, vip_dram_timing_pkg).
//
////////////////////////////////////////////////////////////////////////////////

`ifndef VIP_DRAM_PKG
`define VIP_DRAM_PKG

package vip_dram_pkg;

  // The device timing model is expressed in absolute NANOSECONDS (realtime):
  // vip_dram.sv issues `#(s.last - $realtime)` delays and the scheduler reads
  // `$realtime`, both of which are scaled by THIS package's time unit. Pin it so
  // the ns-valued delays are scale-correct regardless of the surrounding compile
  // unit's `-timescale`, and pin precision to 1 ps so sub-ns presets (t_ck =
  // 0.625 ns, tCCD_S = 2.5 ns, tRCD = 13.75 ns, …) are not rounded away.
  timeunit      1ns;
  timeprecision 1ps;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  import vip_mem_types_pkg::*;
  import vip_memory_pkg::*;          // vip_mem + vip_mem_config

  import vip_dram_types_pkg::*;
  import vip_dram_timing_pkg::*;
  import vip_dram_addr_pkg::*;

  `include "vip_dram_req.sv"
  `include "vip_dram_rsp.sv"
  `include "vip_dram_config.sv"
  `include "vip_dram_bank_state.sv"
  `include "vip_dram_scheduler.sv"
  `include "vip_dram.sv"

endpackage

`endif
