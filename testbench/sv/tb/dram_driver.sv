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
// dram_driver
//
// Tiny TLM driver for the device-only contract tests. It owns the analysis port
// wired into vip_dram.req_fifo and offers two ways to push a request:
//
//   - send(req)   : fire-and-forget (used by back-to-back tests that assert on
//                   the relationships between collected responses).
//   - issue(req)  : the §12.2 checked path — at issue time it asks the device's
//                   predict() for the expected first/last beat times, registers
//                   them with the scoreboard (keyed by req.tag), then sends.
//                   Valid only with a single outstanding request, because
//                   predict() reads $realtime + the current committed state
//                   (see vip_dram predict() caveat): a test must let the prior
//                   response retire before issue()-ing the next.
//
// Handles to the device and scoreboard are wired by the env in connect_phase.
// Parameterized by the device CFG_P.
//
////////////////////////////////////////////////////////////////////////////////

class dram_driver #(
  vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_component;

  typedef vip_dram_req #(CFG_P) req_t;

  uvm_analysis_port #(req_t) req_ap;

  // Wired by the env (connect_phase).
  vip_dram        #(CFG_P) dram;
  dram_scoreboard #(CFG_P) sb;

  `uvm_component_param_utils(dram_driver #(CFG_P))

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name,
    input uvm_component parent
  );
    super.new(name, parent);
    this.req_ap = new("req_ap", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Fire-and-forget send (no expectation registered).
  // ---------------------------------------------------------------------------
  function void send(
    input req_t req
  );
    this.req_ap.write(req);
  endfunction

  // ---------------------------------------------------------------------------
  // Checked send: predict the timing now (single-outstanding only), register it
  // with the scoreboard, then push the request.
  // ---------------------------------------------------------------------------
  function void issue(
    input req_t req
  );
    realtime first;
    realtime last;

    this.dram.predict(
      .req              ( req   ),
      .first_beat_ready ( first ),
      .last_beat_ready  ( last  )
    );
    this.sb.expect_timed(
      .tag   ( req.tag ),
      .first ( first   ),
      .last  ( last    )
    );
    this.req_ap.write(req);
  endfunction

endclass
