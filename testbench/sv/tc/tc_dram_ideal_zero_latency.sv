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
// tc_dram_ideal_zero_latency (§12.3 #12)
//
// The IDEAL preset collapses every timing parameter to zero, so a read's data
// is ready at its arrival time — first == last == arrival. A sanity regression
// that the zero-delay path behaves and the response still carries the data.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_ideal_zero_latency extends dram_base_test;

  `uvm_component_utils(tc_dram_ideal_zero_latency)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_ideal_zero_latency",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    addr_t addr;
    data_t seeded_data;
    req_t  rd_req;
    rsp_t  rd_rsp;

    // IDEAL zeroes every delay (t_ck stays non-zero only so ns->cycles is well
    // defined). Apply it, then clear state so the read sees a fresh device.
    super.env.dram.cfg.apply_preset(
      .preset ( VIP_DRAM_PRESET_IDEAL_E )
    );
    super.env.dram.cfg.validate();
    super.env.dram.reset();

    addr = super.addr_of(
      .rank ( 0 ),
      .bg   ( 0 ),
      .bank ( 0 ),
      .row  ( 0 ),
      .col  ( 0 )
    );
    seeded_data = super.pattern(
      .seed ( 'hD0 )
    );

    // Seed via backdoor so the read returns known data at zero latency.
    super.env.dram.backdoor_write(
      .addr ( addr        ),
      .data ( seeded_data )
    );

    rd_req = super.mk_rd_req(
      .addr  ( addr   ),
      .beats ( 1     ),
      .tag   ( 'hC00 )
    );
    super.send_checked(
      .req ( rd_req )
    );
    rd_rsp = super.env.sb.get_rsp(
      .tag ( 'hC00 )
    );

    // With every delay zero the data is ready the instant the request arrives:
    // both first and last beat ready times equal the device's arrival stamp.
    super.chk_time(
      .nm  ( "ideal first == arrival"  ),
      .got ( rd_rsp.first_beat_ready_time ),
      .exp ( rd_req.arrival_time          )
    );
    super.chk_time(
      .nm  ( "ideal last == arrival"   ),
      .got ( rd_rsp.last_beat_ready_time ),
      .exp ( rd_req.arrival_time         )
    );
    if (rd_rsp.rdata[0] !== seeded_data) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] ideal read %0h != seeded %0h",
      super.tc_name, rd_rsp.rdata[0], seeded_data))
    end
  endtask

endclass
