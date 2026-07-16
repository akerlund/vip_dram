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
// dram_tb_pkg
//
// Testbench package for the vip_dram device-only example (§12). Holds the shared
// device geometry (CFG_P) the whole TB is parameterized by, and `include`s the
// harness classes (scoreboard, driver, env). No bus, no DUT RTL — purely the
// neutral TLM contract.
//
////////////////////////////////////////////////////////////////////////////////

`ifndef DRAM_TB_PKG
`define DRAM_TB_PKG

package dram_tb_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  import vip_mem_types_pkg::*;
  import vip_memory_pkg::*;
  import vip_dram_types_pkg::*;
  import vip_dram_timing_pkg::*;
  import vip_dram_addr_pkg::*;
  import vip_dram_pkg::*;

  // Device under test geometry: the default DDR4 x8, 8 Gb, 64-bit, 8 GiB part.
  localparam vip_dram_cfg_t DRAM_CFG_C = VIP_DRAM_CFG_DEFAULT_C;

  `include "dram_scoreboard.sv"
  `include "dram_driver.sv"
  `include "dram_env.sv"

endpackage

`endif
