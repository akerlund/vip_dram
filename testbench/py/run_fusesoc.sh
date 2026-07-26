#!/usr/bin/env bash
################################################################################
# FuseSoC entry point for the pyUVM/cocotb vip_dram example.
#
# Builds + runs the cocotb testbench through Edalize's flow API (see the .core).
# FuseSoC runs cocotb from its build work_root, so this script puts the source
# dir on PYTHONPATH (dram_tb_top.py bootstraps the remaining paths itself) and
# the user-built Verilator on PATH.
#
#   ./run_fusesoc.sh                       # lint + sim (all 15 TCs, one sim)
#   ./run_fusesoc.sh --target lint         # lint only
#   ./run_fusesoc.sh --target sim          # build + run all TCs
#   COCOTB_TEST_FILTER=tc_dram_smoke ./run_fusesoc.sh --target sim
#   COCOTB_TEST_FILTER='tc_dram_smoke|tc_dram_read_fault' ./run_fusesoc.sh --target sim
################################################################################
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer the user-built Verilator (cocotb 2.0 needs >= 5.022).
if [ -x "$HOME/.local/verilator/bin/verilator" ]; then
  export PATH="$HOME/.local/verilator/bin:$PATH"
fi

# cocotb imports dram_tb_top from tb/; it adds the rest of the dirs to sys.path.
export PYTHONPATH="$HERE/tb:$HERE${PYTHONPATH:+:$PYTHONPATH}"

CORE="akerlund::vip_dram_example_py:0"

if [ "$#" -eq 0 ]; then
  fusesoc --cores-root "$HERE" run --target lint "$CORE"
  fusesoc --cores-root "$HERE" run --target sim  "$CORE"
else
  fusesoc --cores-root "$HERE" run "$@" "$CORE"
fi
