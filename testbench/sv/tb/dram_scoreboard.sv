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
// dram_scoreboard
//
// Predictor-vs-observed checker for the vip_dram device-only contract tests
// (§12.2). It subscribes to the device's rsp_port and, for any response whose
// tag has a registered expectation, compares:
//   - the timing (first/last beat ready) within a 1-cycle (t_ck) tolerance, and
//   - the page classification (hit/miss/empty),
// raising a uvm_error on a mismatch. Responses are also stored by tag so a test
// can fetch one and assert on it directly (the relational checks — spacing
// between bursts, FAW deferral — that an absolute predict cannot express).
//
// Expectations are registered by the driver (timing, from vip_dram.predict())
// and/or by the test (page class, which the scenario knows). No copyright
// header (house style); parameterized by the device CFG_P.
//
////////////////////////////////////////////////////////////////////////////////

class dram_scoreboard #(
  vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_component;

  typedef vip_dram_rsp #(CFG_P) rsp_t;

  uvm_analysis_imp #(rsp_t, dram_scoreboard #(CFG_P)) rsp_imp;

  // Per-tag expectation. check_time/check_page gate which fields are compared.
  typedef struct {
    realtime first;
    realtime last;
    bit      check_time;
    bit      hit;
    bit      miss;
    bit      empty;
    bit      check_page;
  } expect_t;

  protected expect_t exp [longint unsigned];
  protected rsp_t    got [longint unsigned];

  // 1-cycle timing tolerance (set from cfg.t_ck by the env).
  realtime tol = 0.0;

  // Observed-response count (tests wait on it) and check tallies.
  int n_recv;
  int n_time_ok, n_time_bad, n_page_ok, n_page_bad;

  `uvm_component_param_utils(dram_scoreboard #(CFG_P))

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(string name, uvm_component parent);
    super.new(name, parent);
    this.rsp_imp = new("rsp_imp", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Register expected first/last beat times for a tag (from predict()).
  // ---------------------------------------------------------------------------
  function void expect_timed(longint unsigned tag, realtime first, realtime last);
    this.exp[tag].first      = first;
    this.exp[tag].last       = last;
    this.exp[tag].check_time = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Register expected page classification for a tag (the scenario knows it).
  // ---------------------------------------------------------------------------
  function void expect_page(longint unsigned tag, bit hit, bit miss, bit empty);
    this.exp[tag].hit        = hit;
    this.exp[tag].miss       = miss;
    this.exp[tag].empty      = empty;
    this.exp[tag].check_page = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Analysis write: store + compare against any registered expectation.
  // ---------------------------------------------------------------------------
  function void write(rsp_t rsp);
    this.got[rsp.tag] = rsp;
    this.n_recv++;

    if (this.exp.exists(rsp.tag)) begin
      expect_t e = this.exp[rsp.tag];

      if (e.check_time) begin
        if (this.approx(rsp.first_beat_ready_time, e.first) &&
            this.approx(rsp.last_beat_ready_time,  e.last)) begin
          this.n_time_ok++;
        end
        else begin
          this.n_time_bad++;
          `uvm_error(get_name(), $sformatf(
          "ERROR [%s] tag %0h TIMING: got first=%0.3f last=%0.3f, expected first=%0.3f last=%0.3f (tol=%0.3f)",
          get_name(), rsp.tag, rsp.first_beat_ready_time, rsp.last_beat_ready_time, e.first, e.last, this.tol))
        end
      end

      if (e.check_page) begin
        if (rsp.was_page_hit == e.hit && rsp.was_page_miss == e.miss &&
            rsp.was_page_empty == e.empty) begin
          this.n_page_ok++;
        end
        else begin
          this.n_page_bad++;
          `uvm_error(get_name(), $sformatf(
          "ERROR [%s] tag %0h PAGE: got hit/miss/empty=%0b/%0b/%0b, expected %0b/%0b/%0b",
          get_name(), rsp.tag, rsp.was_page_hit, rsp.was_page_miss, rsp.was_page_empty,
          e.hit, e.miss, e.empty))
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Fetch a stored response by tag (null if not yet received).
  // ---------------------------------------------------------------------------
  function rsp_t get_rsp(longint unsigned tag);
    if (this.got.exists(tag)) return this.got[tag];
    return null;
  endfunction

  // ---------------------------------------------------------------------------
  // Block until at least `n` responses have been observed.
  // ---------------------------------------------------------------------------
  task wait_for(int n);
    wait (this.n_recv >= n);
  endtask

  // ---------------------------------------------------------------------------
  // |a - b| <= tol (realtime).
  // ---------------------------------------------------------------------------
  protected function bit approx(realtime a, realtime b);
    realtime d = (a > b) ? (a - b) : (b - a);
    return (d <= this.tol);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function void report_phase(uvm_phase phase);
    `uvm_info(get_name(), $sformatf(
    "INFO [%s] responses=%0d  timing ok/bad=%0d/%0d  page ok/bad=%0d/%0d",
    get_name(), this.n_recv, this.n_time_ok, this.n_time_bad, this.n_page_ok, this.n_page_bad),
    UVM_LOW)
  endfunction

endclass
