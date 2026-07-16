# DRAM Primer for `vip_dram`

This primer gives the DRAM background needed to read
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md). It is intentionally not a
JEDEC reference. It explains the mental model behind the plan: hierarchy,
pages, bank state, bursts, timing names, refresh, and the split between a memory
controller and a DRAM device.

`vip_dram` is a behavioral DDR device model. It does not model pins or mode
registers; it models the timing consequences of DRAM structure well enough for a
controller VIP and a scoreboard to see believable latency.

---

## 1. The Big Picture

DRAM is not a flat array that answers every read in one fixed delay. A request
travels through a hierarchy:

```text
system byte address
  |
  v
+---------+   +------+   +------+   +------------+   +------+   +------+   +------+
| channel |-->| rank |-->| bank |-->| row buffer |-->| col  |-->| beat |-->| byte |
+---------+   +------+   +------+   +------------+   +------+   +------+   +------+
```

The important idea is the **row buffer**. Each bank can have one row open. If a
request hits that open row, the DRAM can issue a relatively quick column access.
If it needs a different row in the same bank, the old row must be closed and the
new row opened first.

That gives the three page classifications used throughout the plan:

| State at request arrival | Meaning | Cost shape |
|--------------------------|---------|------------|
| **empty** | Bank is idle/precharged; no row is open. | Open the row, then access the column. |
| **hit** | The target row is already open. | Access the column directly. |
| **miss** | A different row is open in the target bank. | Close old row, open new row, then access column. |

The implementation plan is mostly about modeling those costs and the global
constraints that prevent too many row opens, column accesses, or bus turnarounds
from happening too close together.

---

## 2. Controller Versus Device

A real memory system has at least two conceptual pieces:

```text
CPU / DMA / testbench
  |
  | AXI4, native bus, or another host protocol
  v
+-------------------+       DDR commands / pins       +------------------+
| memory controller | -------------------------------> | DRAM device(s)   |
|                   | <------------------------------- |                  |
+-------------------+                                  +------------------+
```

The **memory controller** decides policy:

- accept AXI4 or another host protocol,
- split and pack host bursts into DRAM accesses,
- map system addresses to channels/ranks/banks/rows/columns,
- reorder requests for performance,
- schedule refresh commands,
- choose when to keep rows open or close them.

The **DRAM device** enforces physics:

- which row is currently open in each bank,
- how long it takes to activate, read, write, precharge, and refresh,
- how close commands may be placed,
- when data is ready.

`vip_dram` models the second half. It intentionally leaves the first half to a
future `vip_mc` or to a direct test driver.

```text
[manager VIP / TB] -- AXI4 --> [vip_mc] -- neutral TLM --> [vip_dram] --> vip_mem
                                                   ^
                                                   |
                                      device-only tests may drive here
```

This is why the plan says `vip_dram` is **protocol-agnostic** and
**controller-agnostic**. It does not know AXI4. It receives already-translated
neutral requests: read, write, or refresh.

---

## 3. DRAM Hierarchy

### Channel

A channel is the data path controlled by one memory controller interface. A
typical DDR4 non-ECC channel is 64 data bits wide. Several DRAM chips are wired
in parallel to provide that width.

For example, a 64-bit channel built from x8 devices:

```text
one 64-bit rank, built from eight x8 devices

             data bit lanes
          63                                      0
          |                                       |
          v                                       v
       +------+ +------+ +------+       +------+ +------+
       | x8   | | x8   | | x8   |  ...  | x8   | | x8   |
       | chip | | chip | | chip |       | chip | | chip |
       +------+ +------+ +------+       +------+ +------+
          \        \        \              \        \
           +--------+--------+--------------+--------+--> 64-bit channel
```

All devices in the rank see the same command/address. Each chip contributes its
slice of the data word.

In `vip_dram`, the default geometry is:

| Concept | Default |
|---------|---------|
| Device width | x8 |
| Devices per rank | 8 |
| Channel width | 64 bits |
| Burst length | BL8 |
| Payload per column access | 64 bytes |

### Rank

A rank is a group of devices that respond together to one chip-select. A DIMM
can have one or more ranks. Only one rank drives the channel data bus at a time,
but ranks can have independent internal bank state.

`vip_dram` supports `N_RANKS_P`, but the default is one rank.

### Bank Group And Bank

A bank is an independently activatable memory array with its own row buffer.
DDR4 introduced bank groups, which make some same-group timing constraints
longer than different-group constraints.

```text
rank
 |
 +-- bank group 0
 |    +-- bank 0  [one row buffer]
 |    +-- bank 1  [one row buffer]
 |    +-- bank 2  [one row buffer]
 |    +-- bank 3  [one row buffer]
 |
 +-- bank group 1
 |    +-- bank 0  [one row buffer]
 |    +-- bank 1  [one row buffer]
 |    +-- bank 2  [one row buffer]
 |    +-- bank 3  [one row buffer]
 |
 +-- ...
```

The default `vip_dram` geometry has 4 bank groups with 4 banks per group, for
16 banks per rank.

### Row

A row is a large internal line of memory cells inside one bank. Before data in a
row can be read or written, the row must be activated into the bank's row
buffer.

```text
bank
 |
 +-- rows in the cell array
 |     row 0
 |     row 1
 |     row 2
 |     ...
 |
 +-- row buffer / sense amps
       holds exactly one activated row at a time
```

The plan often calls an open row a **page**. A page hit is just a row-buffer hit.

### Column

After a row is open, a column command selects a slice of that row and transfers a
burst of data. For DDR4 BL8 on a 64-bit channel, one column access transfers:

```text
64-bit data bus * 8 burst beats = 512 bits = 64 bytes
```

In `vip_dram`, this 64-byte column access is the neutral request beat at the
default geometry.

---

## 4. The Three Basic Row Operations

DRAM command names vary by abstraction level, but the basic sequence is:

| Command | Plain English | Effect |
|---------|---------------|--------|
| `ACT` | Activate | Open a row into the row buffer. |
| `RD` / `WR` | Column read/write | Access a column burst from the open row. |
| `PRE` | Precharge | Close the open row and return the bank to idle. |
| `REF` | Refresh | Restore charge in a rank; modelled as blocking the rank and closing banks. |

### Empty-Bank Read

If the bank is idle, first open the row, then issue a read:

```text
time -->

request arrives
  |
  v
  ACT row R             RD col C                 data ready
  |---------------------|------------------------|
        tRCD                    tCL

latency shape: tRCD + tCL
```

For a write, replace `tCL` with `tWL`:

```text
ACT row R             WR col C                 write data accepted
|---------------------|------------------------|
      tRCD                    tWL
```

This is why the smoke tests expect the first access to a fresh bank to cost
`tRCD + tCL` for a read or `tRCD + tWL` for a write. It should not pay `tRP`,
because there was no previously open row to close.

### Page Hit

If the target row is already open, no activate is needed:

```text
bank already has row R open

request for row R, col C
  |
  v
  RD col C                 data ready
  |------------------------|
             tCL
```

Back-to-back page hits are often limited by column-to-column spacing (`tCCD`)
rather than full row-open latency.

### Page Miss

If the bank has a different row open, the old row must be closed first:

```text
bank has row A open, request wants row B

request arrives
  |
  v
  PRE row A             ACT row B             RD col C             data ready
  |---------------------|---------------------|--------------------|
          tRP                   tRCD                  tCL

latency shape: tRP + tRCD + tCL
```

Real rules also require the old row to have been active long enough (`tRAS`) and
require enough time after recent reads/writes before precharge (`tRTP`, `tWR`).
The implementation plan's formulas include those gates.

---

## 5. Bank State Machine

For the model, a bank is mostly this:

```text
                       ACT(row)
                 +----------------+
                 |                v
             +--------+       +---------+
             | IDLE   |       | ACTIVE  |
             | no row |       | row=N   |
             +--------+       +---------+
                 ^                |
                 |                |
                 +----------------+
                      PRE / REF
```

`vip_dram_bank_state` stores:

- the state (`IDLE`, `ACTIVE`, `REFRESHING`),
- the currently open row,
- timestamps of recent ACT/RD/WR/PRE events.

Those timestamps are what make the timing formulas possible. A new request is
scheduled by asking, "What is the earliest time this command is legal, given the
current state and timestamp history?"

The plan initializes timestamps to a very negative value, not zero. That makes
the first access after reset behave like the past is infinitely far away:

```text
max(now, t_last_pre + tRP) = now
```

This prevents a fresh bank from accidentally paying a precharge delay that never
happened.

---

## 6. Bursts And `vip_dram_req.beats`

The implementation plan uses the word **beat** at the neutral TLM level, not at
the AXI4 level.

In the default DDR4-style geometry:

```text
one DRAM column access

        DDR data bus transfers BL8

        beat0 beat1 beat2 beat3 beat4 beat5 beat6 beat7
DQ[63:0]  8 B   8 B   8 B   8 B   8 B   8 B   8 B   8 B
          ------------------------------------------------
                         64 B total
```

So, in `vip_dram`:

```text
req.beats = number of DRAM column accesses
          = number of 64 B payload chunks at the default geometry
```

This is not the same as `AXI awlen+1` or `arlen+1`. The memory controller is
responsible for packing host bus beats into DRAM column accesses before it sends
requests to `vip_dram`.

Example:

```text
AXI burst: 16 beats * 16 bytes = 256 bytes

default vip_dram column access: 64 bytes

vip_dram_req.beats = 256 / 64 = 4
```

The plan assumes successive `beats` in one `vip_dram_req` advance columns within
the same open row. The first beat may pay the row-open cost; the later beats are
modeled as page hits spaced by `tCCD_L`.

```text
one req, beats=4, same row

ready[0] = row-open cost + CAS latency
ready[1] = ready[0] + tCCD_L
ready[2] = ready[1] + tCCD_L
ready[3] = ready[2] + tCCD_L
```

Important limitation from the plan: a single multi-beat request is expected to
stay within one row. The scheduler does not split one request across row
boundaries internally.

---

## 7. Address Mapping

A byte address must be decoded into DRAM location fields:

```text
{rank, bank group, bank, row, column, byte_in_column}
```

The default `vip_dram` map is LSB-first:

```text
low address bits                                              high address bits

+-------------+----------+------+------------+------+------+
| byte offset | column   | bank | bank group | row  | rank |
+-------------+----------+------+------------+------+------+
```

With the default geometry:

```text
ROW_BYTES_P        = 64 bytes per column access -> byte offset width = 6 bits
COL_BITS_P         = 10
BANKS_PER_BG_P     = 4  -> bank width = 2 bits
N_BANK_GROUPS_P    = 4  -> bank-group width = 2 bits
ROW_BITS_P         = 13
N_RANKS_P          = 1  -> rank width = 0 bits

total address width = 6 + 10 + 2 + 2 + 13 + 0 = 33 bits
```

ASCII bit layout:

```text
bit index:
  32                       20 19 18 17 16 15          6 5      0
  +--------------------------+-----+-----+--------------+--------+
  | row[12:0]                | bg  |bank | col[9:0]     | byte   |
  +--------------------------+-----+-----+--------------+--------+
```

The implementation separates **field widths** from **field positions**:

- widths come from the compile-time geometry (`CFG_P`),
- positions come from `cfg.addr_map`,
- the map may reorder fields, but it cannot change the size of the device.

That is why the plan has a standalone `vip_dram_addr_pkg`: address decoding is a
pure function over geometry plus a map.

---

## 8. Timing Names

Most DRAM timing names are "minimum time from event A to event B." The plan
stores timings in nanoseconds and quantizes them to cycles using `t_ck`.

The table below is a reader's guide to the names used in the plan.

| Name | Mental model | Reference edge |
|------|--------------|----------------|
| `t_ck` | DRAM clock period used for cycle quantization. | Clock period, not a command gap by itself. |
| `tRCD` | Row-to-column delay. After `ACT`, wait before `RD`/`WR`. | ACT command. |
| `tCL` | Read CAS latency. After `RD`, wait for read data. | RD command. |
| `tWL` | Write latency. After `WR`, wait to place write data. | WR command. |
| `tRP` | Precharge time. After `PRE`, wait before next `ACT` to that bank. | PRE command. |
| `tRAS` | Minimum row active time. Row must stay open this long before precharge. | ACT command. |
| `tRC` | Row cycle time, roughly `tRAS + tRP`. | ACT-to-ACT same bank. |
| `tRTP` | Read-to-precharge. Wait after a read before closing that row. | RD command. |
| `tWR` | Write recovery. Wait after write data before precharge. | End of WR data. |
| `tCCD_S/L` | Column-to-column delay. `_S` for different bank group, `_L` for same bank group. | Prior CAS command. |
| `tRRD_S/L` | Activate-to-activate delay across banks. `_S` different bank group, `_L` same bank group. | Prior ACT command. |
| `tFAW` | Four-activate window. Prevents too many ACTs in a short rank-level window. | Last four ACT commands. |
| `tWTR_S/L` | Write-to-read turnaround. Wait after write data before read. | End of WR data. |
| `tRTW` | Read-to-write turnaround. Controller-derived bus turnaround. | RD command in this model. |
| `tBL` | Burst length bus occupancy. BL8 consumes several cycles on the data bus. | Data burst. |
| `tRFC` | Refresh cycle time. Rank is unavailable during refresh. | REF command. |
| `tREFI` | Average refresh interval. Controller uses this to decide when to send REF. | Refresh policy, not used by `vip_dram` scheduling. |

### Why `_S` And `_L` Exist

DDR4 bank groups allow more parallelism across different groups. Some gaps are
shorter when consecutive commands touch different bank groups and longer when
they touch the same bank group:

```text
same bank group       -> use _L ("long")
different bank group  -> use _S ("short")
```

This is why a test that round-robins across bank groups can see better
throughput than one that repeatedly hits one bank group.

---

## 9. Timing As Earliest-Legal-Time Math

The scheduler can be understood as a set of "not before" constraints. For every
request, compute the earliest legal time for the next needed command:

```text
earliest = max(
  request_arrival_time,
  constraint_from_this_bank,
  constraint_from_this_bank_group,
  constraint_from_rank,
  constraint_from_shared_data_bus
)
```

For an empty-bank read, the shape is simple:

```text
ACT may issue no earlier than:
  max(now, rank/bank-group ACT constraints, FAW constraints)

RD may issue no earlier than:
  ACT_time + tRCD

data ready:
  RD_time + tCL
```

For a page miss, more constraints appear:

```text
PRE may issue no earlier than:
  max(now,
      last ACT + tRAS,
      last RD  + tRTP,
      last WR data end + tWR)

ACT new row:
  PRE_time + tRP, also gated by tRRD/tFAW rank constraints

RD/WR:
  ACT_time + tRCD
```

The implementation plan's formulas are exact for the model. This primer's
purpose is to make the terms readable before you inspect those formulas.

---

## 10. FAW: The Four-Activate Window

Opening a row consumes internal power. DRAM therefore limits how many activate
commands can occur in a rolling window. `tFAW` means: within any `tFAW` window,
only four ACT commands may issue per rank.

```text
time -->

ACT0     ACT1     ACT2     ACT3     ACT4?
 |        |        |        |        |
 +-----------------------------------+
              tFAW window

If ACT4 would be the 5th ACT inside the window, delay it until:

  ACT0 + tFAW
```

`vip_dram_scheduler` models this with a rank-level ring containing the last four
ACT times. This is why the `tc_dram_faw_stress` test issues several accesses to
closed banks back-to-back: each one requires ACT, and the fifth one should be
held until the oldest ACT exits the window.

---

## 11. Refresh

DRAM cells store charge, and charge leaks. Rows must be refreshed periodically.

Two timing names matter:

| Name | Meaning |
|------|---------|
| `tREFI` | Average interval at which the controller should issue refresh. |
| `tRFC` | Time the DRAM is busy executing a refresh. |

`vip_dram` deliberately does not schedule refresh by itself. The controller (or
a direct test) sends an explicit `VIP_DRAM_OP_REF_E` request.

In this model, REF:

```text
request REF(rank)
  |
  v
rank unavailable for tRFC
  |
  v
all banks in that rank return to IDLE
```

That "all banks return to IDLE" behavior is equivalent to a precharge-all for
the level of abstraction used here. After refresh, the next access to any bank in
the rank is an **empty** access, not a page hit.

`tRFC` depends strongly on DRAM density. Larger dies need longer refresh time.
That is why the plan derives `tRFC` from geometry-implied per-die density rather
than treating it as just another speed-bin number.

---

## 12. Open-Page Versus Closed-Page Policy

A controller can choose what to do after a column access:

```text
open-page policy:
  keep the row open
  -> next access to same row is fast
  -> next access to different row pays a miss

closed-page policy:
  close the row after the access
  -> next access is usually empty
  -> avoids future miss penalty if locality is poor
```

The current `vip_dram` plan includes page-policy enums, but the central modeled
behavior is open-page. That is enough to exercise page hits, misses, row
thrashing, and bank parallelism.

---

## 13. What `predict()` Means

`vip_dram` has two ways to ask the timing core a question:

```text
predict(req)   -> compute timing from current state, mutate nothing
schedule(req)  -> compute timing from current state, then commit state changes
```

Both use the same underlying latency computation so a scoreboard and the device
do not drift apart.

The caveat is state and time. `predict()` answers "what would happen if this
request arrived now, given the current bank state?" If another request commits
before the real request is scheduled, the answer can change.

This is why the device-only testbench uses two styles:

- single-outstanding checked requests: call `predict()` at issue time, then
  compare the actual response,
- back-to-back traffic tests: send a stream and check relationships between
  responses, such as `tCCD_L`, `tCCD_S`, or `tFAW` spacing.

---

## 14. Mapping The Primer To `vip_dram` Files

| Primer concept | Implementation object |
|----------------|-----------------------|
| Geometry: ranks, bank groups, banks, rows, columns | `vip_dram_cfg_t` in `vip_dram_types_pkg.sv` |
| Data width derived from geometry | `vip_dram_types #(CFG_P)` |
| Address slicing | `vip_dram_addr_pkg.sv` |
| Runtime timing and policy | `vip_dram_config.sv` |
| Open row and command history per bank | `vip_dram_bank_state.sv` |
| Page hit/miss/empty, timing formulas, FAW, REF | `vip_dram_scheduler.sv` |
| TLM request fields | `vip_dram_req.sv` |
| TLM response fields | `vip_dram_rsp.sv` |
| Consumer task, delayed responses, reset cancellation, storage | `vip_dram.sv` |
| Backing memory array | `vip_mem` submodule |

The most important file-to-concept connection is:

```text
vip_dram_req
  -> decode address
  -> inspect bank state
  -> compute timing
  -> commit bank/rank state
  -> perform vip_mem access at ready time
  -> publish vip_dram_rsp
```

---

## 15. Reading Guide For `IMPLEMENTATION_PLAN.md`

Read the implementation plan in this order if the DRAM terminology is new:

1. **Scope and architecture**: identify the boundary between `vip_mc` and
   `vip_dram`.
2. **Neutral request/response API**: understand that `beats` are DRAM column
   accesses, not AXI beats.
3. **Beat granularity and address decode**: connect byte addresses to
   rank/bg/bank/row/column.
4. **Geometry**: see how the default DDR4-like organization creates a 64-byte
   column access and a 33-bit byte address.
5. **Timing parameters**: use the timing table as a glossary.
6. **Bank state and scheduler**: read the formulas as earliest-legal-time
   constraints.
7. **Reset and tests**: verify that each test is pinning one piece of the model:
   first access, page hits, page misses, bank-group parallelism, FAW, refresh,
   write/read turnaround, and reset cancellation.

The plan is detailed because the model's value comes from small timing
distinctions. The core mental model is still simple:

```text
decode address
  |
  v
find target rank / bank group / bank / row / column
  |
  v
classify page: empty, hit, or miss
  |
  v
apply the timing constraints for the commands needed
  |
  v
return data or accept write at the computed ready time
```

---

## 16. Glossary

| Term | Meaning in this project |
|------|-------------------------|
| ACT | Activate a row into a bank's row buffer. |
| AXI beat | One transfer on AXI. Not the same as `vip_dram_req.beats`. |
| Bank | Independent DRAM array with one row buffer. |
| Bank group | Group of banks sharing some timing constraints; DDR4 has `_S`/`_L` distinctions. |
| BL8 | Burst length 8; one column command transfers 8 data beats on the DDR bus. |
| CAS | Column access command; read or write after a row is open. |
| Channel | Shared data bus controlled by a memory controller. |
| Column | Slice of an open row selected by a read/write command. |
| Empty | Target bank has no row open. |
| Hit | Target bank has the requested row already open. |
| Miss | Target bank has a different row open. |
| Page | The currently open row in a bank. |
| PRE | Precharge; close the currently open row. |
| Rank | Set of devices responding together to one command/chip-select. |
| REF | Refresh command. In this model, blocks the rank for `tRFC` and closes banks. |
| Row buffer | Sense-amp storage holding one activated row for a bank. |
| TLM beat | In `vip_dram`, one DRAM column access payload, 64 bytes by default. |

