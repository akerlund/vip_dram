# VIP DRAM Example — pyUVM Port

The proof-of-parity testbench for the [pyUVM port of `vip_dram`](../../py/README.md):
the device-only environment (device + tiny TLM driver + predictor-vs-observed
scoreboard) plus **15 test cases**, 1:1 with the SystemVerilog example in
[`../sv/`](../sv/). There is **no DUT RTL and no clock** — the device is pure
TLM and advances simulation time itself with cocotb `Timer`s; `dram_vip_top.sv`
is just an empty Verilator shell so cocotb has a toplevel to elaborate.

## Prerequisites

- **Verilator ≥ 5.022** (cocotb 2.0 needs it). A 5.050 build at
  `~/.local/verilator` is picked up automatically by the run scripts.
- Python deps: `pyuvm==4.0.1`, `cocotb==2.0.1`, and (for the FuseSoC path)
  `fusesoc` (2.4.x) + `edalize`. **No `pyvsc`** — this VIP has no randomization.
- The `vip_memory` git submodule checked out (`git submodule update --init`) —
  the scoreboard/device reuse its Python `vip_mem`.

## Running

### Via the cocotb runner (simplest)

```bash
python3 run_all_tcs.py                 # all 15 TCs, each in a fresh sim
python3 run_all_tcs.py tb_smoke        # one TC
python3 run_all_tcs.py tb_smoke tb_read_fault   # a subset
```

`run_all_tcs.py` builds the shell once, then runs each TC in its own simulator
invocation (a clean `uvm_root` per TC). It runs a **version-drift preflight**
first (see below) and aborts if any port disagrees with its SV `.core`.

### Via FuseSoC (flow API)

```bash
./run_fusesoc.sh                       # lint + sim (all 15 TCs in one process)
./run_fusesoc.sh --target lint         # lint only
./run_fusesoc.sh --target sim          # build + run
COCOTB_TEST_FILTER=tb_smoke ./run_fusesoc.sh --target sim          # one TC
COCOTB_TEST_FILTER='tb_smoke|tb_read_fault' ./run_fusesoc.sh --target sim
```

FuseSoC drives cocotb through Edalize's `sim` flow (the `.core`'s
`cocotb_module: dram_tc_top`). The wrapper puts this dir on `PYTHONPATH` (the top
bootstraps the rest) and the user Verilator on `PATH`. All 15 tests run
sequentially in ONE simulator process; pyUVM clears its singletons between tests.

## How the tests are organized

- **`dram_tc_top.py`** — the cocotb top (counterpart of `../sv/tb/dram_tb_top.sv`).
  It bootstraps `sys.path` (`py/`, `submodules/vip_memory/py`, `tb/`, `tc/`),
  imports all 15 TC classes so the pyUVM factory can resolve them by name, and
  exposes one `@cocotb.test` wrapper `tb_<name>` per TC that calls
  `run_test("tc_dram_<name>")`.
- **`tc/tc_dram_*.py`** — the 15 ported `uvm_test` cases (1:1 with `../sv/tc/`).
- **`tb/`** — env, TLM driver, scoreboard, and the `dram_vip_top.sv` shell.
- **`tc/dram_base_test.py`** — request builders (`addr_of`/`pattern`/`mk_*`) and
  issue helpers (`send_checked`/`chk_time`). pyUVM has no UVM_ERROR exit code, so
  an error-counting log handler is attached over the whole tree and `check_phase`
  raises if any component logged an error — i.e. "0 UVM_ERROR == pass".

## Version-drift guard

```bash
python3 check_versions.py     # exit 0 = every py port matches its SV .core
```

Asserts each port's `<component>_version.py` (`__version__` + `CORE_NAME`) equals
the version in its SV `.core` — for `vip_dram` and the `vip_memory` submodule.
`run_all_tcs.py` runs it as a preflight.
