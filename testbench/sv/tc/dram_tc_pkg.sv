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
// dram_tc_pkg
//
// Test-case package for the vip_dram device-only example (§12.3). Imports the
// TB package and the device VIP, then `include`s the base test and every test
// case. A test is selected with +UVM_TESTNAME=<tc_name>.
//
////////////////////////////////////////////////////////////////////////////////

`ifndef DRAM_TC_PKG
`define DRAM_TC_PKG

package dram_tc_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  import dram_tb_pkg::*;

  import report_server_pkg::*;
  import vip_mem_types_pkg::*;
  import vip_memory_pkg::*;
  import vip_dram_types_pkg::*;
  import vip_dram_timing_pkg::*;
  import vip_dram_addr_pkg::*;
  import vip_dram_pkg::*;

  `include "dram_base_test.sv"
  `include "tc_dram_backdoor_preload.sv"
  `include "tc_dram_bank_parallel.sv"
  `include "tc_dram_faw_stress.sv"
  `include "tc_dram_ideal_zero_latency.sv"
  `include "tc_dram_page_hit_streak.sv"
  `include "tc_dram_page_thrash.sv"
  `include "tc_dram_partial_write.sv"
  `include "tc_dram_predict_matches_schedule.sv"
  `include "tc_dram_preset_sweep.sv"
  `include "tc_dram_read_fault.sv"
  `include "tc_dram_refresh_explicit.sv"
  `include "tc_dram_reset_recovery.sv"
  `include "tc_dram_smoke.sv"
  `include "tc_dram_wr_rd_turnaround.sv"
  `include "tc_dram_writes_then_reads.sv"
endpackage

`endif
