################################################################################
##
## Copyright (C) 2026 Fredrik Åkerlund
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.
##
## Description:
## tc_dram_read_fault (SV §11 item 5)
##
## pyUVM port of testbench/sv/tc/tc_dram_read_fault.sv.
##
## Exercise the device read-fault model directly. Seed three rows via the
## backdoor, mark one CORRECTABLE and one UNCORRECTABLE, then frontdoor-read all
## three and assert on the response (severity, corrupt_mask population, physical
## corruption, SECDED repairability). Also assert get_fault() reflects the
## injections, the backing store is NOT mutated, and clear_all_faults() cleans up.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import VipDramFault
from dram_base_test import dram_base_test


class tc_dram_read_fault(dram_base_test):

  # ---------------------------------------------------------------------------
  # Read the row at `addr` through the frontdoor and return the response.
  # ---------------------------------------------------------------------------
  async def read_row(self, addr, tag):
    rd_req = self.mk_rd_req(addr, 1, tag)
    await self.send_checked(rd_req)
    return self.env.sb.get_rsp(tag)

  async def body(self):
    addr_clean = self.addr_of(rank=0, bg=0, bank=0, row=0, col=0)
    addr_corr = self.addr_of(rank=0, bg=1, bank=2, row=7, col=0)
    addr_unc = self.addr_of(rank=0, bg=2, bank=1, row=9, col=0)
    seed_clean = self.pattern(0xC0)
    seed_corr = self.pattern(0xC1)
    seed_unc = self.pattern(0xC2)

    # Seed the three rows (no timing) and mark two of them faulted.
    self.env.dram.backdoor_write(addr_clean, seed_clean)
    self.env.dram.backdoor_write(addr_corr, seed_corr)
    self.env.dram.backdoor_write(addr_unc, seed_unc)
    self.env.dram.inject_fault(addr_corr, VipDramFault.CORRECTABLE)
    self.env.dram.inject_fault(addr_unc, VipDramFault.UNCORRECTABLE)

    # get_fault() mirrors the injections.
    if self.env.dram.get_fault(addr_clean) != VipDramFault.NONE:
      self.logger.error(f"ERROR [{self.tc_name}] get_fault(clean) != NONE")
    if self.env.dram.get_fault(addr_corr) != VipDramFault.CORRECTABLE:
      self.logger.error(f"ERROR [{self.tc_name}] get_fault(corr) != CORRECTABLE")
    if self.env.dram.get_fault(addr_unc) != VipDramFault.UNCORRECTABLE:
      self.logger.error(f"ERROR [{self.tc_name}] get_fault(unc) != UNCORRECTABLE")

    # --- Clean read ---------------------------------------------------------
    rsp = await self.read_row(addr_clean, 0x900)
    if rsp.injected_fault != VipDramFault.NONE:
      self.logger.error(
        f"ERROR [{self.tc_name}] clean read fault = {rsp.injected_fault.name} "
        f"(expected NONE)")
    if rsp.rdata[0] != seed_clean:
      self.logger.error(
        f"ERROR [{self.tc_name}] clean rdata {rsp.rdata[0]:x} != seeded "
        f"{seed_clean:x}")
    if rsp.corrupt_mask[0] != 0:
      self.logger.error(
        f"ERROR [{self.tc_name}] clean corrupt_mask {rsp.corrupt_mask[0]:x} != 0")

    # --- Correctable read ---------------------------------------------------
    rsp = await self.read_row(addr_corr, 0x901)
    if rsp.injected_fault != VipDramFault.CORRECTABLE:
      self.logger.error(
        f"ERROR [{self.tc_name}] corr read fault = {rsp.injected_fault.name} "
        f"(expected CORRECTABLE)")
    if rsp.corrupt_mask[0].bit_count() != 1:
      self.logger.error(
        f"ERROR [{self.tc_name}] corr corrupt_mask has "
        f"{rsp.corrupt_mask[0].bit_count()} bits set (expected 1)")
    if rsp.rdata[0] == seed_corr:
      self.logger.error(
        f"ERROR [{self.tc_name}] corr rdata not physically corrupted")
    if (rsp.rdata[0] ^ rsp.corrupt_mask[0]) != seed_corr:
      self.logger.error(
        f"ERROR [{self.tc_name}] corr repair (rdata ^ mask) "
        f"{rsp.rdata[0] ^ rsp.corrupt_mask[0]:x} != seeded {seed_corr:x}")

    # --- Uncorrectable read -------------------------------------------------
    rsp = await self.read_row(addr_unc, 0x902)
    if rsp.injected_fault != VipDramFault.UNCORRECTABLE:
      self.logger.error(
        f"ERROR [{self.tc_name}] unc read fault = {rsp.injected_fault.name} "
        f"(expected UNCORRECTABLE)")
    if rsp.corrupt_mask[0] != 0:
      self.logger.error(
        f"ERROR [{self.tc_name}] unc corrupt_mask {rsp.corrupt_mask[0]:x} != 0 "
        f"(double-bit is unrepairable)")
    if (rsp.rdata[0] ^ seed_unc).bit_count() != 2:
      self.logger.error(
        f"ERROR [{self.tc_name}] unc rdata differs from seed in "
        f"{(rsp.rdata[0] ^ seed_unc).bit_count()} bits (expected 2)")

    # --- Backing store is untouched (corruption is response-only) -----------
    if self.env.dram.backdoor_read(addr_corr) != seed_corr:
      self.logger.error(
        f"ERROR [{self.tc_name}] store at corr row mutated by faulted read")
    if self.env.dram.backdoor_read(addr_unc) != seed_unc:
      self.logger.error(
        f"ERROR [{self.tc_name}] store at unc row mutated by faulted read")

    # --- Clearing faults makes the row read clean again ---------------------
    self.env.dram.clear_all_faults()
    rsp = await self.read_row(addr_corr, 0x903)
    if rsp.injected_fault != VipDramFault.NONE:
      self.logger.error(
        f"ERROR [{self.tc_name}] corr read after clear_all_faults fault = "
        f"{rsp.injected_fault.name} (expected NONE)")
    if rsp.rdata[0] != seed_corr:
      self.logger.error(
        f"ERROR [{self.tc_name}] corr rdata after clear {rsp.rdata[0]:x} != "
        f"seeded {seed_corr:x}")
