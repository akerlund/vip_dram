# vip_dram SystemVerilog testbench

This is the SystemVerilog UVM implementation of the shared `vip_dram`
device-only example regression. It builds with FuseSoC and VCS.

The shared testbench overview is [../README.md](../README.md). The shared
testcase catalog is [../TEST_CASES.md](../TEST_CASES.md).

## Build And Run

Run from the repository root:

```sh
fusesoc --cores-root . run --target default --tool vcs --setup --build \
        akerlund::vip_dram_example:0
```

Run one testcase on the built simulator:

```sh
cd build/akerlund__vip_dram_example_0/default-vcs
./akerlund__vip_dram_example_0 +UVM_TESTNAME=tc_dram_smoke \
  -l tc_dram_smoke.log
```

For the full regression, loop the names from [../TEST_CASES.md](../TEST_CASES.md)
through the built simulator.
