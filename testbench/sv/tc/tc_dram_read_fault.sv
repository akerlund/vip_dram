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
// tc_dram_read_fault (§11 item 5)
//
// Exercise the device read-fault model directly in the device-only env (vip_mc's
// ECC test only reaches it transitively). Seed three rows via the backdoor, mark
// one CORRECTABLE and one UNCORRECTABLE with inject_fault(), then frontdoor-read
// all three and assert on the response:
//   - clean row     : injected_fault NONE, zero corrupt_mask, rdata == seeded.
//   - correctable   : injected_fault CORRECTABLE, one-bit corrupt_mask, rdata
//                     physically flipped, and rdata ^ corrupt_mask == seeded
//                     (the SECDED-repairable syndrome restores the original).
//   - uncorrectable : injected_fault UNCORRECTABLE, zero corrupt_mask, rdata
//                     flipped in exactly two bits (a double-bit DUE).
// Also assert get_fault() reflects the injections, the backing store is NOT
// mutated (backdoor_read still returns the seeds), and clear_all_faults() makes a
// re-read come back clean.
//
////////////////////////////////////////////////////////////////////////////////

class tc_dram_read_fault extends dram_base_test;

  `uvm_component_utils(tc_dram_read_fault)

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  function new(
    input string        name   = "tc_dram_read_fault",
    input uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Read the row at `addr` through the frontdoor and return the response.
  // ---------------------------------------------------------------------------
  task read_row(input addr_t addr, input longint unsigned tag, output rsp_t rsp);
    req_t rd_req = super.mk_rd_req(.addr(addr), .beats(1), .tag(tag));
    super.send_checked(.req(rd_req));
    rsp = super.env.sb.get_rsp(.tag(tag));
  endtask

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  task body();

    addr_t addr_clean;
    addr_t addr_corr;
    addr_t addr_unc;
    data_t seed_clean;
    data_t seed_corr;
    data_t seed_unc;
    rsp_t  rsp;

    addr_clean = super.addr_of(.rank(0), .bg(0), .bank(0), .row(0), .col(0));
    addr_corr  = super.addr_of(.rank(0), .bg(1), .bank(2), .row(7), .col(0));
    addr_unc   = super.addr_of(.rank(0), .bg(2), .bank(1), .row(9), .col(0));
    seed_clean = super.pattern(.seed('hC0));
    seed_corr  = super.pattern(.seed('hC1));
    seed_unc   = super.pattern(.seed('hC2));

    // Seed the three rows (no timing) and mark two of them faulted.
    super.env.dram.backdoor_write(.addr(addr_clean), .data(seed_clean));
    super.env.dram.backdoor_write(.addr(addr_corr),  .data(seed_corr));
    super.env.dram.backdoor_write(.addr(addr_unc),   .data(seed_unc));
    super.env.dram.inject_fault(.addr(addr_corr), .fault(VIP_DRAM_FAULT_CORRECTABLE_E));
    super.env.dram.inject_fault(.addr(addr_unc),  .fault(VIP_DRAM_FAULT_UNCORRECTABLE_E));

    // get_fault() mirrors the injections.
    if (super.env.dram.get_fault(.addr(addr_clean)) != VIP_DRAM_FAULT_NONE_E) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] get_fault(clean) != NONE", super.tc_name))
    end
    if (super.env.dram.get_fault(.addr(addr_corr)) != VIP_DRAM_FAULT_CORRECTABLE_E) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] get_fault(corr) != CORRECTABLE", super.tc_name))
    end
    if (super.env.dram.get_fault(.addr(addr_unc)) != VIP_DRAM_FAULT_UNCORRECTABLE_E) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] get_fault(unc) != UNCORRECTABLE", super.tc_name))
    end

    // --- Clean read ---------------------------------------------------------
    this.read_row(.addr(addr_clean), .tag('h900), .rsp(rsp));
    if (rsp.injected_fault != VIP_DRAM_FAULT_NONE_E) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] clean read fault = %s (expected NONE)",
      super.tc_name, rsp.injected_fault.name()))
    end
    if (rsp.rdata[0] !== seed_clean) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] clean rdata %0h != seeded %0h", super.tc_name, rsp.rdata[0], seed_clean))
    end
    if (rsp.corrupt_mask[0] !== '0) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] clean corrupt_mask %0h != 0", super.tc_name, rsp.corrupt_mask[0]))
    end

    // --- Correctable read ---------------------------------------------------
    this.read_row(.addr(addr_corr), .tag('h901), .rsp(rsp));
    if (rsp.injected_fault != VIP_DRAM_FAULT_CORRECTABLE_E) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] corr read fault = %s (expected CORRECTABLE)",
      super.tc_name, rsp.injected_fault.name()))
    end
    if ($countones(rsp.corrupt_mask[0]) != 1) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] corr corrupt_mask has %0d bits set (expected 1)",
      super.tc_name, $countones(rsp.corrupt_mask[0])))
    end
    if (rsp.rdata[0] === seed_corr) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] corr rdata not physically corrupted", super.tc_name))
    end
    if ((rsp.rdata[0] ^ rsp.corrupt_mask[0]) !== seed_corr) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] corr repair (rdata ^ mask) %0h != seeded %0h",
      super.tc_name, rsp.rdata[0] ^ rsp.corrupt_mask[0], seed_corr))
    end

    // --- Uncorrectable read -------------------------------------------------
    this.read_row(.addr(addr_unc), .tag('h902), .rsp(rsp));
    if (rsp.injected_fault != VIP_DRAM_FAULT_UNCORRECTABLE_E) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] unc read fault = %s (expected UNCORRECTABLE)",
      super.tc_name, rsp.injected_fault.name()))
    end
    if (rsp.corrupt_mask[0] !== '0) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] unc corrupt_mask %0h != 0 (double-bit is unrepairable)",
      super.tc_name, rsp.corrupt_mask[0]))
    end
    if ($countones(rsp.rdata[0] ^ seed_unc) != 2) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] unc rdata differs from seed in %0d bits (expected 2)",
      super.tc_name, $countones(rsp.rdata[0] ^ seed_unc)))
    end

    // --- Backing store is untouched (corruption is response-only) -----------
    if (super.env.dram.backdoor_read(.addr(addr_corr)) !== seed_corr) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] store at corr row mutated by faulted read", super.tc_name))
    end
    if (super.env.dram.backdoor_read(.addr(addr_unc)) !== seed_unc) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] store at unc row mutated by faulted read", super.tc_name))
    end

    // --- Clearing faults makes the row read clean again ---------------------
    super.env.dram.clear_all_faults();
    this.read_row(.addr(addr_corr), .tag('h903), .rsp(rsp));
    if (rsp.injected_fault != VIP_DRAM_FAULT_NONE_E) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] corr read after clear_all_faults fault = %s (expected NONE)",
      super.tc_name, rsp.injected_fault.name()))
    end
    if (rsp.rdata[0] !== seed_corr) begin
      `uvm_error(get_name(), $sformatf(
      "ERROR [%s] corr rdata after clear %0h != seeded %0h",
      super.tc_name, rsp.rdata[0], seed_corr))
    end
  endtask

endclass
