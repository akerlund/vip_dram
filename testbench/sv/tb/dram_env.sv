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
// dram_env
//
// The device-only verification environment (§12.1): the vip_dram device under
// test, a tiny dram_driver, and a dram_scoreboard, wired over the neutral TLM
// contract —
//
//   driver.req_ap ──▶ dram.req_fifo.analysis_export      (requests in)
//   dram.rsp_port ──▶ scoreboard.rsp_imp                 (responses out)
//
// No DUT RTL, no clock, no bus. A test reaches `dram` (predict/backdoor/reset/
// counters), `drv` (issue/send), and `sb` (expect/wait/fetch). No copyright
// header (house style); parameterized by the device CFG_P.
//
////////////////////////////////////////////////////////////////////////////////

class dram_env #(
  vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_env;

  vip_dram        #(CFG_P) dram;
  dram_driver     #(CFG_P) drv;
  dram_scoreboard #(CFG_P) sb;

  `uvm_component_param_utils(dram_env #(CFG_P))

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    this.dram = vip_dram        #(CFG_P)::type_id::create("dram", this);
    this.drv  = dram_driver     #(CFG_P)::type_id::create("drv",  this);
    this.sb   = dram_scoreboard #(CFG_P)::type_id::create("sb",   this);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    this.drv.req_ap.connect(this.dram.req_fifo.analysis_export);
    this.dram.rsp_port.connect(this.sb.rsp_imp);
    this.drv.dram = this.dram;
    this.drv.sb   = this.sb;
    this.sb.tol   = this.dram.cfg.timing.t_ck;   // 1-cycle tolerance
  endfunction

endclass
