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
## cocotb testbench top (counterpart of testbench/sv/tb/dram_tb_top.sv): runs each
## ported vip_dram device-only test case (uvm_test subclass) on the pure-TLM
## dram_hdl_top shell. No clock, no bus -- the device advances sim time itself via
## cocotb Timers. This module also folds in the SV dram_tc_pkg role: the import
## block below pulls in every TC so the pyuvm factory can resolve it by name. One
## @cocotb.test entry per TC; run_all_tcs.py selects the public `tc_dram_*`
## names via `testcase=` so each runs in a fresh simulator.
##
################################################################################

import os
import sys

import cocotb

from pyuvm import uvm_root

_HERE = os.path.dirname(os.path.abspath(__file__))
_PY_ROOT = os.path.dirname(_HERE)


def _find_vip_root(start):
  """Locate this repo's root by walking up to the .git marker, so component
  paths don't depend on how deep this example sits. Override with $VIP_ROOT;
  falls back to the historical 2-levels-up guess if no marker is found."""
  env = os.environ.get("VIP_ROOT")
  if env:
    return os.path.abspath(env)
  d = start
  while True:
    if os.path.exists(os.path.join(d, ".git")):  # dir (repo) or file (worktree)
      return d
    parent = os.path.dirname(d)
    if parent == d:                               # hit filesystem root
      return os.path.abspath(os.path.join(start, "..", ".."))
    d = parent


_ROOT = _find_vip_root(_HERE)
# Shared VIP components this example imports (mirrors the SV `depend` graph):
# vip_dram's own py/ at the repo root, and vip_memory checked out as a git
# submodule. Example-local dirs are relative to testbench/py.
_COMPONENT_PYS = [
    os.path.join(_ROOT, "py"),
    os.path.join(_ROOT, "submodules", "vip_memory", "py"),
]
_LOCAL_PYS = [_HERE, os.path.join(_PY_ROOT, "tc")]
for p in _COMPONENT_PYS + _LOCAL_PYS:
  if os.path.isdir(p) and p not in sys.path:
    sys.path.insert(0, p)
  elif not os.path.isdir(p):
    raise RuntimeError(
        f"dram_tb_top: expected source dir not found: {p}\n"
        f"  (VIP root resolved to {_ROOT}; set $VIP_ROOT to override)")

# Import TC classes so the pyuvm factory can resolve them by name.
from tc_dram_smoke import tc_dram_smoke                                # noqa: E402,F401
from tc_dram_backdoor_preload import tc_dram_backdoor_preload          # noqa: E402,F401
from tc_dram_bank_parallel import tc_dram_bank_parallel               # noqa: E402,F401
from tc_dram_faw_stress import tc_dram_faw_stress                     # noqa: E402,F401
from tc_dram_ideal_zero_latency import tc_dram_ideal_zero_latency     # noqa: E402,F401
from tc_dram_page_hit_streak import tc_dram_page_hit_streak           # noqa: E402,F401
from tc_dram_page_thrash import tc_dram_page_thrash                   # noqa: E402,F401
from tc_dram_partial_write import tc_dram_partial_write               # noqa: E402,F401
from tc_dram_predict_matches_schedule import tc_dram_predict_matches_schedule  # noqa: E402,F401
from tc_dram_preset_sweep import tc_dram_preset_sweep                 # noqa: E402,F401
from tc_dram_read_fault import tc_dram_read_fault                     # noqa: E402,F401
from tc_dram_refresh_explicit import tc_dram_refresh_explicit         # noqa: E402,F401
from tc_dram_reset_recovery import tc_dram_reset_recovery             # noqa: E402,F401
from tc_dram_wr_rd_turnaround import tc_dram_wr_rd_turnaround         # noqa: E402,F401
from tc_dram_writes_then_reads import tc_dram_writes_then_reads       # noqa: E402,F401


async def _run(test_name):
  """Run one ported test on the pure-TLM shell. No clock/reset/bus -- the device
  advances sim time via cocotb Timers as it schedules responses."""
  await uvm_root().run_test(test_name)


@cocotb.test(name="tc_dram_smoke", timeout_time=10, timeout_unit="ms")
async def tc_dram_smoke(dut):
  await _run("tc_dram_smoke")


@cocotb.test(name="tc_dram_backdoor_preload", timeout_time=10, timeout_unit="ms")
async def tc_dram_backdoor_preload(dut):
  await _run("tc_dram_backdoor_preload")


@cocotb.test(name="tc_dram_bank_parallel", timeout_time=10, timeout_unit="ms")
async def tc_dram_bank_parallel(dut):
  await _run("tc_dram_bank_parallel")


@cocotb.test(name="tc_dram_faw_stress", timeout_time=10, timeout_unit="ms")
async def tc_dram_faw_stress(dut):
  await _run("tc_dram_faw_stress")


@cocotb.test(name="tc_dram_ideal_zero_latency", timeout_time=10, timeout_unit="ms")
async def tc_dram_ideal_zero_latency(dut):
  await _run("tc_dram_ideal_zero_latency")


@cocotb.test(name="tc_dram_page_hit_streak", timeout_time=10, timeout_unit="ms")
async def tc_dram_page_hit_streak(dut):
  await _run("tc_dram_page_hit_streak")


@cocotb.test(name="tc_dram_page_thrash", timeout_time=10, timeout_unit="ms")
async def tc_dram_page_thrash(dut):
  await _run("tc_dram_page_thrash")


@cocotb.test(name="tc_dram_partial_write", timeout_time=10, timeout_unit="ms")
async def tc_dram_partial_write(dut):
  await _run("tc_dram_partial_write")


@cocotb.test(name="tc_dram_predict_matches_schedule", timeout_time=10, timeout_unit="ms")
async def tc_dram_predict_matches_schedule(dut):
  await _run("tc_dram_predict_matches_schedule")


@cocotb.test(name="tc_dram_preset_sweep", timeout_time=10, timeout_unit="ms")
async def tc_dram_preset_sweep(dut):
  await _run("tc_dram_preset_sweep")


@cocotb.test(name="tc_dram_read_fault", timeout_time=10, timeout_unit="ms")
async def tc_dram_read_fault(dut):
  await _run("tc_dram_read_fault")


@cocotb.test(name="tc_dram_refresh_explicit", timeout_time=10, timeout_unit="ms")
async def tc_dram_refresh_explicit(dut):
  await _run("tc_dram_refresh_explicit")


@cocotb.test(name="tc_dram_reset_recovery", timeout_time=10, timeout_unit="ms")
async def tc_dram_reset_recovery(dut):
  await _run("tc_dram_reset_recovery")


@cocotb.test(name="tc_dram_wr_rd_turnaround", timeout_time=10, timeout_unit="ms")
async def tc_dram_wr_rd_turnaround(dut):
  await _run("tc_dram_wr_rd_turnaround")


@cocotb.test(name="tc_dram_writes_then_reads", timeout_time=10, timeout_unit="ms")
async def tc_dram_writes_then_reads(dut):
  await _run("tc_dram_writes_then_reads")
