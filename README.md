# vip_dram — DRAM device model VIP

`vip_dram` is a **protocol-agnostic, controller-agnostic DDR device model**. It
responds to memory requests with *realistic* DRAM timing and behaviour — bank
state, page hit/miss/empty classification, per-bank/per-bank-group timing, the
four-activate window, and explicit refresh — without being a bit/cycle-exact
reproduction of a DRAM die. The detailed bank/timing model is the *means* to
believable latency, ordering, and refresh behaviour, not a claim of device
fidelity.

The device has **no bus, no virtual interface, and no clock**. It is a pure UVM
component driven over a neutral TLM contract, so it drops into any UVM
environment — behind a memory-controller VIP, or driven directly by a unit test
or a DPI/cosim poke driver.

```text
[manager VIP / TB] ── AXI4 ── [vip_mc] ── neutral TLM ── [vip_dram] ── vip_mem
                                          (req / rsp)
```

`vip_mc` (a separate sibling VIP) owns everything above the neutral contract:
refresh scheduling, command reordering, address interleaving, and the host bus
protocol. `vip_dram` models only the device. A direct TLM/DPI driver can stand
in for `vip_mc` for device-only contract tests.

If the DRAM terminology is new, start with the
[`DRAM primer`](docs/PRIMER.md). See
[`IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) for the full design
rationale; this README documents the delivered code.

---

## What it models / what it does not

**Models** (device physics):

- Per-bank FSM (`IDLE` / `ACTIVE`) with an open row.
- Page classification: **hit** (row open & matching), **miss** (open, wrong
  row), **empty** (bank precharged).
- Timing: `tRCD`, `tCL`, `tWL`, `tWR`, `tRTP`, `tCCD_S/L`, `tWTR_S/L`, `tRTW`,
  `tRAS`, `tRC`, `tRP`, `tBL`, rank-level `tRRD_S/L` + `tFAW`.
- Explicit **REF**: blocks the whole rank for `tRFC`, then precharge-all.
- Channel-level data-bus contention (`tBL` spacing, shared across ranks).
- Page hit/miss/empty + refresh debug counters.
- Page policy enum (only **OPEN** is implemented today).
- A side-effect-free `predict()` for scoreboards.
- Backdoor preload/dump/randomize over an owned `vip_mem`.

**Does not model** (an MC concern, out of scope, or future work):

- Refresh scheduling / the `tREFI` timer (the device never auto-refreshes —
  the caller issues `VIP_DRAM_OP_REF_E`).
- Command reordering / FR-FCFS, write coalescing, queue depth.
- Address interleaving across channels/ranks.
- Any bus protocol (AXI4 / APB / DFI) or pin/electrical detail.
- Mode registers, training, CRC/parity/DBI, DIMM register devices — these need
  a future JEDEC-command / DFI face (a timing *preset* is not protocol support).

---

## Architecture

```text
            ┌──────────────────────────────────────────────┐
            │                   vip_dram                    │
            │                 (uvm_component)               │
            │                                               │
  req_fifo  │   ┌──────────────┐      ┌──────────────────┐  │
 ──────────▶│──▶│  consumer    │─────▶│ vip_dram_scheduler│  │
 (TLM in)   │   │  task (fork) │      │  + bank_state[N]  │  │
            │   └──────┬───────┘      └──────────────────┘  │
            │          │ forked, delayed response            │
            │          ▼                                     │
            │   ┌──────────────┐      ┌──────────────────┐  │
  rsp_port  │   │ do_mem_access│─────▶│     vip_mem      │  │
 ◀──────────│◀──│  @ ready time│      │  (backing store) │  │
 (TLM out)  │   └──────────────┘      └──────────────────┘  │
            └──────────────────────────────────────────────┘
```

The consumer task drains `req_fifo`, asks the scheduler for the access timing
and page classification, snapshots that, and forks a response that sleeps until
the scheduled completion time before touching memory and publishing the result
on `rsp_port`. A reset cancels every in-flight forked response with
`disable fork` so no stale beat fires afterward.

---

## File & class map

| File | Kind | Contents |
|------|------|----------|
| `vip_dram_types_pkg.sv` | package | enums, the `vip_dram_cfg_t` geometry parameter, address-map types, the `vip_dram_types #(CFG_P)` derived-width container |
| `vip_dram_timing_pkg.sv` | package | timing record, presets, ns→cycle helper, density→`tRFC` table |
| `vip_dram_addr_pkg.sv` | package | pure address decode/encode/bank-index functions |
| `vip_dram_req.sv` | class `#(CFG_P)` | neutral request item (`uvm_sequence_item`) |
| `vip_dram_rsp.sv` | class `#(CFG_P)` | neutral response item (`uvm_sequence_item`) |
| `vip_dram_config.sv` | class `#(CFG_P)` | runtime timing + policy + flags (`uvm_object`) |
| `vip_dram_bank_state.sv` | class | per-bank FSM record (plain, non-parameterized) |
| `vip_dram_scheduler.sv` | class `#(CFG_P)` | the timing core (plain object, owned by the device) |
| `vip_dram.sv` | class `#(CFG_P)` | the device (`uvm_component`) |
| `vip_dram_pkg.sv` | package | umbrella — imports the three packages, `` `include ``s the class items |
| `vip_dram.svh` | header | one-line compile entry point |

Everything is parameterized by a single `vip_dram_cfg_t CFG_P`. The same `CFG_P`
flows into the device **and** the neutral items, so item widths always track the
device channel width.

---

## The neutral TLM contract

### `vip_dram_req` (request)

| Field | Type | Meaning |
|-------|------|---------|
| `addr` | `longint unsigned` | byte address (RD/WR only; ignored for REF) |
| `op` | `vip_dram_op_t` | `VIP_DRAM_OP_RD_E` / `WR_E` / `REF_E` |
| `beats` | `int unsigned` | number of **DRAM column accesses** (BL8 bursts), **not** AXI4 bus beats; `≥ 1` for RD/WR |
| `has_explicit_rank` | `bit` | `0` → derive rank from `addr`; `1` → force `rank` |
| `rank` | `int unsigned` | target rank (forced if `has_explicit_rank`, and always for REF) |
| `wdata` / `wstrb` | `data_t[]` / `strb_t[]` | write payload, one element per column access |
| `tag` | `longint unsigned` | caller's correlation tag, echoed on the response |
| `arrival_time` | `realtime` | stamped by the device on accept |

### `vip_dram_rsp` (response)

| Field | Type | Meaning |
|-------|------|---------|
| `tag` | `longint unsigned` | echo of `req.tag` |
| `op` | `vip_dram_op_t` | operation this completes |
| `rdata` | `data_t[]` | read payload, one element per column access (RD only) |
| `first_beat_ready_time` | `realtime` | absolute readiness of column access 0 |
| `last_beat_ready_time` | `realtime` | absolute readiness of column access `beats-1` (== first when `beats==1`) |
| `was_page_hit / miss / empty` | `logic` | mutually-exclusive classification of the access |

Both times are **absolute** simulation times in **nanoseconds** (`realtime`), so
sub-ns values such as `tRCD = 13.75 ns` are exact and timescale-independent.

### Beat granularity (the contract)

- **One `vip_dram_req` == one DRAM column burst (BL8)**, `req.beats` column
  accesses, each moving `ROW_BYTES_P` bytes (`vip_dram_types #(CFG_P)::DATA_BITS`
  bits = 64 B at the default config). It is **not** the AXI4 `awlen+1`/`arlen+1`.
- The MC owns the AXI4→DRAM mapping (`beats = ceil(total_bytes / ROW_BYTES_P)`).
  `vip_dram` never sees AXI4 widths and never splits or re-packs.
- Successive column accesses of one request advance the column index on the
  **same** open row (page hits, spaced by `tCCD_L`). The first access pays the
  row-open cost; the rest are column-to-column.

---

## Class reference

### `vip_dram_types_pkg`

The neutral type registry — no bus dependency, imports only
`vip_mem_types_pkg`.

- **Enums.** `vip_dram_op_t` (RD/WR/REF), `vip_dram_page_policy_t`
  (OPEN/CLOSED/ADAPTIVE), `vip_dram_bank_fsm_t` (IDLE/ACTIVE/REFRESHING).
- **`vip_dram_cfg_t`** — the compile-time geometry parameter struct:
  `ROW_BYTES_P`, `ADDR_WIDTH_P`, `N_RANKS_P`, `N_BANK_GROUPS_P`, `BANKS_PER_BG_P`,
  `ROW_BITS_P`, `COL_BITS_P`, `DEVICE_WIDTH_P`, `N_DEVICES_PER_RANK_P`.
  `VIP_DRAM_CFG_DEFAULT_C` is DDR4 ×8, 8 Gb dies, 64-bit channel, 8 GiB
  (`ADDR_WIDTH_P = 33`).
- **`vip_dram_addr_map_t`** — per-field LSB offsets for the byte-address slice
  (the *widths* are fixed by the geometry; only the order is overridable).
  `vip_dram_default_addr_map(cfg)` builds the default LSB-first layout
  `[byte][col][bank][bg][row][rank]`.
- **`vip_dram_dec_t`** — a decoded address `{rank, bg, bank, row, col, byte_in_col}`.
- **`vip_dram_types #(CFG_P)`** — the derived-width container. Aliased by
  consumers (`typedef vip_dram_types #(CFG_P)::data_t data_t;`) so widths are
  computed once. Exposes `DATA_BITS`, `STRB_BITS`, `ADDR_BITS`, the `data_t` /
  `strb_t` / `addr_t` typedefs, and the `MEM_CFG` storage descriptor for the
  owned `vip_mem`.

### `vip_dram_timing_pkg`

DRAM timing in nanoseconds, plus presets and helpers.

- **`vip_dram_timing_t`** — the timing record (unpacked, because it carries
  `real` fields). `tRC`, `tBL`, `tRTW` are *derived*.
- **`vip_dram_get_preset(preset)`** — fills the record for a speed bin. Only
  **DDR4-3200 CL22** is authoritative (matches the plan table); the other
  presets (DDR4-2400, DDR3-1600, LPDDR4, DDR5, IDEAL) are first-pass and flagged
  `TODO: refine`. IDEAL collapses every delay to zero.
- **`vip_dram_trfc_ns(gen, density_gbit)`** — `tRFC` is density-driven, not
  bin-driven, so it lives in its own table keyed by `(generation, density)`.
  DDR4 figures are authoritative (JESD79-4 tRFC1); off-table densities clamp to
  the nearest-larger row.
- **`vip_dram_ns_to_cycles(ns, t_ck)`** — round a ns delay **up** to whole
  clock cycles (guards `t_ck ≤ 0` → 0).
- **`vip_dram_derive_trtw(...)`**, **`vip_dram_preset_gen(...)`**,
  **`vip_dram_trfc_max_gbit(...)`** — supporting helpers.

### `vip_dram_addr_pkg`

Pure functions over the geometry/map types (no UVM, no bus): field LSBs come
from `cfg.addr_map` (overridable), widths from the geometry (fixed).

- `vip_dram_decode_addr(addr, cfg, map) → vip_dram_dec_t`
- `vip_dram_encode_addr(dec, cfg, map) → addr` (the inverse; round-trips)
- `vip_dram_bank_index(cfg, dec) → int` (flat per-rank bank id, bg-major)
- `vip_dram_banks_per_rank(cfg) → int`
- `vip_dram_addr_extract` / `vip_dram_addr_place` (bit-slice primitives)

### `vip_dram_config #(CFG_P)`

Runtime (non-geometry) device properties — a `uvm_object`. Geometry is the
`CFG_P` parameter, **not** here.

- `timing` — the `vip_dram_timing_t` record (source of truth, overridable).
- `addr_map` — defaults to the CFG_P-derived layout; the MC may override it.
- `page_policy` (default OPEN), `enable_bus_contention` (default TRUE),
  `enable_bank_scoreboard`, `randomize_mem_on_reset`.
- `mem_cfg` — the owned `vip_mem`'s X-handling (a device-storage property).
- `apply_preset(preset)` — load a bin's AC timings, then **re-derive `tRFC`**
  from the per-die density implied by `CFG_P` (so a re-sized device gets the
  right refresh time with no manual edit).
- `density_gbit()` — per-die density from the geometry.
- `ns_to_cycles(ns)` — the centralized quantization entry point.
- `validate()` — `uvm_fatal` on bad geometry, non-power-of-two channel width,
  `t_ck ≤ 0`, `tRC < tRAS + tRP`, or geometry-field widths that do not sum
  exactly to `ADDR_WIDTH_P`; `uvm_warning` if the density is past the `tRFC`
  table.

### `vip_dram_req` / `vip_dram_rsp` `#(CFG_P)`

The neutral items (above). Both are populated directly by the caller/device
(not randomized), with explicit `do_copy` / `do_compare` / `convert2string`
(house style avoids the `uvm_field_*` macros). `do_compare` excludes the timing
and classification fields — those are simulation observables, not item identity.

### `vip_dram_bank_state`

A plain per-bank record (no geometry — the scheduler owns an array of them):
the FSM `state`, the `open_row`, and the command/data reference timestamps
(`t_last_act`, `t_last_rd`, `t_last_rd_end`, `t_last_wr`, `t_last_wr_end`,
`t_last_pre`). On construction and `reset()` every timestamp is `NEG_LARGE_C`
(≈ −∞), **not** 0 — so every `max(now, t_last_* + tXX)` floor collapses to `now`
on the first access to a fresh bank (no spurious `tRP`/`tCCD` term).

### `vip_dram_scheduler #(CFG_P)`

The timing core. Owns the per-(rank,bank) `vip_dram_bank_state` array plus
rank-level tracking (`last_act_any`, `last_act_bg`, the 4-deep FAW ring,
`last_burst_end`, `rank_busy`).

**Single source of truth (M9).** The latency formula lives **only** in the
pure, side-effect-free `compute_latency()`, which returns a `lat_t` carrying the
timing *and* the commit data *and* the page classification. `predict()` and
`schedule()` are thin wrappers that both **return a `result_t` by value** (the
two readiness times + hit/miss/empty/is_ref) — so the caller needs no
side-channel state; `schedule()` additionally calls `commit_state()`, the
**only** place bank/rank state mutates. Predicted and committed timing therefore
cannot drift.

Public surface: `predict()` and `schedule()` (both → `result_t`), `reset()`, and
the `n_page_hit/miss/empty/n_ref` counters. Everything else (`compute_latency`,
`commit_state`, `pack`, `quantize`, `gate_activate`, the FAW ring helpers, …) is
`protected`.

### `vip_dram #(CFG_P)`

The device `uvm_component`. Public surface:

- `req_fifo` (`uvm_tlm_analysis_fifo #(req_t)`) — connect the producer's analysis
  port to `req_fifo.analysis_export`.
- `rsp_port` (`uvm_analysis_port #(rsp_t)`) — subscribe for responses.
- `cfg` — the `vip_dram_config` (sourced from the `config_db` key `"cfg"` if
  present, else default-created in `build_phase`).
- `reset_event` (`uvm_event`) and the `reset()` **task**.
- `predict(req, first, last)` — delegates to the scheduler's predictor.
- `get_page_hit_count()` / `get_page_miss_count()` / `get_page_empty_count()` /
  `get_refresh_count()` — debug tallies of events the device executed (one per
  request consumed; a different object from any controller-side count).
- Backdoor API (no timing — see below).

`build_phase` resolves and validates the config, allocates the `vip_mem`
(constructed with `new`, since `vip_mem` is not factory-registered), the
scheduler, the FIFO/port, and the events. `run_phase` runs the reset-safe
consumer. `do_mem_access` performs the actual `vip_mem` read/write at delivery
time (REF touches no memory).

---

## Timing model

`now` is the request's arrival time (`$realtime`), floored by `rank_busy` so an
access cannot start while the rank is mid-refresh. All delays are quantized
**up** to whole DRAM clock cycles via `t_ck` (an identity for DDR4-3200, where
every value is already a whole-cycle multiple).

```text
hit  (bank ACTIVE, same row), access 0:
  read  : max(now, t_last_rd + tCCD_L, t_last_wr_end + tWTR_L) + tCL
  write : max(now, t_last_wr + tCCD_L, t_last_rd    + tRTW)    + tWL

miss (bank ACTIVE, wrong row), access 0:
  pre = max(now, t_last_rd + tRTP, t_last_wr_end + tWR, t_last_act + tRAS)
  read  : pre + tRP + tRCD + tCL          (write: + tWL)

empty (bank IDLE), access 0:
  read  : max(now, t_last_pre + tRP) + tRCD + tCL    (write: + tWL)

per-beat (accesses 1..beats-1, page hits on the now-open row):
  ready[i] = ready[i-1] + tCCD_L

refresh (REF): max(now, last-op-on-rank) + tRFC, then precharge-all the rank
```

On top of the row-open cost, the first CAS of every access is gated by
rank-level **column-spacing** and **bus-turnaround** constraints (so they apply
uniformly to hits, misses and empties):

- `tCCD_L` vs. the most recent CAS to the **same** bank group; `tCCD_S` vs. the
  most recent CAS to **any** bank group (since `tCCD_L ≥ tCCD_S`, the `_S` term
  only binds when the prior CAS really was to a different bank group).
- read-after-write: `tWTR_L`/`tWTR_S` from the last WR **data**-burst end
  (same / any bank group); write-after-read: `tRTW` from the last RD **command**.

An activate is additionally gated by `tRRD_S` (vs. the last ACT to any bank
group), `tRRD_L` (vs. the last ACT to the same bank group), and `tFAW` (vs. the
oldest of the rank's last four ACTs). When `enable_bus_contention`, the first
data beat is also gated by the previous burst's end (`+tBL`) — a single
**channel-wide** edge, since the DQ bus is shared by every rank in the channel.

**Reference edges** (which edge each constraint is measured from):

| Parameter | Referenced from |
|-----------|-----------------|
| `tRTP`, `tRTW`, `tCCD_*` | the prior **command** (`t_last_rd` / `t_last_wr`) |
| `tWTR_*`, `tWR` | the last WR **data** burst end (`t_last_wr_end`) |
| `tRAS`, `tRC`, `tRRD_*` | the ACT **command** (`t_last_act`) |
| `tRP` | the PRE **command** (`t_last_pre`) |

### Presets and the default geometry

DDR4-3200 CL22 (`t_ck = 0.625 ns`) is authoritative: `tRCD = tRP = tCL = 13.75`,
`tRAS = 32`, `tWL = 10`, `tWR = 15`, `tRTP = 7.5`, `tCCD_L = 5.0`, `tRRD_L = 4.9`,
`tFAW = 21`, `tWTR_L = 7.5`, `tRFC = 350` (8 Gb), `tBL = 2.5`. `tRC` and `tRTW`
are derived. The default config is a 64-bit, 8 GiB channel (`byte 6 + col 10 +
bank 2 + bg 2 + row 13 + rank 0 = 33` address bits). Re-sizing the device
re-derives `tRFC` from the new density automatically.

---

## Address mapping

The default LSB-first slice is `[byte][col][bank][bg][row][rank]`
(column-interleaved, row-MSB). Override `cfg.addr_map` to reorder fields; widths
always track the geometry, so a slice can be reordered but never resized out of
step with the device. Example (default config):

```text
byte address 0x0004_0840
  byte_in_col [5:0]   = 0    col [15:6] = 33    bank [17:16] = 0
  bg [19:18]   = 1    row [32:20] = 0    rank = 0  (n_ranks = 1)
→ {rank0, bg1, bank0, row0, col33}
```

---

## Reset & lifecycle

`reset()` is a **task** (not a function): it must cancel in-flight forked
responses and block until the consumer has drained. Two equivalent entry points:
call `reset()`, or trigger `reset_event` directly. On reset the consumer's
`disable fork` kills every scheduled-but-unfired response, `req_fifo` is
flushed, all banks return to `IDLE`, the FAW ring clears, and every `t_last_*`
returns to `NEG_LARGE`. No response from before the reset can fire afterward.
`vip_mem` is optionally re-randomized (`cfg.randomize_mem_on_reset`).

---

## Usage

```sv
// 1. Pick a geometry (or use the default) and parameterize everything with it.
localparam vip_dram_cfg_t CFG = VIP_DRAM_CFG_DEFAULT_C;
typedef vip_dram_req #(CFG) req_t;
typedef vip_dram_rsp #(CFG) rsp_t;

// 2. Build & configure (in the env's build_phase).
vip_dram_config #(CFG) cfg = vip_dram_config #(CFG)::type_id::create("cfg");
cfg.apply_preset(VIP_DRAM_PRESET_DDR4_3200_CL22_E);   // optional; this is the default
uvm_config_db #(vip_dram_config #(CFG))::set(this, "dram", "cfg", cfg);
dram = vip_dram #(CFG)::type_id::create("dram", this);

// 3. Connect (in connect_phase).
producer.req_port.connect(dram.req_fifo.analysis_export);
dram.rsp_port.connect(consumer.analysis_export);

// 4. Drive a 4-beat read.
req_t rq = req_t::type_id::create("rq");
rq.op = VIP_DRAM_OP_RD_E; rq.addr = 'h4_0840; rq.beats = 4; rq.tag = 7;
req_port.write(rq);          // device responds on rsp_port after the latency

// 5. Predict (scoreboard) — call at issue time; predict() reads $realtime.
realtime first, last;
dram.predict(rq, first, last);

// 5b. Debug counters.
$display("hits=%0d miss=%0d empty=%0d ref=%0d",
         dram.get_page_hit_count(), dram.get_page_miss_count(),
         dram.get_page_empty_count(), dram.get_refresh_count());

// 6. Backdoor (no timing).
dram.backdoor_write('h4_0840, 512'hDEAD_BEEF);
data = dram.backdoor_read('h4_0840);
dram.memory_randomize();     // or memory_reset(), backdoor_dump()/load()

// 6b. Device read-fault injection (deterministic, addressable — not
//     probabilistic). Physically corrupts the faulted beat and tags the response
//     via vip_dram_rsp.injected_fault (+ corrupt_mask for the repairable bit) for
//     a SECDED consumer (e.g. vip_mc cfg.ecc_enable): CORRECTABLE is un-flipped ->
//     OKAY with data restored, UNCORRECTABLE -> SLVERR with poisoned data.
dram.inject_fault('h4_0840, VIP_DRAM_FAULT_UNCORRECTABLE_E);
dram.clear_fault('h4_0840);  // or clear_all_faults(); get_fault(addr)

// 7. Reset (cancels in-flight responses, drains, resets state).
dram.reset();
```

> `predict()` computes against the **current** `$realtime` and the current
> committed bank state — not against `req.arrival_time`. Call it at the moment
> the request is issued (and in the same order the device will schedule) for the
> numbers to match the device.

---

## Compilation & dependencies

Add the one header to a filelist (with `+incdir` pointing at `vip_dram/`):

```sv
`include "vip_dram.svh"
```

It pulls in the three standalone packages and the umbrella `vip_dram_pkg` (which
`` `include ``s the parameterized class items so they share one compilation
unit). Required compile order:

1. `vip_memory_pkg` (dependency)
2. `vip_dram_types_pkg`, `vip_dram_timing_pkg`, `vip_dram_addr_pkg`, then
   `vip_dram_pkg`
3. consumer code (e.g. a `vip_mc` or a TB driver)

Dependencies: UVM and the `vip_memory` VIP
(`vip_mem_types_pkg` / `vip_memory_pkg`). No bus or interface dependency, and
no `bool_pkg` — the two behavioural flags in `vip_dram_config` are plain `bit`.

---

## Verification (device-only example)

Self-checking contract tests live in
[`examples/vip_dram/`](../examples/vip_dram/) and drive the device directly over
its TLM API — no MC, no AXI4, no clock. A small env wires a driver into
`req_fifo` and a predictor-vs-observed scoreboard onto `rsp_port`. Run one test
with the standalone VCS flow:

```sh
cd examples/vip_dram
./scripts/compile.sh tc_dram_smoke      # or any tc_* below
```

(or feed `examples/vip_dram/yml/compile.yml` to the project's regression flow;
pick a test with `+UVM_TESTNAME=<tc_name>`). The thirteen cases:

| Test | Stresses |
|------|----------|
| `tc_dram_smoke` | empty-bank latency = `tRCD+tWL` exactly; data round-trip |
| `tc_dram_page_hit_streak` | per-access spacing `tCCD_L`; 1 empty + 63 hits |
| `tc_dram_page_thrash` | alternating rows → `tRP+tRCD+tCL` per miss |
| `tc_dram_bank_parallel` | round-robin across bank groups → `tCCD_S` (< `tCCD_L`) |
| `tc_dram_wr_rd_turnaround` | WR→RD `tWTR` (`_L`/`_S`) + RD→WR `tRTW` bus turnaround |
| `tc_dram_faw_stress` | 5th ACT deferred to first-ACT + `tFAW` |
| `tc_dram_refresh_explicit` | REF blocks the rank `tRFC`; post-REF access empty |
| `tc_dram_writes_then_reads` | data integrity across banks/rows |
| `tc_dram_backdoor_preload` | backdoor seed → frontdoor/backdoor read-back |
| `tc_dram_partial_write` | `wstrb` byte-enable merge (masked bytes preserved) |
| `tc_dram_reset_recovery` | mid-flight reset cancels in-flight rsp + clears state |
| `tc_dram_preset_sweep` | every preset validates; predict == observed |
| `tc_dram_ideal_zero_latency` | IDEAL preset → first == last == arrival |

---

## Known limitations & not-yet-implemented

These are deliberate phase-1 boundaries or known approximations.

- **Page policy: OPEN only.** CLOSED/ADAPTIVE are accepted by config but behave
  as OPEN (no auto-precharge); `validate()` warns when a non-OPEN policy is set.
  `enable_bank_scoreboard`, the `REFRESHING` FSM state, and
  `pending_pre`/`pending_ref` are reserved for future work.
- **Cross-rank turnaround is approximated.** Within a rank, `tCCD_S/L`,
  `tWTR_S/L`, and `tRTW` are enforced; across ranks the only shared constraint
  modeled is the channel-wide `tBL` data-bus contention (rank-to-rank switching
  time `tRTR` is not modeled). Exact at the default `N_RANKS_P = 1`.
- **Only DDR4-3200 is timing-authoritative**; the other presets are first-pass
  approximations flagged `TODO: refine`. (At DDR4-3200, `tCCD_S == tWTR_S == tBL
  == 2.5 ns`, so the three constraints coincide numerically there.)
- **Multi-beat requests are modeled as same-row page hits** — a request whose
  `beats` cross a row boundary still schedules as all-hits while memory reads
  linearly. Keep `beats` within a row (the MC's job).
- **Caller-contract checks are advisory at runtime.** An out-of-range `req.rank`
  is a `uvm_fatal`; a `req.beats` vs `wdata.size()` (or `wstrb` size) mismatch
  is a `uvm_error` (writes still proceed, missing strobes default to all-enable).
