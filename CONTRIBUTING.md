# Contributing to LiteHM

Thanks for helping. LiteHM moves production data, so changes are held to a
high bar: every behavior change needs a test against a real file-backed SQLite
database. Mocks and in-memory databases cannot stand in for WAL, locking,
crash recovery, or schema-cookie behavior.

## Setup

LiteHM needs Ruby 3.3+, and SQLite 3.51.3+ as loaded by `sqlite3-ruby`. The
precompiled `sqlite3` gems bundle a suitable SQLite, so no system package is
required.

```bash
bundle install
bundle exec rake                # full suite, including crash and concurrency tests
bundle exec rake compatibility  # every Gemfile in gemfiles/
```

Run a single file with:

```bash
bundle exec ruby -Ilib -Itest test/integration/runner_test.rb
```

The suite forks processes and SIGKILLs workers on purpose. Expect it to take
several minutes.

## Pull requests

- Open an issue first for anything larger than a bug fix, especially new
  supported schema objects or changes to the cutover and capture protocols.
  [`docs/design-contract.md`](./docs/design-contract.md) explains why the
  current boundaries exist.
- Anything LiteHM cannot prove safe must fail with a clear error *before*
  installing capture triggers. A best-effort path is not an acceptable
  substitute for a refusal.
- Add an entry under `[Unreleased]` in [`CHANGELOG.md`](./CHANGELOG.md).
- Keep commits focused and explain the reasoning in the message.

## Reporting bugs

Include the SQLite version (`SQLite3::SQLITE_LOADED_VERSION`), `sqlite3-ruby`,
Rails, and Ruby versions, the plan (`LiteHM.plan(...)` block), and
`LiteHM.status(id)` output. Remove any row data you would not publish.

Report suspected data loss or corruption privately; see
[`SECURITY.md`](./SECURITY.md).
