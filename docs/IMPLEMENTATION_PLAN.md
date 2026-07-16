# `vip_dram` — Implementation Plan

If the DRAM terms in this plan are new, start with
[`PRIMER.md`](PRIMER.md). It explains ranks, bank groups, rows, pages, bursts,
timing names, refresh, and how those concepts map onto this VIP.

A VIP that emulates a DRAM device. **The device is protocol-agnostic and
controller-agnostic**: it exposes a neutral request/response TLM API that
any memory controller VIP (e.g. `vip_mc`, to be added as a sibling VIP)
or a test-side DPI/poke driver can feed.

`vip_dram` models DDR **device physics**: bank state, per-bank/per-bank-group
timing, FAW window, REF execution, page policy. It does **not** own:

- Refresh scheduling (`tREFI` timer) — that's an MC concern.
- Command reordering / FR-FCFS — that's an MC concern.
- Address interleaving across channels/ranks — that's an MC concern.
- Any bus protocol (AXI4, APB, DFI, …) — that's an MC concern.

The companion VIP `vip_mc` (separate plan, built next) owns all of the
above and exposes a host-side bus protocol (AXI4 first) to user
testbenches. Together they form:

```text
[manager VIP / TB] ── AXI4 ── [vip_mc] ── neutral TLM ── [vip_dram] ── vip_mem
```

This split mirrors real silicon: in densemem the topology is
`densemem → AXI4 → MIG (controller) → DDR pins → DRAM device`. In the VIP,
`vip_mc` stands in for MIG and `vip_dram` stands in for the DRAM device.

**Goal.** Provide a *realistic-enough* DDR timing/behavior model so the
controller above it produces believable latency, ordering, and refresh
behavior — **not** a silicon-exact reproduction of a DRAM die. The detailed
bank/timing model is the *means* to realistic responses, not a claim of
bit/cycle-exact device fidelity.

### Main features

- **Protocol-agnostic device model** over a neutral `vip_dram_req`/`vip_dram_rsp`
  TLM API — no bus, no virtual interface, no clock (pure UVM component).
- **Parameterized by one `vip_dram_cfg_t CFG_P`** (geometry + channel widths)
  that also sizes the neutral items; runtime timing/policy live in
  `vip_dram_config`.
- **DDR device physics**: per-bank FSM, per-bank/per-bank-group timing
  (tRCD, tCL, tWL, tWR, tRTP, tCCD_S/L, tWTR_S/L, tRRD_S/L, tRAS, tRC, tRP,
  tBL), rank-level **FAW**, page policy (OPEN/CLOSED/ADAPTIVE), and explicit
  **REF** execution (tRFC, precharge-all).
- **Timing presets** (DDR4-3200/2400, DDR3-1600, LPDDR4, DDR5, IDEAL), stored
  in ns and quantized to whole cycles on demand from `t_ck`.
- **Side-effect-free `predict()`** for MC/scoreboard latency checks, sharing a
  single `_compute_latency()` source of truth with the scheduler.
- **Backdoor** preload/dump/randomize over an owned `vip_mem`; whole-image type
  declared class-local (per-`CFG_P`), no leaked package symbol.
- **Backing storage granularity** = one DRAM column burst (BL8) per neutral-TLM
  beat (`vip_dram_types #(CFG_P)::DATA_BITS`), §4.6.
- **Deterministic, reproducible** control/timing (see below); reset is a *task*
  that cancels in-flight forked responses.
- Debug counters: page hit / miss / empty, REF executed.

### Determinism, seed & clocking

- **Initial / post-reset state is deterministic and seed-independent.** On
  construction and on `reset()`, all banks are `IDLE`, the FAW ring is empty,
  and every `t_last_*` timestamp is `-LARGE` (§7.3). The same stimulus always
  yields the same timing and ordering, regardless of the simulator seed.
- **Seed only affects *data*, never *timing*** — and only if memory
  randomization is explicitly enabled (`cfg.randomize_mem_on_reset` /
  `memory_randomize()`). With it off (default), un-written reads return 0 or X
  per `cfg.mem_cfg` — also deterministic.
- **No clock.** `vip_dram` has no clock or clocking block; all timing is
  computed in **absolute time** (ns, derived from `t_ck`). It therefore imposes
  no frequency relationship on anything above it — the controller's bus clock
  and the modeled DRAM clock are independent domains (see vip_mc "Clocking").

---

## 1. Scope

In scope:

- DDR device model: bank/row state, page policy (OPEN/CLOSED/ADAPTIVE).
- Per-bank/per-bank-group timing (tRCD, tCL, tWL, tWR, tRTP, tCCD_S/L,
  tWTR_S/L, tRRD_S/L, tRAS, tRC, tRP, tBL).
- Rank-level FAW enforcement.
- REF command handling (blocks the rank for `tRFC`; banks return to
  `IDLE` when REF completes).
- Per-rank/per-bank-group/per-bank scoreboards (debug counters).
- Direct backdoor API (preload/dump/randomize) for cosim/DPI environments.
- A side-effect-free `predict()` so the MC and scoreboards can compute
  expected latency without disturbing bank state.

Out of scope (lives in `vip_mc` or future work):

- Refresh policy / `tREFI` timer / refresh-deferral logic.
- Command reordering, write coalescing, command queue depth.
- Address interleaving (system-addr → channel/rank decision).
- Any bus protocol adapter (AXI4, APB, DFI).
- DFI-level signal modeling — only neutral TLM is exposed.
- HBM channels (model with multiple `vip_dram` instances).
- Per-DQ analog detail, ZQ calibration, DLL training, power-state.

A DDR4/DDR5/etc. **timing preset is not protocol support**: mode registers,
trainings, parity/CRC/DBI, DIMM register devices (RCD/MRCD/…), and pin-level
timing are deliberately **not** part of the neutral device core and would
require a future JEDEC-command or DFI-facing adapter.

---

## 2. Layered architecture

```text
                ┌────────────────────────────────────┐
                │           user testbench           │
                └──────────────────┬─────────────────┘
                                   │
          ┌────────────────────────┴─────────────────────────┐
          │                                                  │
  ┌───────▼──────────┐                              ┌────────▼──────────┐
  │     vip_mc       │                              │  direct TLM /     │
  │ (separate VIP,   │                              │  DPI driver       │
  │   AXI4 face)     │                              │  (cosim, unit-test)│
  └───────┬──────────┘                              └────────┬──────────┘
          │                                                  │
          │      neutral TLM: vip_dram_req / vip_dram_rsp    │
          └──────────────────────┬───────────────────────────┘
                                 │
                  ┌──────────────▼─────────────────────────┐
                  │              vip_dram                  │
                  │  ┌────────────────────────────────┐    │
                  │  │  scheduler  + bank state × N   │    │
                  │  │  (timing, FAW, REF execution,  │    │
                  │  │   page policy, addr_map)       │    │
                  │  └──────────────┬─────────────────┘    │
                  │                 │                      │
                  │            ┌────▼─────┐                │
                  │            │ vip_mem  │  ← storage     │
                  │            └──────────┘                │
                  └────────────────────────────────────────┘
```

Rules:

1. `vip_dram` depends only on `vip_memory_pkg`, `bool_pkg`, and its own types.
2. The neutral request API is the only public contract.
3. `vip_dram` has no virtual interface; it is a pure UVM component,
   parameterized by a single `vip_dram_cfg_t CFG_P` (geometry + channel
   widths) that also parameterizes the neutral `vip_dram_req`/`vip_dram_rsp`
   items (§4). Runtime timing/policy live in `vip_dram_config`.

---

## 3. Directory layout

```text
submodules/vip/vip_dram/
├── IMPLEMENTATION_PLAN.md       (this file)
├── README.md
├── vip_dram.svh                 (compile header)
├── vip_dram_pkg.sv              (single package — no bus deps)
│
├── vip_dram_types_pkg.sv        (enums + vip_dram_cfg_t param struct +
│                                 vip_dram_types #(CFG_P) derived-width container)
├── vip_dram_timing_pkg.sv       (timing presets, ns→cycles helper)
├── vip_dram_addr_pkg.sv         (address-map functions: decode/encode/bank index)
├── vip_dram_req.sv              (neutral memory-request item, #(CFG_P))
├── vip_dram_rsp.sv              (neutral response item, #(CFG_P))
├── vip_dram_config.sv           (runtime timing + policy + flags — no bus fields,
│                                 no geometry: geometry is the CFG_P parameter)
├── vip_dram_bank_state.sv       (per-bank FSM)
├── vip_dram_scheduler.sv        (latency calc + FAW + REF execution)
├── vip_dram.sv                  (the uvm_component)
│
└── yml/
```

Examples live under the shared
[`submodules/vip/examples/`](../../examples/) tree — `examples/vip_dram/`
holds device-only contract tests; the manager → `vip_mc` → `vip_dram`
end-to-end TB belongs to `vip_mc` and lives in `examples/vip_mc/`.

---

## 4. Neutral request/response API

`vip_dram_req` and `vip_dram_rsp` are `uvm_object`s carried over TLM
analysis FIFOs. No virtual interface.

```sv
typedef enum logic [1:0] {
  VIP_DRAM_OP_RD_E,
  VIP_DRAM_OP_WR_E,
  VIP_DRAM_OP_REF_E       // refresh — addr/data ignored; uses rank field
} vip_dram_op_t;

class vip_dram_req #(vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C)
  extends uvm_sequence_item;
  longint unsigned          addr;        // byte address (RD/WR only)
  vip_dram_op_t             op;
  // Number of **DRAM column accesses** (BL8 bursts), NOT AXI4 bus beats.
  // One column access moves `vip_dram_types #(CFG_P)::DATA_BITS` bits (one
  // channel row = 8*CFG_P.ROW_BYTES_P). The MC translates an AXI4 burst into
  // this granularity — see the beat-granularity contract in §4.6 (vip_mc §5.6).
  int unsigned              beats;       // # of DRAM column accesses (BL8)
  // Rank selection. `has_explicit_rank == 0` (the default) means the
  // device derives the rank from `addr` via its addr_map — including the
  // ordinary decode-to-rank-0 case. `has_explicit_rank == 1` means the
  // caller forces `rank` verbatim and the device skips address slicing.
  // The validity bit is what distinguishes "normal traffic that happens
  // to land on rank 0" from "explicitly forced rank 0"; the `rank` value
  // alone cannot. REF always uses the explicit path (`has_explicit_rank`
  // is set, `rank` selects the target rank, addr/data ignored).
  bit                       has_explicit_rank;
  int unsigned              rank;
  // Write only. One element per column access (`beats` elements); element
  // width is the device channel width, derived from the CFG_P parameter
  // (`vip_dram_types #(CFG_P)::data_t/strb_t`). Parameterizing the item is
  // what replaces the former fixed package width constants (and the
  // never-defined `MAX_DATA_BITS` / `MAX_STRB_BITS`, B3).
  vip_dram_types #(CFG_P)::data_t wdata [];
  vip_dram_types #(CFG_P)::strb_t wstrb [];
  // Caller's private tag — vip_dram echoes it on the response.
  longint unsigned          tag;
  // Filled by vip_dram on accept. NANOSECONDS (realtime) — the device models
  // timing in ns, not integer sim-time units, so sub-ns values (tRCD=13.75 ns)
  // are exact and timescale-independent.
  realtime                  arrival_time;
endclass

class vip_dram_rsp #(vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C)
  extends uvm_sequence_item;
  longint unsigned          tag;
  vip_dram_op_t             op;
  vip_dram_types #(CFG_P)::data_t rdata [];  // RD only; one per column access
  // Timing contract — absolute readiness times in NANOSECONDS (realtime):
  realtime                  first_beat_ready_time;
  realtime                  last_beat_ready_time;
  // Introspection (set on RD/WR completion):
  logic                     was_page_hit;
  logic                     was_page_miss;
  logic                     was_page_empty;
endclass
```

`vip_dram` interface:

```sv
class vip_dram #(vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C)
  extends uvm_component;
  // TLM in: caller (typically vip_mc) pushes requests here. Item and device
  // share the same vip_dram_cfg_t — a consumer instantiates
  // vip_dram_req #(CFG_P) for the same CFG_P it parameterized the device with.
  uvm_tlm_analysis_fifo #(vip_dram_req #(CFG_P)) req_fifo;
  // TLM out: scheduled responses
  uvm_analysis_port     #(vip_dram_rsp #(CFG_P)) rsp_port;

  // Storage typedefs derived from CFG_P (class-local, so the whole-image type
  // is per-CFG_P and the public signatures need no separate package alias).
  typedef vip_mem #(vip_dram_types #(CFG_P)::MEM_CFG) mem_t;
  typedef mem_t::mem_get_type_t                       image_t;   // whole-image type

  // Reset surface (see §8). `reset()` is a **task**, not a function (B5):
  // a reset must cancel in-flight forked responses — each sleeps until its
  // scheduled $time — and drain `req_fifo`, neither of which is legal from a
  // function context. The caller either calls the task on `negedge rst_n` or
  // triggers `reset_event`; the consumer task (§7.5) waits on `reset_event`
  // concurrently with its scheduling work and `disable fork`s its pending
  // subtasks the instant reset asserts.
  uvm_event             reset_event;
  task reset();

  // Synchronous backdoor (no timing). Each value is one channel-row word
  // (`vip_dram_types #(CFG_P)::data_t` = DATA_BITS bits = one column access);
  // addresses are row-aligned to the column-access (ROW_BYTES_P) granularity.
  // (Delivered API — simpler than the original queue+beats sketch: single-row
  // write/read, and whole-image dump/load by value rather than memory_get/set.)
  typedef vip_dram_types #(CFG_P)::data_t data_t;
  function void    backdoor_write(longint unsigned addr, data_t data); // one row
  function data_t  backdoor_read (longint unsigned addr);              // one row
  function void    memory_reset();
  function void    memory_randomize(longint unsigned addr_lo = '0,
                                    longint unsigned addr_hi = '1);
  function image_t backdoor_dump();             // whole image, by value
  function void    backdoor_load(image_t img);  // whole image, by value

  // Side-effect-free latency predictor (used by MC + scoreboards). Times in ns.
  function void predict(
    input  vip_dram_req #(CFG_P) req,
    output realtime              first_beat_ready,
    output realtime              last_beat_ready
  );

  // Counters. NOTE (M5): `vip_dram.get_refresh_count()` counts REF requests
  // **executed by the device** (one per VIP_DRAM_OP_REF_E consumed). This is a
  // different object from `vip_mc.get_refresh_count()`, which counts REF
  // **emitted by the controller**. The two are equal under normal operation
  // and diverge only across a reset; tests must always qualify the call with
  // its object (`dram.get_refresh_count()` vs `mc.get_refresh_count()`).
  function int get_page_hit_count();
  function int get_page_miss_count();
  function int get_page_empty_count();
  function int get_refresh_count();
endclass
```

**Device configuration is a class parameter, not package constants.** The
geometry and channel widths are a single packed-struct type `vip_dram_cfg_t`
(in `vip_dram_types_pkg`) used to parameterize the device **and** the neutral
items. A testbench sizes the device per instance; the same `CFG_P` flows into
`vip_dram_req`/`vip_dram_rsp` so item field widths track the device. (This is
the chosen answer to B3's "parameterize vip_dram": rather than fixing the
channel width as a package constant and keeping the items monomorphic, the
width is a parameter — at the cost of consumers sharing the `vip_dram_cfg_t`,
which vip_mc accepts since it already imports `vip_dram_pkg`.)

```sv
// vip_dram_types_pkg.sv
typedef struct packed {
  int ROW_BYTES_P;          // bytes per DRAM column access (BL8) = neutral-TLM beat
  int ADDR_WIDTH_P;         // device byte-address width
  int N_RANKS_P;
  int N_BANK_GROUPS_P;
  int BANKS_PER_BG_P;
  int ROW_BITS_P;
  int COL_BITS_P;
  int DEVICE_WIDTH_P;
  int N_DEVICES_PER_RANK_P;
} vip_dram_cfg_t;

localparam vip_dram_cfg_t VIP_DRAM_CFG_DEFAULT_C = '{   // DDR4 x8, 8 GiB, 64-bit
  ROW_BYTES_P:64, ADDR_WIDTH_P:33, N_RANKS_P:1, N_BANK_GROUPS_P:4, BANKS_PER_BG_P:4,
  ROW_BITS_P:13, COL_BITS_P:10, DEVICE_WIDTH_P:8, N_DEVICES_PER_RANK_P:8 };
// Geometry must sum to ADDR_WIDTH_P (validate() fatals otherwise):
// byte clog2(64)=6 + col 10 + bank clog2(4)=2 + bg clog2(4)=2 + row 13 + rank 0 = 33.

// CFG_P-derived widths + storage descriptor (consumers alias what they need):
class vip_dram_types #(vip_dram_cfg_t CFG_P = VIP_DRAM_CFG_DEFAULT_C);
  localparam int DATA_BITS = 8 * CFG_P.ROW_BYTES_P;   // one column-access word
  localparam int STRB_BITS = CFG_P.ROW_BYTES_P;
  typedef logic [DATA_BITS-1:0] data_t;
  typedef logic [STRB_BITS-1:0] strb_t;
  // all four vip_mem_cfg_t fields set (B4); backing row == one column access:
  localparam vip_mem_cfg_t MEM_CFG = '{ ADDR_WIDTH_P:CFG_P.ADDR_WIDTH_P,
    WDATA_BYTES_P:CFG_P.ROW_BYTES_P, RDATA_BYTES_P:CFG_P.ROW_BYTES_P,
    ROW_BYTES_P:CFG_P.ROW_BYTES_P };
endclass
```

The whole-image backdoor type stays out of the public package namespace: the
device declares it **class-locally** as `image_t` (= `mem_t::mem_get_type_t`
where `mem_t = vip_mem #(vip_dram_types #(CFG_P)::MEM_CFG)`), so it is per-`CFG_P`
and the class-private `vip_mem` nested typedef never leaks into a package
symbol. (If a TB prefers to avoid the whole-image accessors entirely, the
address/beats backdoor pair above already does.)

The caller is responsible for issuing `VIP_DRAM_OP_REF_E` requests at
the right cadence. `vip_dram` does not auto-refresh — if the caller
never sends REF, banks stay live (useful for ideal-timing tests).

### 4.6 Beat granularity & transaction semantics (the contract)

This is the contract M7 / the "transaction-semantics" feedback asked to be
pinned down. It is stated **once** here and mirrored verbatim by `vip_mc`
(§5.6); both VIPs must agree on it.

- **One `vip_dram_req` == one DRAM column burst (BL8).** `req.beats` is the
  number of column accesses, each transferring one channel row
  (`vip_dram_types #(CFG_P)::DATA_BITS` bits = `CFG_P.ROW_BYTES_P` bytes, 64 B at
  the default config). `req.beats` is **not** the AXI4 `awlen+1`/`arlen+1`
  bus-beat count.
- **The MC owns the AXI4→DRAM mapping.** A wide AXI4 burst becomes
  `beats = ceil(total_bytes / CFG_P.ROW_BYTES_P)` column accesses;
  `vip_mc` packs `WDATA_BYTES_P`-wide AXI4 beats into channel-row words and
  applies `wstrb` per byte (§5.6). `vip_dram` never sees AXI4 widths and never
  splits or re-packs — it consumes whole column bursts.
- **Column progression within a request.** Successive column accesses of one
  `vip_dram_req` advance the column index on the **same** open row; they are
  page hits and are spaced by `tCCD_x` (not `tBL` — see §6 / M2). The first
  access pays the row-open cost (`tRCD`/`tRP` as applicable); the rest are
  column-to-column.
- **Per-request vs per-beat timing.** `first_beat_ready_time` is the readiness
  of column access 0; `last_beat_ready_time` is the readiness of column access
  `beats-1`. With `beats == 1` the two are equal (vip_mc must guard its
  per-beat spacing division — vip_mc M10).

**Worked address-decode example** (default LSB-first slice
`[byte][col][bank][bg][row][rank]`, geometry from §5: `byte_in_col=6`,
`col=10`, `bank=2`, `bg=2`, `row=13`, `rank=0`; the six widths sum to
`ADDR_WIDTH_P = 33`):

```text
byte address 0x0004_0840  =  0b 0100_0000_1000_0100_0000
  bit field        width  slice           decoded
  byte_in_col [5:0]   6   0b000000          0   (offset within the 64 B column)
  col        [15:6]  10   0b00_0010_0001   33   (column index: 33<<6 = 0x840)
  bank       [17:16]  2   0b00              0
  bg         [19:18]  2   0b01              1   (bit18 set: 1<<18 = 0x40000)
  row        [32:20] 13   0b0…0             0   (top address bit is 32)
  rank          —     0   —                 0   (n_ranks=1)
→ {rank0, bg1, bank0, row0, col33}   (0x40000 | 0x840 = 0x40840)

A 256 B INCR AXI4 burst (4 × 64 B) from this address occupies col33..col36 of
{rank0,bg1,bank0,row0}: one vip_dram_req with beats=4, all four column accesses
page-hit after the first → tRCD+tCL, then 3 × tCCD_L. (This example stays within
one row.) In the ADDRESS MAP, incrementing past the column span rolls into the
next bank-group (parallelism) and past the row span lands in a new row. Note,
however, that the multi-beat scheduler does NOT detect a row crossing inside a
single request: every beat is modelled as a same-row page hit, so keeping a
request's `beats` within one row is the caller's responsibility (§12 limitations
/ README "Known limitations").
```

---

## 5. Device geometry — the `vip_dram_cfg_t` parameter

Geometry is the **compile-time `CFG_P` parameter** (`vip_dram_cfg_t`, §4), not
runtime config. The default `VIP_DRAM_CFG_DEFAULT_C` matches the most common
DDR4 case (FPGA SODIMM / ×8 chips), which is what densemem's MIG target
effectively models; a TB overrides `CFG_P` to size a different device:

| `vip_dram_cfg_t` field | Default          | Notes                                |
|------------------------|------------------|--------------------------------------|
| `N_RANKS_P`            | 1                |                                      |
| `N_BANK_GROUPS_P`      | 4                | DDR4 standard                        |
| `BANKS_PER_BG_P`       | 4                | 16 banks total per rank              |
| `ROW_BITS_P`           | 13               | 8K rows (sized so the geometry sums to `ADDR_WIDTH_P`) |
| `COL_BITS_P`           | 10               | 1K columns                           |
| `DEVICE_WIDTH_P`       | 8                | ×8 device                            |
| `N_DEVICES_PER_RANK_P` | 8                | 8 × ×8 → 64-bit channel              |
| `ROW_BYTES_P`          | 64               | BL8 payload = neutral-TLM beat width |
| `ADDR_WIDTH_P`         | 33               | byte-address width = `sum(field widths)`; 8 GiB channel |
| **channel data width** | **64-bit (8 B)** | informational: `DEVICE_WIDTH_P * N_DEVICES_PER_RANK_P` |
| **burst length**       | **BL8**          | 8 beats → `ROW_BYTES_P` = **64 B / access** |

`page_policy` is **not** part of `CFG_P` — it is a runtime knob on
`vip_dram_config` (§7.1), default `OPEN_PAGE`.

**Density / tRFC consistency (m4).** The default is an **8 GiB channel**
(`2^ADDR_WIDTH_P = 2^33 B`): eight **8 Gb-density** (1 GiB) ×8 devices ganged to
a 64-bit channel (8 × 8 Gb = 64 Gb = 8 GB). The §6 `tRFC` default is therefore
**350 ns** (JEDEC tRFC1 for 8 Gb DDR4), not the 260 ns figure that belongs to a
4 Gb die. Per-device density and `tRFC` are tied, and that tie is **automatic**:
a half-density (4 Gb) part just drops one `ROW_BITS_P` (→ `ROW_BITS_P=12`,
`ADDR_WIDTH_P=32`, a 4 GiB channel) and `apply_preset()` then derives
`tRFC = 260 ns` from that density (§6 "tRFC density derivation") — no separate
timing edit. `validate()` fatals unless the geometry-field widths sum to
`ADDR_WIDTH_P`, so geometry and capacity cannot silently disagree.

Real-world widths for reference (informs future presets):

- **DDR4 DIMM**: 64-bit (72-bit ECC) channel, BL8 → 64 B/access.
- **DDR5 DIMM**: 2× 32-bit sub-channels, BL16 → 64 B/sub-channel.
- **LPDDR4/5**: 16- or 32-bit per channel.
- **HBM2/3**: 128-bit per channel.

Wider/multi-channel systems are modeled by instantiating multiple
`vip_dram` instances (one per channel or sub-channel) behind one or more
`vip_mc` instances.

---

## 6. Timing parameters & realistic defaults

Defaults target **DDR4-3200 (CL22)**. Stored in nanoseconds and quantized to
whole clock cycles **on demand** (at `schedule()`/`predict()` time) using
`cfg.t_ck` — not cached at `start_of_simulation`, so a mid-sim `cfg.timing`
edit takes effect immediately with no re-elaboration step.

| Param   | Meaning                                            | Default (ns) | DDR4-3200 cycles |
|---------|----------------------------------------------------|--------------|------------------|
| `t_ck`  | DRAM clock period                                  | 0.625        | n/a              |
| `tRCD`  | Row addr → Col addr (ACT → RD/WR)                  | 13.75        | 22               |
| `tRP`   | Row precharge                                      | 13.75        | 22               |
| `tRAS`  | Row active time (min)                              | 32.0         | 52               |
| `tRC`   | Row cycle = tRAS + tRP                             | 45.75        | 74               |
| `tCL`   | CAS read latency                                   | 13.75        | 22               |
| `tWL`   | Write latency (CWL)                                | 10.0         | 16               |
| `tWR`   | Write recovery (last WR data → PRE, same bank)     | 15.0         | 24               |
| `tRTP`  | Read → Precharge, same bank                        | 7.5          | 12               |
| `tCCD_S`| Col-to-col, different bank group                   | 2.5          | 4                |
| `tCCD_L`| Col-to-col, same bank group                        | 5.0          | 8                |
| `tRRD_S`| ACT-ACT, different bank group                      | 3.0          | 5                |
| `tRRD_L`| ACT-ACT, same bank group                           | 4.9          | 8                |
| `tFAW`  | Four-activate window (rank)                        | 21.0         | 34               |
| `tWTR_S`| WR → RD, different bank group                      | 2.5          | 4                |
| `tWTR_L`| WR → RD, same bank group                           | 7.5          | 12               |
| `tRTW`  | RD → WR (controller-derived, see below)            | 7.5 (calc)   | 12 (calc)        |
| `tRFC`  | Refresh cycle (**density-derived**; 8 Gb default)  | 350.0        | 560              |
| `tBL`   | Burst length on bus (BL8)                          | 2.5          | 4                |
| `tREFI` | Average refresh interval **(read-only for vip_mc)**| 7800.0       | 12480            |

`tREFI` is exposed on `vip_dram_config` for **`vip_mc` to read** when it
sets up its refresh timer; `vip_dram` itself never uses it.

**tRTW derivation (M3).** JEDEC does not specify tRTW as a device timing — it
is controller-derived. `vip_dram_config::apply_preset()` computes it (it is
not a free-standing default):

```text
tRTW = tCL + tBL + 2*t_ck - tWL          (read-to-write bus turnaround)
     = 13.75 + 2.5 + 2*0.625 - 10.0      = 7.5 ns  (= 12 cyc @ DDR4-3200)
```

> The exact constant depends on the preset's CL/CWL/BL; the formula above is
> the one `apply_preset()` evaluates per preset so DDR5/LPDDR presets get a
> correct value rather than a hard-coded number. The "12 cyc" table entry is
> the DDR4-3200 evaluation; the authoritative value is whatever the formula
> yields for the active preset.

**tRFC density derivation.** Unlike the AC timings above, `tRFC` scales with the
per-die **density**, not the speed bin — so it is not owned by the speed-bin
preset. `apply_preset()` re-derives it: load the bin's AC timings, compute the
per-die density from the geometry —
`(2^ADDR_WIDTH_P × 8) / (N_DEVICES_PER_RANK_P × N_RANKS_P)` bits — and look up
`vip_dram_trfc_ns(generation, density_gbit)` against the table below. A re-sized
device thus gets the right refresh time automatically; off-table densities clamp
to the **nearest-larger** row (conservative — longer refresh) and `validate()`
warns. The 350 ns §6 default is the DDR4 8 Gb evaluation. A manual
`cfg.timing.tRFC = …` override still wins for odd parts.

**tRFC by generation × density (JEDEC, ns).** The table `vip_dram_trfc_ns()`
encodes. **DDR4 is authoritative** (JESD79-4); the others are the target values
the first-pass code branches refine toward — the code is correct only where it
matches this table.

| Generation | 512 Mb | 1 Gb | 2 Gb | 4 Gb | 8 Gb | 16 Gb | 24/32 Gb | Spec     | Variant         |
|------------|--------|------|------|------|------|-------|----------|----------|-----------------|
| DDR4       | —      | —    | 160  | 260  | 350  | 550   | —        | JESD79-4 | tRFC1 (auth.)   |
| DDR3       | 90     | 110  | 160  | 260  | 350  | —     | —        | JESD79-3 | tRFC            |
| DDR5       | —      | —    | —    | —    | 195  | 295   | 410      | JESD79-5 | tRFC1 (normal)  |
| LPDDR4     | —      | —    | —    | 130  | 180  | 280   | —        | JESD209-4| tRFCab (all-bank)|

Refinement notes (these are what the `// TODO: refine` markers in
`vip_dram_timing_pkg.sv` track):

- **DDR3 4 Gb is 260 ns** (the first-pass code's 300 ns has been corrected to
  match this table; the DDR3 column is now spec-accurate per JESD79-3).
- **DDR5** has a fine-granularity `tRFC2` and a same-bank `tRFCsb`; the table is
  `tRFC1` (normal-mode, all-bank). Refine if a fine-granularity refresh preset is
  ever added.
- **LPDDR4** `tRFCab` (all-bank) is what blocks the rank and is what we model;
  per-bank `tRFCpb` (≈ 4 Gb 60 / 8 Gb 90 / 16 Gb 140 ns) only becomes relevant
  once per-bank refresh is modeled — out of scope for phase 1.
- `vip_dram_trfc_max_gbit(gen)` returns the largest tabulated density per
  generation (DDR4 16, DDR3 8, DDR5/LPDDR4 16) so `validate()` can warn on clamp.

**Reference edge for every timing parameter (M1).** §7.4 mixes
*command-referenced* and *data-end-referenced* constraints, so §6 must state
the reference edge of each:

| Parameter            | Referenced from                              |
|----------------------|----------------------------------------------|
| `tRTP`               | RD **command** (`t_last_rd`)                 |
| `tRTW`               | RD **command** (`t_last_rd`)                 |
| `tCCD_S/L`           | prior CAS **command** (`t_last_rd`/`t_last_wr`)|
| `tWTR_S/L`           | last WR **data** (`t_last_wr_end`)           |
| `tWR`                | last WR **data** (`t_last_wr_end`)           |
| `tRAS`, `tRC`, `tRRD`| ACT **command** (`t_last_act`)               |
| `tRP`                | PRE **command** (`t_last_pre`)               |

tRTP and tRTW are RD-**command**-referenced (JEDEC), so §7.4 applies them to
`t_last_rd` — **not** `t_last_rd_end`, which already includes tCL + tBL and
would overcount by ≈ tCL + tBL.

Presets in `vip_dram_timing_pkg.sv`:

- `VIP_DRAM_PRESET_DDR4_3200_CL22_E`
- `VIP_DRAM_PRESET_DDR4_2400_CL17_E`
- `VIP_DRAM_PRESET_DDR3_1600_CL11_E`
- `VIP_DRAM_PRESET_LPDDR4_3200_E`
- `VIP_DRAM_PRESET_DDR5_4800_E`
- `VIP_DRAM_PRESET_IDEAL_E` (all delays zero — sanity tests)

`vip_dram_config::apply_preset(preset_e)` loads the speed-bin AC timings and
re-derives `tRFC` from the geometry-implied density (above); field overrides are
then free.

---

## 7. Class design

### 7.1 `vip_dram_config` (uvm_object)

Owns **only** runtime device properties (geometry is compile-time `CFG_P`,
§5 — **not** here):

- Timing fields from §6 (incl. `t_ck` and the exposed `tREFI`).
- `vip_dram_addr_map_t addr_map` — bit slicing of the request byte-address
  (its field widths are sized from `CFG_P`'s `ROW_BITS_P`/`COL_BITS_P`/etc.).
- `vip_dram_page_policy_t page_policy`.
- `bool_t enable_bus_contention = TRUE` (channel-level `tBL` spacing).
- `bool_t enable_bank_scoreboard = FALSE` (debug logging).
- `bool_t randomize_mem_on_reset = FALSE`.
- `vip_mem_config mem_cfg` — X-handling / severity of the storage
  primitive `vip_dram` owns (§7.5). This is a **device-storage**
  property, not a bus property: it describes how the DRAM array behaves
  on uninitialized reads and X writes, independent of any controller or
  protocol above it. `vip_dram` is the single owner of this setting; it
  is set by the testbench directly on the `vip_dram` instance's config
  and is **not** sourced from any controller-side config (see vip_mc
  Finding-4 resolution: vip_mc does **not** copy a bus-side `mem_cfg`
  down into `vip_dram_config`).

"No bus fields" means no **protocol** fields — no AXI4/APB/DFI knobs,
no refresh policy, no reorder/QoS. The `vip_mem_config` above governs
the device's own storage array and is in scope precisely because
`vip_dram` owns the `vip_mem`.

Methods: `apply_preset(...)`, `validate()` (sanity: `tRC >= tRAS + tRP`,
`t_ck > 0`, `CFG_P.N_DEVICES_PER_RANK_P * CFG_P.DEVICE_WIDTH_P` is a power of
two, and the geometry-field widths
`clog2(ROW_BYTES_P)+COL_BITS_P+clog2(BANKS_PER_BG_P)+clog2(N_BANK_GROUPS_P)+ROW_BITS_P+clog2(N_RANKS_P)`
sum **exactly** to `CFG_P.ADDR_WIDTH_P` — so the declared interface address
width and the device capacity can never disagree; `uvm_fatal` on violations).
Geometry checks read the compile-time `CFG_P` fields (§4), not runtime config.

### 7.2 `vip_dram_addr_pkg`

A package of pure free functions (mirroring `vip_dram_timing_pkg`; **not** an
`include`d class fragment — these aren't parameterized UVM items), driven by
`cfg.addr_map` (per-field LSB offsets, overridable) and the field WIDTHS implied
by the geometry (`cfg`, fixed). The map types and the `default_addr_map` builder
stay in `vip_dram_types_pkg`; this package imports them.
Default slicing (LSB-first): `[byte][col][bank][bg][row][rank]`
(column-interleaved, row-MSB). The MC can supply its own slicing by overriding
`cfg.addr_map`; widths always track the geometry, so a slice can be reordered but
never resized out of step with the device.

- `vip_dram_decode_addr(addr, cfg, map) → vip_dram_dec_t` — byte-addr →
  `{rank, bg, bank, row, col, byte_in_col}` (the `vip_dram_dec_t` result type
  lives in `vip_dram_types_pkg`; zero-width fields decode to a constant 0).
- `vip_dram_encode_addr(dec, cfg, map) → addr` — the inverse, masking each field
  to its width; round-trips with decode for any in-range decode. Used by the
  scheduler/TB to build an address targeting a chosen `{rank,bg,bank,row,col}`
  (e.g. the §12.3 page-thrash test's alternating-row addresses).
- `vip_dram_bank_index(cfg, dec) → int` — flat per-rank bank id (bg-major,
  bank-minor) the §7.3 bank-state array is indexed by; `vip_dram_banks_per_rank(cfg)`
  gives that array's size.

### 7.3 `vip_dram_bank_state`

Per-bank FSM with states `IDLE`, `ACTIVE`, `REFRESHING`. Tracks:

- open row,
- `t_last_act`, `t_last_rd`, `t_last_rd_end`, `t_last_wr`,
  `t_last_wr_end`, `t_last_pre`,
- pending PRE / pending REF.

**Initial values on reset (Q1).** All timestamp fields are initialized to
`-LARGE` (a value ≤ `-tRC`, effectively −∞) on construction and on
`reset()` — **not** 0. This makes every "`max(now, t_last_* + tXX)`" term in
§7.4 collapse to `now` for the first access to a freshly-reset bank, so the
smoke test (§12.3 #1) sees exactly `arrival_time + tRCD + tCL` with **no**
spurious `tRP` term. In particular `t_last_pre = -LARGE` means the empty-bank
`max(now, t_last_pre + tRP)` reduces to `now` on the first access. (If
`t_last_pre` were 0, the first access would incorrectly add a full `tRP`.)

### 7.4 `vip_dram_scheduler`

Given an incoming `vip_dram_req`, computes
`first_beat_ready_time` / `last_beat_ready_time` from bank state and
timing, then commits the bank state update. Handles all three op types:

- `RD` / `WR`: latency formulas below.
- `REF`: blocks the rank for `tRFC`; sets all banks of the rank to
  `IDLE` (closed) when it completes.

Latency formulas (open-page). `now == $time` at request arrival. tRTP and
tRTW are RD-**command**-referenced (`t_last_rd`), while tWTR/tWR are last-WR-
**data**-referenced (`t_last_wr_end`) — see the §6 reference-edge table (M1):

```text
hit (bank ACTIVE, same row) — column access 0:
  read  : max(now, t_last_rd + tCCD_x, t_last_wr_end + tWTR_x) + tCL
  write : max(now, t_last_wr + tCCD_x, t_last_rd  + tRTW)      + tWL
                                       ^^^^^^^^^^^ RD-command-referenced (M1),
                                                   NOT t_last_rd_end

miss (bank ACTIVE, different row) — column access 0:
  read  : max(now,                       ← (B6) without `now` the result can
              t_last_rd  + tRTP,            precede arrival_time on an idle bank
              t_last_wr_end + tWR,
              t_last_act + tRAS) + tRP + tRCD + tCL
  write : max(now, t_last_rd + tRTP, t_last_wr_end + tWR,
              t_last_act + tRAS) + tRP + tRCD + tWL

empty (bank IDLE) — column access 0:
  read  : max(now, t_last_pre + tRP) + tRCD + tCL
  write : max(now, t_last_pre + tRP) + tRCD + tWL

per-beat (column accesses 1 .. beats-1, all page hits on the now-open row):
  ready[i] = ready[i-1] + tCCD_L      ← DATA spacing is exactly tCCD_L: the
             accesses are same-bank (so same bank group), and CAS latency is
             constant/pipelined, so consecutive DATA words are tCCD_L apart —
             NOT tBL (M2) and NOT another tCL/tWL on top of ready[i-1].
             (§12.3 test #2 pins this: per-access ≈ tCCD_L = 8 cyc, not tBL.)

refresh (REF):
  ready : max(now, t_last_op_on_rank) + tRFC,
          then all banks of rank → IDLE (precharge-all implied).
```

`first_beat_ready_time` is `ready[0]`; `last_beat_ready_time` is
`ready[beats-1]` (equal to `ready[0]` when `beats == 1`).

FAW: rank-level ring of the last 4 ACT times; if
`now - oldest_act < tFAW`, defer the new ACT by
`tFAW - (now - oldest_act)`. If `enable_bus_contention`, the **channel** (one
edge shared by every rank — the DQ bus is channel-wide) also enforces `tBL`
between completed bursts.

**Column spacing & turnaround are rank-level (not per-bank).** The `tCCD_x` and
`tWTR_x`/`tRTW` terms above are applied against rank-level CAS history, not just
the accessed bank's: `tCCD_L`/`tWTR_L` vs the most recent CAS/WR-data to the
**same** bank group, and `tCCD_S`/`tWTR_S` vs the most recent to **any** bank
group (the `_S` term binds only when the prior CAS was to a different bank group,
since `_L >= _S`). This is what makes round-robin-across-bank-groups traffic
`tCCD_S`-limited (§12.3 #4) and a cross-bank write→read pay the bus turnaround.
The per-bank timestamps remain the reference for the precharge path
(`tRTP`/`tWR`/`tRAS`) and REF. (At DDR4-3200 `tCCD_S == tWTR_S == tBL`, so these
coincide numerically — distinguishable only under a preset where they differ.)

**Single source of truth: `predict()` does not duplicate `schedule()` (M9).**
The ~50-line timing computation lives in **one** private helper; `schedule()`
and `predict()` are thin wrappers so the two can never drift:

Both wrappers RETURN a public `result_t` (the two readiness times + the page
classification) by value — no `last_was_*` side-channel members for the caller
to read back:

```sv
// Public result of predict()/schedule().
typedef struct { realtime first, last; bit hit, miss, empty, is_ref; } result_t;

// The ONLY place the formulas above are coded. Pure: reads the live bank/rank
// arrays and cfg.timing, returns ALL it computed in one lat_t struct (the
// timing PLUS the commit data + page classification), mutates nothing. Times
// are realtime ns.
protected function lat_t    compute_latency(input req_t req);
protected function result_t pack(input lat_t r);   // lat_t -> public subset

// Side-effect-free predictor (MC / scoreboard).
function result_t predict(input req_t req);
  return this.pack(this.compute_latency(req));
endfunction

// Scheduler: compute against live state, THEN commit the state update + count.
function result_t schedule(input req_t req);
  lat_t r = this.compute_latency(req);
  this.commit_state(r);                   // the only mutation
  // ... bump n_page_hit/miss/empty/n_ref ...
  return this.pack(r);
endfunction
```

(The device's public `predict(req, output first, output last)` keeps its §4
output-arg signature, forwarding `first`/`last` out of the returned `result_t`.)

If a timing rule changes, it changes in `_compute_latency()` alone; the
scoreboard (which calls `predict()`) and the device (which calls `schedule()`)
stay in lock-step by construction.

**`predict()` usage caveat.** Single-source-of-truth guarantees the *formula*
matches; the *inputs* must match too. `compute_latency()` reads `$realtime` and
the current committed bank/rank state — **not** `req.arrival_time` — so a
scoreboard must call `predict()` at the instant the request is issued, and (for
back-to-back traffic) in the same order the device will `schedule()` them.
Calling `predict()` at a later `$realtime`, or after another request has
committed state, yields a different (correct-for-that-moment) number.

### 7.5 `vip_dram` (uvm_component)

- Owns `vip_dram_config`, `vip_dram_scheduler`, `vip_mem`.
- Consumer task: drain `req_fifo` → `scheduler.schedule(req)` → perform
  the actual `vip_mem` read/write at the scheduled time → publish
  `vip_dram_rsp` on `rsp_port`. Each scheduled response runs in a forked
  subprocess that sleeps until its computed `*_ready_time`.
- **Reset-safe forking (B5).** The consumer wraps its per-request work so a
  reset cancels pending responses instead of letting them fire stale data:

  ```sv
  task run_consumer();
    forever begin
      fork
        begin : work
          forever begin
            vip_dram_req req; req_fifo.get(req);
            schedule(req, ...);
            fork drive_response_at_ready_time(req); join_none  // delayed rsp
          end
        end
        begin : on_reset
          reset_event.wait_ptrigger();  // PERSISTENT: catches a reset issued
        end                             // before this arms (e.g. at time 0)
      join_any
      disable fork;        // kills `work` AND every delayed response subprocess
      flush_in_flight();   // empty req_fifo, reset bank state (see reset())
      reset_event.reset(); // clear the persistent trigger so the next loop blocks
    end
  endtask
  ```

  No delayed `rsp_port.write()` can fire after reset, so the scoreboard never
  sees stale beats. `reset()` is the task that triggers `reset_event` and
  waits for the drain to complete. on_reset uses **wait_ptrigger** (persistent),
  not wait_trigger, so a `reset()` issued before the consumer has armed its wait
  — e.g. at time 0 — is caught rather than lost to a missed edge; the persistent
  state is cleared after each drain so the loop blocks again instead of spinning.
- Provides backdoor API (§4) and `predict()` delegate.
- **Does not** fork a refresh loop. REF arrives as a request like any
  other.

The component has no virtual interface, no clocking blocks, no bus
dependencies. It can run in any UVM env with or without `vip_mc`.

---

## 8. Reset & lifecycle

- `vip_dram` exposes a `reset()` **task** and a `reset_event` `uvm_event`
  (both in the §4 public interface). `reset()` is a task — not a function —
  because it must cancel in-flight forked responses and block until they are
  drained (B5); a function cannot `disable fork` another process's pending
  work or yield time. The two surfaces are equivalent entry points:
  - `reset()` — triggers `reset_event`, then waits for the consumer's drain.
  - `reset_event` — the consumer task waits on it concurrently (§7.5) and
    `disable fork`s its pending delayed responses the instant it asserts.
- On reset: the consumer's `disable fork` kills every scheduled-but-not-yet-
  fired response, `req_fifo` is emptied, all bank states → `IDLE`, the FAW
  ring is cleared, and all `t_last_*` timestamps return to `-LARGE` (§7.3,
  Q1). No `rsp_port.write()` from before the reset can fire afterward.
- No clock signal is required — timing is computed against `$time`.
- `vip_mem` may be re-randomized on reset
  (`cfg.randomize_mem_on_reset`).
- **Manager-observable contract** (mirrors vip_mc §9): because the device
  discards every in-flight response on reset, an upstream MC must surface that
  as "no completion arrives for anything outstanding at reset." The MC is then
  responsible for the AXI4-visible behavior (no B/R after reset, partial
  writes discarded, manager reissues) — see vip_mc §9.

---

## 9. Verification of the model itself

Self-checking tests in `submodules/vip/examples/vip_dram/`. They drive
`vip_dram` directly via its TLM API — no MC, no AXI4, no bus.

1. **Single-RD latency** — push one `vip_dram_req` for an IDLE bank;
   `first_beat_ready_time == arrival_time + tRCD + tCL` **exactly** (no `tRP`
   term — `t_last_pre` starts at `-LARGE`, §7.3 / Q1).
2. **Page-hit speedup** — 64 single-beat requests to consecutive columns of one
   open row (the first opens the bank, the other 63 are page hits); per-access
   spacing settles to ~`tCCD_L` (8 cyc, M2), **not** `tBL`, and the device counts
   1 empty + 63 hits. Counters tally one event PER REQUEST, not per column
   access — a single `beats = 64` request would bump exactly one counter. (To
   observe `tCCD_S`-limited ≈ `tBL` throughput, spread the accesses across bank
   groups — that is test #4, `tc_dram_bank_parallel`.)
3. **Page miss** — alternating-row reads same bank cost
   `tRP + tRCD + tCL` each (the `tRTP`/`tRAS`/`tWR` inner terms gate the PRE
   but are typically already satisfied between misses).
4. **FAW** — 4 back-to-back ACTs to different banks, then a 5th: the 5th ACT
   is deferred **until `oldest_act + tFAW`** (m5), i.e. its observed time is
   `t_first_act + tFAW` (within 1 cyc) only when the 4 prior ACTs are issued in
   one cycle — the test issues them back-to-back to make that hold.
5. **REF** — REF arrives, next access to that rank waits at most `tRFC`.
6. **Backdoor** — `backdoor_write()` followed by a frontdoor RD
   returns the pre-seeded data with full timing.
7. **WSTRB partial write (Q2)** — write a column access with a non-all-ones
   `wstrb`, read it back, and verify the **unmasked** bytes hold the new data
   while the masked bytes retain their prior value (exercises the `vip_mem`
   `wr_be` byte-enable path).
8. **Preset validation** — every preset passes `cfg.validate()`.

These are the contract tests for the device model. Any future MC bug
shows up as a mismatch between the MC's bus output and the predictor —
but the predictor itself is already proven here.

---

## 10. Open questions / decisions for later

1. **Page-hit hints to the MC** — does `vip_mc` query `predict()` to
   plan reorders, or maintain its own shadow bank state? Lean:
   `predict()` is good enough; shadow only if perf demands it.
2. **Multi-channel / multi-rank** — multiple `vip_dram` instances behind
   one `vip_mc`, vs. a single `vip_dram` with `n_ranks > 1`. The former
   is cleaner for HBM-style stacks.
3. **Closed-page / `ADAPTIVE` policy** — auto-tune by row-hit rate?
4. **DPI golden model** — there is a `dpi_sc2` neighbor; should
   `vip_dram` also expose a C reference?
5. **DFI-level face** — when it becomes worth verifying MC RTL
   command-by-command, add a sibling adapter that translates DFI →
   neutral TLM. The device itself doesn't change.

### 10.1 Feature roadmap (Tier 1 / Tier 2)

The future-work axis that matters: does an idea fit the **current abstraction**
(neutral-TLM device + AXI4↔TLM controller, **no new interface**), or does it
need a **new lower-level interface** (a JEDEC-command / DFI / pin-level face)? A
DDR5/GDDR6/etc. timing *preset* is **not** protocol support. None of the below
is a first-cut feature — it is the durable roadmap, folded in from the prior
ideas/feedback notes (the source inventory was a commercial full-stack
DDR5/GDDR6 VIP feature list) so it lives with the plan.

**Tier 1 — fits the current abstraction (phase-2 refinements, no new interface):**

- **Protocol-family presets & topology** — DDR5 DIMM variants
  (RDIMM/MRDIMM/CSODIMM/UDIMM/SODIMM), GDDR6, LPDDR5, HBM, and the older
  DDR3/DDR2 families as additional **timing presets + topology variants /
  companion adapters** — explicitly *not* command-level support.
- **Sub-channel / pseudo-channel / multi-channel** — DDR5 dual sub-channel and
  GDDR6 pseudo-channel modeled as multiple `vip_dram` instances behind a
  sub-channel-aware address-map policy in `vip_mc` (channel partitioning is a
  controller concern — see vip_mc §11).
- **Refresh variants** — fine-granularity (FGR) and per-bank
  (REFpb/REFp2b) refresh as **additional neutral-TLM REF ops** (the device
  already models explicit REF, §7.4). Self-refresh / power-down / refresh-entry
  *sequencing* are Tier 2 (power-state/command behaviors).
- **Response realism & observability** — row-hit rate, effective
  bandwidth/utilization, and per-bank-group occupancy layered on the existing
  hit/miss/empty counters; request-lifecycle timestamps
  (`req_consumed_time` / `rsp_fired_time`) plus a `predict()`-vs-actual
  page-hit-accuracy counter (doubles as FR-FCFS readiness instrumentation for
  vip_mc); a `update_timing_preset()` for dynamic mid-sim retune (today timing
  is cached at start-of-sim — §6). **Caveat:** real DFS is an MRW + retraining
  command sequence; `update_timing_preset()` is a *behavioral approximation* and
  must say so.
- **(GDDR6) EDC** — a light, response-affecting data-path check, modellable as
  an optional parity/flag on read data for GDDR6 presets (distinct from
  multi-bit ECC + `SLVERR`, which is Tier 2).
- **Debug / trace** — optional CMD/data trace emission and spec-referenced
  error messages (expected vs observed). Additive; no interface change.

**Tier 2 — needs a JEDEC-command / DFI / pin-level face (defer hard):**

- Mode registers + MR programming; full mandatory-command catalogs.
- Trainings: read/write leveling, CA/CS, DCA/DCS, QCA/QCS, MRD/MWD/DWL/MRE.
- CRC / parity / DBI / CABI / scrambler / PRBS / boundary scan.
- DIMM register/buffer devices: RCD / MRCD / MDB / CKD; ODT, MPC.
- Init flow, frequency change, power-state sequencing; self-refresh / power-down.
- Pin / electrical: DQS/DQ noise & jitter, fly-by / board / propagation delay,
  WCK2CK, custom preambles & read-DQS offset, clock-stop, PLL modes.
- DFI monitor; pin-level debug ports & timing checks.

Until that lower-level face exists, the detailed bank/timing model is the
*means* to realistic responses — **not** a claim of bit/cycle-exact fidelity.
Bus-level probabilistic fault injection is **excluded by design** (a real device
is not failed by a die roll; data-integrity faults are physical — device/ECC
layer, vip_mc §11 "ECC and error modeling").

---

## 11. Implementation order

1. `vip_dram_types_pkg.sv`, `vip_dram_timing_pkg.sv` (presets).
2. `vip_dram_req.sv`, `vip_dram_rsp.sv`.
3. `vip_dram_config.sv` + `apply_preset()` + `validate()`.
4. `vip_dram_addr_pkg.sv` (address-map decode/encode functions).
5. `vip_dram_bank_state.sv` + `vip_dram_scheduler.sv` (incl. `predict()`).
6. `vip_dram.sv` (consumer task, backdoor API).
7. Contract tests §9 (examples/vip_dram).
8. README, `.svh`, `yml/compile.yml`.

Then move to `vip_mc/IMPLEMENTATION_PLAN.md` (separate sibling VIP):
AXI4 face, command queue, refresh scheduler, address mapping policy,
optional FR-FCFS — wired to `vip_dram` over the neutral TLM API.

---

## 12. Example testbench (device-only)

Lives in `submodules/vip/examples/vip_dram/`. Drives the device directly
over its TLM API — no manager, no MC, no AXI4. The full system TB
(manager → `vip_mc` → `vip_dram`) belongs to `vip_mc` and lives in
`submodules/vip/examples/vip_mc/`.

### 12.1 Directory layout

```text
examples/vip_dram/
├── tb/
│   ├── tb.svh
│   ├── dram_tb_pkg.sv
│   ├── dram_tb_top.sv                  (no clk/rst — purely TLM)
│   ├── dram_env.sv                     (vip_dram + a tiny TLM driver)
│   ├── dram_driver.sv                  (uvm_component that pushes vip_dram_req)
│   └── dram_scoreboard.sv              (predictor-vs-observed)
├── tc/
│   ├── dram_tc_pkg.sv
│   ├── dram_base_test.sv
│   ├── tc_dram_smoke.sv
│   ├── tc_dram_page_hit_streak.sv
│   ├── tc_dram_page_thrash.sv
│   ├── tc_dram_bank_parallel.sv
│   ├── tc_dram_wr_rd_turnaround.sv
│   ├── tc_dram_faw_stress.sv
│   ├── tc_dram_refresh_explicit.sv
│   ├── tc_dram_writes_then_reads.sv
│   ├── tc_dram_backdoor_preload.sv
│   ├── tc_dram_partial_write.sv
│   ├── tc_dram_reset_recovery.sv
│   ├── tc_dram_preset_sweep.sv
│   └── tc_dram_ideal_zero_latency.sv
├── rundir/
├── scripts/compile.sh
└── yml/compile.yml
```

### 12.2 What the scoreboard checks

For every `vip_dram_req` issued, the driver records `arrival_time` and
calls `vip_dram.predict(req, ...)` to compute expected first/last beat
times. The scoreboard compares against the actual `vip_dram_rsp` —
mismatches outside a 1-cycle tolerance are `uvm_error`. Data integrity
checks are straightforward: write + read + compare against `vip_mem`.

### 12.3 Test cases

| #  | TC name                       | What it stresses                                                                                |
|----|-------------------------------|-------------------------------------------------------------------------------------------------|
| 1  | `tc_dram_smoke`               | One write, one read, same row. Latency is `tRCD+tCL` / `tRCD+tWL` **exactly** (no `tRP`, Q1); data round-trip. |
| 2  | `tc_dram_page_hit_streak`     | 64 single-beat reads to consecutive cols of one row (1 empty + 63 hits). Per-access ≈ `tCCD_L` (8 cyc, **not** `tBL`, M2). Hit counter == 63 (one event per request). |
| 3  | `tc_dram_page_thrash`         | Alternating rows same bank. Each costs ≈ `tRP+tRCD+tCL`. Page-miss counter increments.          |
| 4  | `tc_dram_bank_parallel`       | Round-robin across bank groups → `tCCD_S`-limited (≈ `tBL`) throughput, not `tRCD`-limited.     |
| 5  | `tc_dram_faw_stress`          | 4 back-to-back ACTs to different banks, then a 5th; 5th observed at `t_first_act + tFAW` ±1 cyc (m5). |
| 6  | `tc_dram_refresh_explicit`    | Driver issues REF after some traffic; next access to that rank waits at most `tRFC`.            |
| 7  | `tc_dram_writes_then_reads`   | Pattern across many rows/banks; read-back data integrity + reasonable latency mix.              |
| 8  | `tc_dram_backdoor_preload`    | `backdoor_write()` seeds memory; frontdoor RD returns it.                                       |
| 9  | `tc_dram_partial_write`       | WR with non-all-ones `wstrb`, then RD-back: unmasked bytes updated, masked bytes preserved (Q2). |
| 10 | `tc_dram_reset_recovery`      | Mid-flight reset — bank state, FAW ring, in-flight req queue, forked responses must clear cleanly. |
| 11 | `tc_dram_preset_sweep`        | Run `tc_dram_smoke` once per preset (DDR3/DDR4/LPDDR4/DDR5/IDEAL).                              |
| 12 | `tc_dram_ideal_zero_latency`  | `PRESET_IDEAL_E` collapses to zero latency — sanity regression.                                 |
| 13 | `tc_dram_wr_rd_turnaround`    | Back-to-back WR→RD and RD→WR pairs pin the bus-turnaround bubbles: `tWTR_L` (same BG) / `tWTR_S` (cross BG) off the write data end, and derived `tRTW` off the read CAS. |

### 12.4 Running

`scripts/compile.sh` invokes the project's standard sim flow;
`yml/compile.yml` orders files:

1. `vip_memory_pkg`, `bool_pkg`
2. `vip_dram_types_pkg`, `vip_dram_timing_pkg`, `vip_dram_addr_pkg`, then
   `vip_dram_pkg` (the umbrella, which imports the three above and `include`s the
   parameterized class items)
3. `dram_tb_pkg`
4. `dram_tc_pkg`
5. `dram_tb_top` last

A test is picked with `+UVM_TESTNAME=tc_dram_smoke`.
