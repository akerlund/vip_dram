# vip_dram — Device-Only Example Test Cases

The SystemVerilog tests live under [`sv/tc/`](sv/tc/) and the Python tests live
under [`py/tc/`](py/tc/). Both follow the `tc_dram_<name>` convention and drive
the `vip_dram` device **directly over its neutral TLM API** — no memory
controller, no AXI4, no clock (see [README.md](README.md) for the testbench
architecture).

Run a single SV test after building the FuseSoC/VCS target:

```
./akerlund__vip_dram_example_0 +UVM_TESTNAME=tc_dram_smoke -l tc_dram_smoke.log
```

Run a single Python test from `testbench/py`:

```
python3 run_all_tcs.py tc_dram_smoke
```

Every test passes with `UVM_ERROR=0, UVM_FATAL=0`.

Each test issues requests through the driver and checks the responses two ways:

- **Timing** — for single-outstanding accesses the driver calls
  `vip_dram.predict()` at issue time and the scoreboard compares the observed
  `first/last_beat_ready_time` against it (within a 1-cycle tolerance). For
  back-to-back streams the test instead asserts on the *relationship* between
  collected responses (e.g. the spacing between consecutive bursts).
- **Page classification & data** — the test registers the expected
  hit/miss/empty per request, and compares read data against the written/seeded
  pattern.

The DUT geometry is the default DDR4-3200, ×8, 8 Gb, 64-bit, 8 GiB part
(`VIP_DRAM_CFG_DEFAULT_C`); timing values quoted below are that preset.

---

## Smoke / data integrity

### `tc_dram_smoke`

The canonical "does the device work?" test. One write then one read to the same
row of a fresh bank. The write opens the bank, so it is classified **empty** and
its data is ready at **exactly `tRCD + tWL`** (23.75 ns) — proving there is no
spurious `tRP` term on a first access (the `-LARGE` reset sentinel, plan Q1). The
follow-up read is a **hit** and returns the written data (frontdoor round-trip).

### `tc_dram_writes_then_reads`

Writes a distinct pattern to eight `(bank group, row)` targets, then reads them
all back and compares. Exercises the full frontdoor write→read path across banks
and rows with scheduler timing applied throughout — the broad data-integrity
sweep.

---

## Timing — single bank

### `tc_dram_page_hit_streak`

64 single-beat reads to consecutive columns of **one** row of **one** bank,
issued back-to-back. The first opens the row (empty); the other 63 are page
hits. Checks the per-access spacing settles to **`tCCD_L`** (8 cyc / 5.0 ns —
same bank group), **not** `tBL`, and that the device counts exactly 1 empty + 63
hits. This is the same-bank-group throughput ceiling.

### `tc_dram_page_thrash`

Alternating-row reads to the **same** bank: the first opens row 0 (empty), each
later access targets the other row and is a **miss**. With `tRAS` allowed to
elapse between accesses (a settle delay — the "row already old enough to close"
case), each miss costs exactly **`tRP + tRCD + tCL`** (41.25 ns). The device
counts the misses. This is the worst-case single-bank latency.

---

## Timing — bank / rank concurrency

### `tc_dram_bank_parallel`

Opens one row in each of the 4 bank groups, then streams reads round-robin
across them. Because consecutive accesses hit **different** bank groups, the
spacing is **`tCCD_S`** (2.5 ns) — strictly less than the same-bank-group
`tCCD_L` of the streak test. This is the bank-group-level parallelism that lifts
throughput above the single-bank ceiling. (At DDR4-3200 `tCCD_S == tBL`, so the
two coincide numerically; the constraint that *binds* is `tCCD_S`.)

### `tc_dram_faw_stress`

Five back-to-back reads, each to a different closed bank, so each forces an
ACTIVATE. The first four pace by `tRRD`; the fifth is held off by the
**four-activate window** — its ACT cannot issue before the oldest of the prior
four `+ tFAW`. Observed as `(first5 - first0) == tFAW` (21 ns; the constant
`tRCD + tCL` cancels). Caps the sustained activate rate per rank.

---

## Refresh

### `tc_dram_refresh_explicit`

Opens a row, settles, then issues an explicit `VIP_DRAM_OP_REF_E` to the rank.
With the rank otherwise idle the REF takes exactly **`tRFC`** (350 ns). After it
completes every bank of the rank is precharged, so the next access is **empty**.
The device's refresh counter increments by one. (The device never self-refreshes
— the caller owns REF cadence.)

---

## Backdoor / storage

### `tc_dram_backdoor_preload`

Seeds memory through the timing-free backdoor (`backdoor_write`), then reads it
back through the **frontdoor** (full timing) and the **backdoor**
(`backdoor_read`), verifying all three agree. The preload path cosim/DPI
environments rely on.

### `tc_dram_partial_write`

Seeds a base pattern, then frontdoor-writes the **same** row with a new pattern
but a non-all-ones `wstrb` (even bytes only). Reading back, the strobed (even)
bytes hold the new data and the masked (odd) bytes retain the base — exercising
the `vip_mem` `wr_be` byte-enable merge.

---

## Reset

### `tc_dram_reset_recovery`

Issues a read (which schedules an open row and forks a delayed response), then
`reset()`s the device mid-flight before that response fires. Checks that the
in-flight response is **cancelled** (`disable fork` — it never arrives), that
bank state is **cleared** (a read to the same address afterward is *empty*, not
*hit*), and that only the post-reset response is observed. The manager-visible
"everything outstanding is dropped on reset" contract.

---

## Preset coverage

### `tc_dram_preset_sweep`

Runs a smoke read once per timing preset (DDR4-3200, DDR4-2400, DDR3-1600,
LPDDR4-3200, DDR5-4800, IDEAL). For each: `apply_preset`, `validate()`, reset,
read a fresh bank. The scoreboard confirms the observed timing matches
`predict()` under that preset — the single-source-of-truth guarantee exercised
across every bin — and that `validate()` accepts each preset.

### `tc_dram_ideal_zero_latency`

The IDEAL preset collapses every timing parameter to zero, so a read's data is
ready at its arrival time: `first == last == arrival`. A sanity regression that
the zero-delay path behaves and the response still carries the data.

---

## Read-fault injection

### `tc_dram_read_fault`

Seeds three rows via the backdoor, marks one **CORRECTABLE** and one
**UNCORRECTABLE** with `inject_fault()`, and frontdoor-reads all three. Asserts
the response `injected_fault` severity; that a correctable beat carries a one-bit
`corrupt_mask` and repairs exactly (`rdata ^ corrupt_mask == seed`); that an
uncorrectable beat flips two bits with a zero mask; that `get_fault()` mirrors the
injections; that the **backing store is untouched** (the corruption is
response-only); and that `clear_all_faults()` makes a re-read come back clean.

---

## Predictor

### `tc_dram_predict_matches_schedule`

Drives the public `predict()` API directly over a page-empty / hit / miss / write
walk. For each op it asserts `predict()` is **side-effect-free** (three back-to-
back calls return identical times and do not perturb committed state) and that the
committed access lands within one cycle of the pre-committed prediction —
`predict() == schedule()` checked at the API level, complementing the driver's
implicit per-issue comparison.

---

## Coverage map

| Capability                          | Test(s) |
|-------------------------------------|---------|
| First-access latency (`tRCD+tWL/CL`)| smoke |
| Page hit spacing (`tCCD_L`)         | page_hit_streak |
| Page miss cost (`tRP+tRCD+tCL`)     | page_thrash |
| Bank-group parallelism (`tCCD_S`)   | bank_parallel |
| Four-activate window (`tFAW`)       | faw_stress |
| Refresh (`tRFC`, precharge-all)     | refresh_explicit |
| Page hit/miss/empty classification  | smoke, page_hit_streak, page_thrash, bank_parallel |
| Debug counters                      | page_hit_streak, page_thrash, refresh_explicit |
| Data integrity (frontdoor)          | smoke, writes_then_reads |
| Backdoor preload/read               | backdoor_preload, ideal_zero_latency |
| Byte-enable (`wstrb`) merge         | partial_write |
| Reset / in-flight cancellation      | reset_recovery |
| Preset machinery + `validate()`     | preset_sweep, ideal_zero_latency |
| `predict()` == observed             | every single-outstanding test |
| `predict()` purity + direct API     | predict_matches_schedule |
| Read-fault injection (SECDED)       | read_fault |
