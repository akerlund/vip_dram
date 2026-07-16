# VIP DRAM — pyUVM Port

A faithful [pyUVM](https://github.com/pyuvm/pyuvm) / [cocotb](https://www.cocotb.org/)
port of the SystemVerilog `vip_dram` device model in [`../sv/`](../sv/). Same
protocol-agnostic DDR device, same timing scheduler, same neutral TLM contract —
re-expressed in Python so it runs on an open-source simulator.

> This is the **library** README (the ported device classes). To build and run
> it, see the example testbench:
> [`../testbench/py/README.md`](../testbench/py/README.md). The common
> [`../README.md`](../README.md) (protocol/feature reference) applies to both
> implementations — the Python API mirrors it.

## Stack

| Tool | Version | Role |
|------|---------|------|
| pyUVM | 4.0.1 | UVM class library on Python asyncio |
| cocotb | 2.0.1 | HDL cosimulation / the event loop / `Timer` time model |
| Verilator | ≥ 5.022 (using 5.050) | the simulator (2-state) |
| FuseSoC | 2.4.x | build/run orchestration (flow API) |

Unlike the AXI4 agent port, `vip_dram` needs **no `pyvsc`** — it has no `rand`
fields or constraints (requests are populated directly), no covergroups, and no
SVA. It reuses the already-ported `vip_mem` (`../submodules/vip_memory/py/`) as
its backing store.

## Layout — `py/` mirrors `sv/` 1:1

Filenames are preserved; only the extension changes. The `.svh`/`*_pkg`/`include`
umbrella mechanics are dropped — Python uses `import`.

```
vip_dram/
├── py/                          # this port
│   ├── vip_dram_types_pkg.py    # enums, VipDramCfgT, addr-map, width helpers, mask/clog2, sim-time helpers
│   ├── vip_dram_timing_pkg.py   # VipDramTimingT + preset table + tRFC/ns-to-cycles helpers
│   ├── vip_dram_addr_pkg.py     # decode/encode/bank_index address algorithms
│   ├── vip_dram_bank_state.py   # per-bank FSM record (NEG_LARGE timestamps)
│   ├── vip_dram_req.py  vip_dram_rsp.py     # neutral TLM request/response items
│   ├── vip_dram_config.py       # runtime config (timing/addr_map/flags), validate()
│   ├── vip_dram_scheduler.py    # the §7.4 timing core (pure arithmetic)
│   ├── vip_dram.py              # the device uvm_component (TLM + fork/reset + backdoor/fault API)
│   └── vip_dram_version.py      # port version marker (see "Versioning")
└── sv/                          # the SystemVerilog originals + the FuseSoC .core
```

## How the SV maps to Python

| SystemVerilog | Python port |
|---|---|
| `vip_dram #(CFG_P)` parameterized classes | a runtime `VipDramCfgT` object; widths are plain `int`, no parameterized classes |
| implicit packed-vector truncation | explicit `& mask(width)` — Python ints are unbounded (`mask`/`trunc`/`clog2` in `vip_dram_types_pkg.py`) |
| absolute-ns delays `#(deliver_at - $realtime)` | `await delay_ns(dt)` → `cocotb.Timer` in integer ps; `$realtime` → `sim_time_ns()` (1 ns / 1 ps top; every preset value is exact ps) |
| `fork`/`join_any`/`join_none`/`disable fork` reset | `cocotb.start_soon` + an in-flight task set that reset `.kill()`s; the worker is a `First(work, reset)` race |
| `uvm_event` (reset handshake) | a small persistent-trigger `_UvmEvent` in `vip_dram.py` (pyUVM has no `uvm_event`) |
| `uvm_tlm_analysis_fifo` / `uvm_analysis_port` | same pyUVM classes; the device drains `await req_fifo.get()` |
| packed structs (`result_t`, `lat_t`, cfg records) | `@dataclass` objects; `realtime` fields → Python `float` ns |
| `rand` / `constraint` / covergroups / SVA | **none** — `vip_dram` has no randomization, coverage, or assertions |

Source formatting follows the port convention: **2-space indentation** throughout.

## Versioning

The component's authoritative version lives in the SV `.core`
(`akerlund::vip_dram:1.0.0`). The port restates it in
[`vip_dram_version.py`](vip_dram_version.py) (`__version__` + `CORE_NAME`), and
the example's [`check_versions.py`](../testbench/py/check_versions.py) asserts the
two agree (for `vip_dram` and the `vip_memory` submodule), so the Python port
can't silently drift from the RTL.
