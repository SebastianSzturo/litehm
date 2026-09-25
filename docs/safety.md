# Safety boundary and internals

What LiteHM refuses to do, why, and how it keeps the live table authoritative
until cutover. The complete design and its reasoning live in
[`design-contract.md`](./design-contract.md).

## Preconditions

LiteHM fails before installing capture unless all of these are true:

- SQLite is 3.51.3 or newer and the database is in WAL mode. Older releases
  include the [WAL-reset corruption bug](https://sqlite.org/wal.html#walresetbug).
  Every process opening the database, including application writers and backup
  tools, must use a patched build; checking the runner alone is insufficient.
- The source is an ordinary single table with a complete primary key or
  `UNIQUE NOT NULL` locator. Bare rowid requires the explicit
  `allow_bare_rowid` no-`VACUUM`/no-DDL operational contract.
- The target projection is deterministic, row-local, and every non-generated
  target column is representable. Subqueries, aggregates, and window functions
  require a different migration strategy because one source write can change
  other projected rows.
- Triggers attached to other tables must not reference the migrating table;
  LiteHM fails closed rather than leaving their DML compiled against stale
  columns.
- Non-ABORT target conflict policies are absent. They can silently discard or
  replace projected rows.
- Inbound foreign keys preserve every referenced key exactly. Outbound foreign
  keys use `archive: :ephemeral`; parent triggers keep temporary copies from
  restricting or changing application FK behavior (details below).
- Applications that use replace-style source or guarded-parent writes set
  `recursive_triggers=ON` on every writer and declare
  `all_writers_recursive_triggers: true`.

Preparation keeps the original table authoritative. Source triggers append
typed dirty identities; a two-phase reconciliation work set removes all stale
owners before installing current rows, including unique-value swaps spanning
batch boundaries. Composite/text/blob keys, `WITHOUT ROWID`, key changes,
unkeyed rowid targets, and every SQLite storage class have durable typed
correspondence. Every mutating transaction checks a lease epoch, and artifact
hash loss causes capture reinstall plus a full rescan. A separate heartbeat
renews the operation lease during long read-only validation; `lease_ttl_ms`
controls crash takeover and is deliberately separate from the short
`writer_lease_ms` transaction target.

`LiteHM::OperationJob` uses one stable Active Job Continuation step. It
checkpoints only after committed preparation, copy, reconciliation, validation,
cleanup, readiness, and cutover boundaries. A graceful worker stop serializes
the continuation and requeues the job. After a hard crash, redelivery waits for
the stale epoch-fenced lease to expire and resumes from the database cursor.
Pause, abort, and cutover commands are also read only at those safe points, so
the web UI cannot interrupt an open SQLite transaction.

Forward and reverse validation scan bounded locator ranges in short WAL read
snapshots; FK checks are limited to the same ranges. Ready and cutover recheck
source schema identity, bound the last dirty frontier, and compare that
frontier exactly. Cutover uses
acquisition timeouts and a hold-time check before commit. A failed attempt rolls back to the complete
old state and retries; exhaustion leaves preparation at `ready`.
Ready-tail draining has its own `max_ready_batches` cap (10,000 by default),
because a long validation scan can accumulate far more bounded work than the
final cutover's retry allowance. The elapsed-time cap still applies to both.
`max_wal_bytes` and `max_database_bytes` stop execution when a boundary check
observes an overrun. They do not reserve disk or prevent a single transaction
or another writer from exceeding the threshold. Copy, reconciliation, and cleanup use adaptive batches: initially 16 rows,
up to 250, reduced by a 256 KiB payload target and measured transaction duration.
Selected payloads are warmed before acquiring the writer lock and sizes are
checked again inside it. Batch progress and resume revisions commit with the
data change, avoiding a second metadata write transaction per batch. A single row can exceed the batch target, but a source,
projected, or old target row over 16 MiB stops the migration without rejecting
application writes. Removing a large column does not bypass the archive limit.

The default `writer_lease_ms: 10` is a feedback target, not an interruptible
SQLite deadline. Data-writing transactions are followed by a pause of at least
10 ms and three times their measured duration (`writer_duty_cycle: 0.25`).
Validation cursor checkpoints use proportional pacing without the minimum pause;
writer-lock contention still backs off. Copying records a
finite initial frontier; later inserts remain captured. Reconciliation drains
finite generations, so a steady stream of small writes does not keep extending
the copy or demand a permanently empty journal. The final tail is bounded by
both identities and payload bytes. Readiness tail reconciliation and atomic cutover both use the
`cutover_hold_ms` limit (50 ms by default), independently of the adaptive batch target.
Large rows, expensive projections, parent fan-out, and slow I/O can still exceed
these targets. COMMIT and individual row operations cannot be interrupted safely;
rehearse the intended workload and storage before choosing a latency budget.

Mutating entrypoints use a dedicated connection, preserving the application's
busy handler and transaction state. The runner uses sqlite3-ruby's GVL-releasing
busy handler and backs off when an application owns the writer lock. Borrowed
connections with an open transaction cannot be used for execution.
The runner gives its own connection at least a 64 MiB page-cache allowance so
prewarming an allowed large row does not immediately evict its pages. Copy,
reconciliation, and cleanup also perform [passive checkpoints](https://www.sqlite.org/pragma.html#pragma_wal_checkpoint)
after committing, outside the writer transaction, to reduce WAL maintenance left
for application commits. A pinned reader can leave frames pending; the worker
does not wait for it. Checkpoint I/O contributes to the worker's pacing delay.
Application durability, busy-handler, cache, and checkpoint settings are preserved.
Generated target columns count toward both row and batch payload limits. A private
in-memory target lets SQLite evaluate the complete row, including target affinities
and generated expressions, before copying; a measurement trigger skips actual row
storage. The fenced recheck repeats this sizing for concurrent source changes.
Generated targets that would implicitly allocate a NULL INTEGER PRIMARY KEY are
refused because their generated values cannot be measured against a known key.
Archives
are never instant rollback: cleanup first commits `archive_released`, updates
the durable receipt, and only then deletes archive rows.

Logical index names are mapped to temporary physical names. LiteHM's Active
Record integration makes `indexes`, `index_exists?`, subsequent LiteHM plans,
and schema dumps see logical names. Foreign raw SQLite connections necessarily
see physical catalog names.

## Foreign keys and parent writes

New plans use the durable `live_v1` foreign-key protocol. It does not freeze
parent tables. Before a parent delete or a change to a referenced key:

1. A trigger records the source identities of affected shadow rows in the dirty
   journal, then removes those shadow rows in the same application transaction.
2. SQLite evaluates the live source table's own FK actions normally. A valid
   cascade or `SET NULL` proceeds; a real `RESTRICT`/`NO ACTION` violation still
   fails and rolls back the trigger's work too.
3. Reconciliation installs and validates the current source projections. If a
   newly added target FK has become invalid, the migration fails safely before
   promotion instead of changing the application's existing write semantics.

At cutover, replacement parent triggers prune the **released** source archive.
It is disposable, may change after release, and is never claimed as rollback
evidence. Parent writes continue while background cleanup drains the archive.
The source/archive and shadow pruning predicates must use indexed child
lookups, verified with `EXPLAIN QUERY PLAN` before installing their triggers.
Unindexed FKs and composite, affinity, or collation comparisons that require a
child-table scan are refused. Adding a new FK therefore also requires a suitable
child index. Ordinary Rails integer references and matching-affinity composite keys with
compatible child indexes pass this gate. The parent column supplies comparison
collation; incompatible child index collations still fail the query-plan check. High-fanout parent changes still prune multiple temporary rows inside
the application transaction; index admission does not cap that work. Rehearse
parent changes at the intended maximum fan-out.

Generated parent keys, self-referential FKs, and changes to inbound referenced
keys remain unsupported. Generated parent keys are refused because updates to
their dependencies can bypass column-specific parent guards.
Replace-style parent writes still require `recursive_triggers=ON` on **every**
writer. Existing serialized plans without the `live_v1` compiler marker retain
their original freeze protocol; abort them and create a new plan to use the new
behavior. Aborting those legacy plans releases their parent freeze before
draining the shadow table. Re-registering a legacy plan preserves its stored
policy despite added policy keys or changed defaults; explicit policy changes
are still refused.

Structured operations fail closed if Rails would silently remove an existing
index/uniqueness constraint or turn a generated column into stored data. Use an
explicit raw target definition for those rebuilds. Date/time projections with
dynamic arguments are rejected because future values can mean `now`; fixed
literal date/time expressions are allowed.


## Raw SQLite targets

Structured operations use Active Record only as a compiler on a disposable
SQLite file. The execution engine itself depends only on `sqlite3`. Exact table
shapes, generated columns, table options, expression indexes, and other SQLite
DDL can use the raw compiler:

```ruby
LiteHM.change_table(:events, id: "strict-events-v2", adapter: :raw) do |table|
  table.ddl <<~SQL
    DROP TABLE #{table.name};
    CREATE TABLE #{table.name} (
      id INTEGER PRIMARY KEY,
      payload BLOB,
      payload_size INTEGER GENERATED ALWAYS AS (length(payload)) STORED
    ) STRICT;
  SQL
end
```

`table.name` is a quoted identifier valid only in the disposable compiler.
Ruby row callbacks and cardinality-changing filters are intentionally absent;
per-column deterministic SQL projections use `table.project`.

LiteHM only inserts an implicit affinity cast when widening to `TEXT`.
Potentially lossy changes to `INTEGER`, `REAL`, `NUMERIC`, or `BLOB` require an
explicit projection, so values such as `"12abc"` cannot silently become `12`:

```ruby
table.change_column :legacy_number, :integer
table.project :legacy_number,
  "CASE WHEN legacy_number GLOB '[0-9]*' THEN CAST(legacy_number AS INTEGER) END"
```

