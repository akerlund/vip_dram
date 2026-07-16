# vip_dram — Device-Only Example Testbench

A self-checking UVM environment that verifies the `vip_dram` DRAM device model
**in isolation**: it drives the device directly over its neutral
`vip_dram_req`/`vip_dram_rsp` TLM contract — there is no memory controller, no
AXI4, no DUT RTL, and **no clock**. The full manager → `vip_mc` → `vip_dram`
system testbench belongs to `vip_mc` and lives elsewhere.

For the device itself (timing model, API, geometry) see the VIP's
[`vip_dram/README.md`](../../vip_dram/README.md). For a per-test description see
[`TEST_CASES.md`](TEST_CASES.md).

---

## Architecture

```text
        dram_base_test  (uvm_test)
        └── dram_env
             ├── vip_dram        #(DRAM_CFG_C)   ← device under test
             ├── dram_driver     #(DRAM_CFG_C)
             └── dram_scoreboard #(DRAM_CFG_C)

   driver.req_ap ──▶ dram.req_fifo.analysis_export      (requests in)
   dram.rsp_port ──▶ scoreboard.rsp_imp                 (responses out)
```

Everything is parameterized by one `vip_dram_cfg_t` (`DRAM_CFG_C` in
[`tb/dram_tb_pkg.sv`](tb/dram_tb_pkg.sv), the default DDR4-3200 ×8 8 GiB part).
The top [`tb/dram_tb_top.sv`](tb/dram_tb_top.sv) has no clock/reset/interface —
it just `run_test()`s the test selected by `+UVM_TESTNAME`.

### Components

- **`dram_driver`** ([tb/dram_driver.sv](tb/dram_driver.sv)) — owns the analysis
  port wired into `vip_dram.req_fifo` and offers two ways to push a request:
  - `send(req)` — fire-and-forget, for back-to-back streams.
  - `issue(req)` — the *checked* path: at issue time it asks the device's
    `predict()` for the expected first/last beat times and registers them with
    the scoreboard, then sends. Valid only with a single outstanding request,
    because `predict()` reads `$realtime` + the current committed state.
- **`dram_scoreboard`** ([tb/dram_scoreboard.sv](tb/dram_scoreboard.sv)) —
  subscribes to `rsp_port`. For any tag with a registered expectation it compares
  timing (within a 1-cycle `t_ck` tolerance) and page classification, raising a
  `uvm_error` on mismatch. It also stores every response by tag so a test can
  fetch one and assert on it directly.
- **`dram_env`** ([tb/dram_env.sv](tb/dram_env.sv)) — builds the three and wires
  them; sets the scoreboard tolerance from `cfg.timing.t_ck`.
- **`dram_base_test`** ([tc/dram_base_test.sv](tc/dram_base_test.sv)) — builds
  the env, installs the house report server, and provides the shared helpers
  (below). Each test overrides `body()`; the base raises/drops the run-phase
  objection around it.

---

## How a check works

The model's timing is deterministic and its `predict()` shares the exact formula
the device uses to `schedule()` (single source of truth). So:

1. The driver calls `predict(req)` **at the moment of issue** (same `$realtime`
   and committed state the device will schedule against) and records the expected
   `first/last_beat_ready_time` in the scoreboard, keyed by `req.tag`.
2. The device responds after the modelled latency; the scoreboard compares the
   observed response against the expectation.

This only holds for a **single outstanding** request, so the timing-checked
helper `send_checked()` issues one request and blocks until its response retires.
Tests that need genuine concurrency (page-hit streak, bank parallelism, FAW)
instead `send()` a back-to-back burst and assert on the **relationships** between
the collected responses (e.g. the spacing between consecutive `first` times),
which an absolute per-request predict cannot express.

---

## Base-test helpers

Test bodies use these (all via `super.`):

| Helper | Purpose |
|--------|---------|
| `addr_of(rank, bg, bank, row, col)` | build a byte address for a target via the device addr_map (returns `addr_t`) |
| `pattern(seed)` | a deterministic data row, byte *b* = `seed + b` |
| `mk_rd_req(addr, beats, tag)` | build a read request |
| `mk_wr_req(addr, data, tag)` | build a single-beat write (all strobes set) |
| `mk_ref(rank, tag)` | build a refresh request |
| `send_checked(req)` | predict + register expectation, send, wait for *this* response |
| `chk_time(nm, got, exp)` | assert two times equal within tolerance |

The scoreboard adds `expect_page(tag, hit, miss, empty)`, `wait_for(n)`, and
`get_rsp(tag)`; the device exposes `predict()`, the backdoor API
(`backdoor_write/read`, `memory_*`), `reset()`, and the counters
(`get_page_hit_count()`, `get_refresh_count()`, …).

---

## Running

```sh
cd examples/vip_dram
./scripts/compile.sh                  # builds + runs tc_dram_smoke (default)
./scripts/compile.sh tc_dram_faw_stress
```

`scripts/compile.sh` analyzes UVM, the dependency packages (`bool`,
`report_server`, `vip_memory`), the device VIP (`vip_dram`), and this example,
elaborates `dram_tb_top`, and runs the chosen `+UVM_TESTNAME`. It needs
`$VCS_HOME` pointing at a VCS install with the bundled UVM-1.2; build artifacts
land in `rundir/vcs/` (gitignored). The example also exposes
[`yml/compile.yml`](yml/compile.yml) for the project's regression flow.

A test passes with `UVM_ERROR=0, UVM_FATAL=0`. The scoreboard prints a one-line
tally per run, e.g. `INFO [sb] responses=2  timing ok/bad=2/0  page ok/bad=2/0`.

---

## Adding a test

1. Create `tc/tc_dram_<name>.sv` extending `dram_base_test`, override `body()`.
2. Build requests with the `super.mk_*`/`super.addr_of` helpers; check with
   `super.send_checked` + scoreboard expectations, or `send()` + relational
   asserts on `super.env.sb.get_rsp(...)`.
3. Register it with an `` `include `` in [tc/dram_tc_pkg.sv](tc/dram_tc_pkg.sv).
4. Document it in [TEST_CASES.md](TEST_CASES.md).

---

## File layout

```text
examples/vip_dram/
├── README.md                 (this file)
├── TEST_CASES.md             (per-test descriptions)
├── tb/
│   ├── dram_tb_pkg.sv        (geometry param + harness includes)
│   ├── dram_scoreboard.sv    (predictor-vs-observed checker)
│   ├── dram_driver.sv        (TLM request driver)
│   ├── dram_env.sv           (DUT + driver + scoreboard)
│   └── dram_tb_top.sv        (run_test; no clk/rst)
├── tc/
│   ├── dram_tc_pkg.sv        (test registry)
│   ├── dram_base_test.sv     (env build + shared helpers)
│   └── tc_dram_*.sv          (the 12 test cases)
├── scripts/compile.sh        (standalone VCS build + run)
├── yml/compile.yml           (project regression filelist)
└── rundir/                   (build output — gitignored)
```
