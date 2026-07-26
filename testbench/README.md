# vip_dram testbenches

This directory contains the device-only example regressions for `vip_dram`.
They verify the DRAM timing/storage model directly over its neutral TLM request
and response API. There is no memory controller, no AXI4, no DUT RTL, and no
clocked bus.

There are two implementations of the same testcase intent:

- [sv](sv) is the SystemVerilog UVM flow, built with FuseSoC and VCS.
- [py](py) is the pyUVM/cocotb flow, built with cocotb runner or FuseSoC and
  Verilator.

The shared testcase catalog is [TEST_CASES.md](TEST_CASES.md).

## Architecture

```text
dram_base_test
└── dram_env
    ├── vip_dram
    ├── dram_driver
    └── dram_scoreboard

driver.req_ap -> dram.req_fifo.analysis_export
dram.rsp_port -> scoreboard.rsp_imp
```

The driver issues TLM requests into the device. The scoreboard compares observed
responses against either an exact `predict()` expectation or per-test relational
checks for concurrent request streams.

## Layout

```text
testbench/
├── README.md
├── TEST_CASES.md
├── sv/
│   ├── README.md
│   ├── tb/
│   │   ├── dram_tb_top.sv
│   │   ├── dram_tb_pkg.sv
│   │   ├── dram_env.sv
│   │   ├── dram_driver.sv
│   │   └── dram_scoreboard.sv
│   ├── tc/
│   │   ├── dram_tc_pkg.sv
│   │   ├── dram_base_test.sv
│   │   └── tc_dram_*.sv
│   └── vip_dram_example.core
└── py/
    ├── README.md
    ├── run_all_tcs.py
    ├── run_fusesoc.sh
    ├── tb/
    │   ├── dram_tb_top.py
    │   ├── dram_hdl_top.sv
    │   ├── dram_env.py
    │   ├── dram_driver.py
    │   └── dram_scoreboard.py
    ├── tc/
    │   ├── dram_base_test.py
    │   └── tc_dram_*.py
    └── vip_dram_example_py.core
```

## Running

Fetch submodules once from the repository root:

```sh
git submodule update --init
```

SV/VCS flow:

```sh
fusesoc --cores-root . run --target default --tool vcs --setup --build \
        akerlund::vip_dram_example:0

cd build/akerlund__vip_dram_example_0/default-vcs
./akerlund__vip_dram_example_0 +UVM_TESTNAME=tc_dram_smoke \
  -l tc_dram_smoke.log
```

Python/Verilator flow:

```sh
cd testbench/py
python3 run_all_tcs.py
python3 run_all_tcs.py tc_dram_smoke
```

See [sv/README.md](sv/README.md) and [py/README.md](py/README.md) for
flow-specific notes.
