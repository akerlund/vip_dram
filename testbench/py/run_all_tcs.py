#!/usr/bin/env python3
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
## Runs every ported vip_dram test case (uvm_test): build the pure-TLM shell
## (dram_vip_top) once, then run each TC in its own fresh sim invocation (clean
## uvm_root per TC).
##
##   python3 run_all_tcs.py                         # all TCs
##   python3 run_all_tcs.py tb_smoke                # one TC
##   python3 run_all_tcs.py tb_smoke tb_faw_stress  # a subset
##
################################################################################

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

import check_versions

HERE = Path(__file__).resolve().parent
TB = HERE / "tb"
TC = HERE / "tc"
PY = HERE.parent.parent / "py"
MEM_PY = HERE.parent.parent / "submodules" / "vip_memory" / "py"
SIM = os.environ.get("SIM", "verilator")

TCS = [
    "tb_smoke",
    "tb_writes_then_reads",
    "tb_backdoor_preload",
    "tb_bank_parallel",
    "tb_page_hit_streak",
    "tb_page_thrash",
    "tb_faw_stress",
    "tb_ideal_zero_latency",
    "tb_partial_write",
    "tb_predict_matches_schedule",
    "tb_preset_sweep",
    "tb_read_fault",
    "tb_refresh_explicit",
    "tb_reset_recovery",
    "tb_wr_rd_turnaround",
]


def main():
  # Pre-flight: fail fast if any py port drifted from its SV .core version.
  drift = check_versions.check()
  if drift:
    for e in drift:
      print(f"VERSION DRIFT: {e}", file=sys.stderr)
    sys.exit(1)

  user_vl = Path.home() / ".local" / "verilator" / "bin"
  if (user_vl / "verilator").exists():
    os.environ["PATH"] = os.pathsep.join([str(user_vl), os.environ["PATH"]])

  # dram_tc_top.py bootstraps py/ + submodules/vip_memory/py + tb/ + tc/ itself,
  # but PYTHONPATH must at least locate dram_tc_top (this dir) and the source
  # dirs for the child sim process.
  paths = [str(HERE), str(TB), str(TC), str(PY), str(MEM_PY)]
  for p in paths:
    if p not in sys.path:
      sys.path.insert(0, p)
  os.environ["PYTHONPATH"] = os.pathsep.join(paths + [os.environ.get("PYTHONPATH", "")])

  tcs = sys.argv[1:] or TCS

  runner = get_runner(SIM)
  runner.build(
      sources=[str(TB / "dram_vip_top.sv")],
      hdl_toplevel="dram_vip_top",
      build_dir=str(HERE / "sim_build_tcs"),
      build_args=["-Wno-fatal"],
      always=True,
  )
  for tc in tcs:
    print(f"\n================ {tc} ================")
    runner.test(
        hdl_toplevel="dram_vip_top",
        test_module="dram_tc_top",
        testcase=tc,
        test_dir=str(HERE),
        build_dir=str(HERE / "sim_build_tcs"),
    )


if __name__ == "__main__":
  main()
