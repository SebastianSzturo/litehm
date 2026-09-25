# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - Unreleased

Initial public release.

- `LiteHM.change_table` / `LiteHM.plan` / `LiteHM.submit`: online single-table
  SQLite schema changes through a shadow table, durable dirty-row capture,
  bounded reconciliation, exact validation, and one atomic cutover.
- Asynchronous execution through Active Job Continuation on a dedicated queue,
  with an inline escape hatch for consoles, tests, and rehearsals.
- `start: :paused` on `change_table`, `submit`, and `revert` registers an
  operation without starting it, so an operator resumes it when convenient.
- The engine serves the LiteHM icon as its favicon.
- Crash-safe resume from the target-database ledger; `LiteHM::RecoveryJob` for
  workers that died without a graceful stop.
- Operator controls: pause, resume, abort, manual cutover, archive cleanup, and
  `LiteHM.revert` as a second online migration.
- Mountable Rails engine for monitoring and operating migrations, closed unless
  an authorization callback is configured.
- Active Record and raw `sqlite3` compilers, including raw DDL targets for
  `STRICT`, `WITHOUT ROWID`, generated columns, and expression indexes.
- `live_v1` foreign-key protocol that keeps parent tables writable.
- Adaptive writer pacing, payload-sized batches, and WAL/database size budgets.
- Structured telemetry through `Rails.event`.

[Unreleased]: https://github.com/SebastianSzturo/litehm/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/SebastianSzturo/litehm/releases/tag/v1.0.0
