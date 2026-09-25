# Writer-latency rehearsal

The initial rehearsal on a restored production database (summarized in the
[design contract](./design-contract.md#pre-release-review-findings))
showed that fixed 250-row batches caused unacceptable contention. The
implementation now sizes batches by payload and measured duration, gives
application writers scheduling gaps, and rejects FK plans whose parent-write
triggers would scan a temporary table.

With the final implementation, the full-size column-addition rehearsal completed
290,116 application writes during migration and cleanup with zero writer errors.
Write p99 was 10.70 ms; 13 writes exceeded 100 ms, with a 192.62 ms maximum.
The nine smaller migration cases also completed without writer errors. These
results support the changes for the measured workload, with occasional stalls
still visible and production-load validation still required.

## Changes driven by the measurements

- Copy, reconciliation, and cleanup share an adaptive scheduler: start at 16 rows,
  cap at 250, target 256 KiB of payload and 10 ms per transaction. Pause for at
  least 10 ms and three times the measured transaction duration after releasing
  the transaction. The controller includes COMMIT time in its feedback. Batch
  resume state commits with the data change, eliminating a separate metadata
  transaction and flush after each batch.
- Warm selected payloads outside the writer lock; recheck sizes inside it. Allow
  one row above the batch target, but refuse source, projected, or prior-target
  rows above 16 MiB. Dropping a large column cannot bypass archive sizing.
- Fix the initial copy frontier and drain finite reconciliation generations.
  New writes remain journaled without extending the copy forever. Bound the
  final tail by bytes as well as identities, and drain large tails outside
  cutover. The default pre-commit cutover hold check is 50 ms.
- Execute on a dedicated connection so runner settings cannot replace the
  application's opaque busy handler. Use the GVL-releasing sqlite3-ruby handler
  and back off on lock acquisition. Restore ordinary connection settings before
  cleanup, including the timeout temporarily changed for cutover.
- Give the dedicated worker a 64 MiB page-cache allowance (or retain an already
  larger allowance). The measured raw default was approximately 2 MiB, which
  cannot retain an 11 MiB source row while building its target copy. Run passive
  checkpoints after data batches, outside the writer transaction, and include
  their I/O time in pacing. This aims to move WAL maintenance away from application
  commits; it does not change application connection settings. SQLite documents
  [passive checkpoint behavior](https://www.sqlite.org/pragma.html#pragma_wal_checkpoint)
  and the [per-connection cache allowance](https://www.sqlite.org/pragma.html#pragma_cache_size).
- Require indexed child lookups for source/archive and shadow FK pruning. Refuse
  unindexed or general affinity/collation predicates that scan child tables.
  Parent deletes and key updates continue under the live table's own FK rules.

These are scheduling and admission controls. They do not make a single SQLite
row operation, disk flush, application transaction, or COMMIT interruptible.
High-fanout parent changes still add work inside application transactions.

## Migration-type matrix

Each case started from a separate few-hundred-MB working database built from a
sample of real rows from a large-JSON-payload table (called `payloads` below),
including the largest rows available. It retained the complete
`payloads` column schema and indexes, with simplified parent/dependent tables
and real FK relationships. No production row data is included in this report.

Four independent writer processes each attempted a transaction about every
20 ms: update a small `payloads` row, insert a synthetic row, and delete the previous
synthetic row. Every 100 successful transactions each writer created a parent,
assigned 37 small `payloads` rows to it, then deleted it. This exercises FK work
for a high-fan-out parent change, but does not simulate every write path
or writes to the largest payloads. Rename/drop tests used SQL compatible with
both schemas; application rollout compatibility is still required.

The rehearsal's writer configuration for the final cohort was WAL, FK enforcement, recursive triggers,
`synchronous=NORMAL`, `cache_size=2000`, 128 MiB mmap, and sqlite3-ruby's
GVL-releasing **10,000 ms** busy handler. Working copies were explicitly flushed
to disk before starting workload timers. Earlier exploratory probes used 100 ms;
those are discussed separately below. The path-based runner retained its
conservative `synchronous=FULL` default, with the final 64 MiB cache allowance,
passive checkpoints, adaptive batching, and combined data/progress commits.

Single runs used Ruby 3.4.7, Rails 8.1.3.1, sqlite3-ruby 2.9.6 and SQLite 3.53.2
on shared Linux storage. OS cache state and unrelated host work were not controlled.
No other rehearsal, test suite, or large file copy was run concurrently with this
final cohort's workload windows. Timing excludes independent replay/verification.

| Change | Seconds | Successful writes | Write p99 ms | Write max ms | Writes over 100 ms | Writer errors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| No migration, before | 20.00 | 3,851 | 6.92 | 32.14 | 0 | 0 |
| Partial + covering indexes | 16.08 | 2,983 | 9.09 | 48.47 | 0 | 0 |
| NOT NULL column + default | 39.68 | 7,363 | 19.95 | 55.04 | 0 | 0 |
| Integer → text projection | 14.88 | 2,765 | 11.46 | 19.03 | 0 | 0 |
| Derived column / CASE projection | 15.09 | 2,806 | 12.08 | 65.31 | 0 | 0 |
| Column rename | 20.78 | 3,832 | 20.26 | 47.02 | 0 | 0 |
| Column removal | 14.79 | 2,763 | 6.86 | 17.02 | 0 | 0 |
| Indexed foreign key | 26.07 | 4,783 | 23.38 | 227.23 | 2 | 0 |
| Unique composite index | 15.02 | 2,791 | 8.35 | 99.44 | 0 | 0 |
| CHECK constraint | 14.94 | 2,783 | 9.81 | 21.09 | 0 | 0 |
| No migration, after | 20.00 | 3,754 | 27.28 | 116.90 | 1 | 0 |

The nine migration cases completed **32,869 writes with zero writer errors**;
**2 successful writes exceeded 100 ms**. The before/after controls show substantial
host variation, so these single runs do not establish a precise causal slowdown
or a guaranteed latency ceiling. All maxima and slow writes remain visible.

Percentiles describe successful transactions; timeout attempts are reported
separately. Every completed case above passed an independent replay of committed
writes, with the schema transformation recorded atomically at cutover. Ordered,
type-preserving hashes compared every column of `payloads`, its parent table,
and both dependent tables. FK and integrity checks passed. Timing
excludes the independent replay and verification.

Earlier exploratory cases used a strict 100 ms timeout and did not explicitly
flush copied files before measurement. Some also overlapped other work: one
check-constraint run recorded two probe timeouts; an FK attempt during a separate
large file copy recorded 164 probe timeouts and failed to acquire a cleanup lock.
That failure exposed the lingering cutover timeout and led to the retry fix. The
failed attempt is not counted as a successful end-to-end run. Another no-migration
full-size control recorded three 100 ms timeouts. These observations motivated
better isolation and controls; they do not prove that all stalls came from the
migration or that all came from the host.

## Largest observed parent payload

A separate profile of all `payloads` rows in the restored copy found the largest
payload group under one non-NULL parent: a parent group of several multi-megabyte
rows. All of those rows were included in a dedicated sample. The concurrent matrix
above also exercised 37-row parent changes.

After explicitly flushing each working copy and warming the source group,
a single parent deletion took **41.32 ms natively**, **49.86 ms with a prepared
shadow**, and **38.26 ms immediately after cutover with an archive present**.
Every resulting column matched the native result; FK and integrity checks passed.
These single measurements are not percentiles or evidence of a speedup. They
exercise the largest observed payload group, not every possible future fan-out.

## Restored production database

The first adaptive full-size run used a restored multi-gigabyte production
database (a read-only copy of an existing backup), in which `payloads` is the
dominant payload table. It added the partial
and covering reporting indexes, killed the worker after 5,000 copied rows, then
resumed and completed archive cleanup with four writers active throughout.

This run preceded the final cache/checkpoint changes and the final control-path
hardening. It completed in **1,943.99 seconds**, with **369,732 successful writes**:
p50 **0.316 ms**, p95 **2.537 ms**, p99 **12.027 ms**, maximum **931.299 ms**.
There were **14 timeout attempts at the strict 100 ms probe deadline** and
**20 successful writes over 100 ms**, including two over 500 ms. Parent-containing
transactions numbered 3,700, with p99 16.44 ms and maximum 85.10 ms. Peak sampled
WAL size was 59.53 MB; this is an observation, not reserved capacity or a hard
limit.

Independent replay matched every compared column of `payloads`, its parent
table, and both dependent tables. Whole-database FK checking and
`payloads` table/index integrity checking passed. Verification
rebuilt the intended table independently and used child-side indexes to make
replayed parent operations efficient. No migration implementation was used to
produce expected rows.

The tail latency and timeouts above motivated the cache/checkpoint iteration.
The final full-data run used the final implementation to add
an `INTEGER NOT NULL DEFAULT 0` column, with the same 10-second writer busy
timeout. It recovered from a forced SIGKILL after 5,000 copied rows,
completed cutover, and removed the archive. Migration and cleanup took
**1,551.68 seconds (25.86 minutes)**, excluding two 60-second no-migration controls
on the same working copy and all independent verification.

| Workload window | Successful writes | Write p99 ms | Write max ms | Writes over 100 ms | Writer errors |
| --- | ---: | ---: | ---: | ---: | ---: |
| No migration, before (60 seconds) | 11,351 | 17.95 | 106.57 | 2 | 0 |
| Migration, including cleanup | 290,116 | 10.70 | 192.62 | 13 | 0 |
| No migration, after (60 seconds) | 11,531 | 4.73 | 23.36 | 0 | 0 |

Migration-only write p50 was **0.483 ms**, p95 **3.564 ms**, and p99.9
**27.297 ms**. No write exceeded 500 ms. The migration p99 lies between the two
controls, while the maximum exceeds both; this does not establish zero impact or
a precise causal slowdown on shared storage. The complete run, including controls,
recorded 312,998 successful writes and zero errors. Its 3,132 parent-containing
transactions had p99 12.85 ms and maximum 87.91 ms.

The measured cutover transaction took **9.21 ms**. Recorded copy transactions had
p99 14.99 ms and maximum 87.88 ms; cleanup transactions had p99 2.99 ms and maximum
46.64 ms. These are elapsed transaction measurements including COMMIT, not exact
lock-duration traces. Explicit passive checkpoints run outside those measurements
and contribute to pacing. The killed worker's initial batches are not included
in the resumed worker's transaction statistics; application-write measurements
cover the crash and restart. Peak sampled WAL size was **79.58 MB**.

Independent replay passed for every compared column of `payloads`, its parent
table, and both dependent tables. Whole-database FK checks and `payloads`
table/index integrity checks passed. The runner finished in `done` state with the archive removed, and the
harness exited successfully after verification. The original backup was untouched.

## Validation and deployment boundary

The final default suite and both checked compatibility Gemfiles passed
**175 tests and 938 assertions** each, with zero failures, errors, or skips.
The gem builds successfully. These matrix entries resolve to Rails 8.1.3.1 and
sqlite3-ruby 2.9.6 on this Linux host; this is not cross-platform coverage.

The original backup remains read-only. All migrations, workload writers,
crashes, and verification ran on local copies; no migration ran against a live
production database. Comparable-storage request-load validation is
still necessary before promising a production latency/error envelope. New target
constraints may intentionally reject future application values after cutover;
LiteHM cannot make an incompatible schema change transparent to old code.
