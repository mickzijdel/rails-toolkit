---
name: rails-core
description: Use FIRST on any Ruby on Rails work — the project owner's hard-won Rails gotchas and non-negotiable rules (fixtures, migrations, Stimulus LSP, validation, gems, test suite). Read before writing or changing Rails code.
---

# Rails Core Gotchas

The entry-point skill for Rails work in this environment. These are personal, hard-won rules that override generic Rails habits. Read this first, then pull in the specific `rails-toolkit:rails-*` skill for the area you're touching.

## The Rules

### 1. Fixtures — never mutate, only add
Do **not** modify existing fixtures or add new relationships to them — that silently breaks other tests. If no existing fixture fits what you're testing, create a **new** one. See [[rails-testing]] for fixture patterns and deterministic UUIDs.

### 2. Stimulus LSP is stale until restart
After you add or rename a Stimulus controller, the Stimulus LSP does not refresh until a restart, so it may report a controller as "not a valid Stimulus controller" even though it exists. **Ignore these false errors** — don't chase them. See [[rails-stimulus]].

### 3. Validate on the server, not in JavaScript
Always prefer server-side validation with Hotwire and Turbo over client-side JavaScript validation. Let the model be the source of truth and re-render with Turbo. See [[rails-turbo]] and [[rails-models]].

### 4. Read the docs for new gems
When a newly-added gem or package is involved, read its actual API/docs rather than relying on memory — APIs drift between versions.

### 5. Migrations on populated tables are multi-step
For tables that already have rows, **never** add a non-nullable or unique column in a single migration. Use the multi-step pattern:
1. Add the column as **nullable**.
2. **Backfill** the data.
3. Add the **constraint** (NOT NULL / unique) in a follow-up migration.
See [[rails-models]] for transactions and data-integrity patterns. For the **legacy
integer-primary-key foreign-key gotcha** when adding a child table, see [[rails-models]].

### 6. Multi-database apps: `db:rollback` needs the namespaced task
In an app configured with multiple databases (e.g. `primary` / `queue` / `cache`), a bare
`bin/rails db:rollback` aborts with *"you must run the namespaced task"*. Target the database
explicitly: `bin/rails db:rollback:primary STEP=n` (and likewise for the other migration tasks
that operate per-database). See [[rails-models]].

### 7. Restart the dev server after a migration — it caches the schema at boot
A running dev server reads the DB schema **once at boot**. After a migration that adds
columns — especially an **enum-backed** column — the already-running process keeps 500ing
(`Undeclared attribute type for enum ... must be backed by a database column`) until it is
restarted. This is **not** a code bug; restart after migrating.

How you restart depends on the server: **Puma hot-restarts via `SIGUSR2`, not
`touch tmp/restart.txt`** (that's a Passenger-only trick and does nothing under Puma). Sending
`SIGUSR2` makes Puma re-exec in place keeping the **same PID**, so a foreman/`bin/dev` dev group
doesn't see a child die and tear everything down (Vite and friends keep running). Everyday app
code (models, controllers, views) auto-reloads and needs no restart — only **boot-time state**
does (initializers, `config/*`, `Gemfile`, env vars, new/enum-backed columns).

A drop-in `bin/restart-web` wrapper (adjust the `pgrep` pattern to your app's Puma process tag):

```sh
#!/usr/bin/env sh
# Hot-restart the running Puma dev server in place (SIGUSR2).
#
# Puma re-execs itself on SIGUSR2, keeping the same PID, so foreman does not
# see a child die and tear down the whole dev group — Vite keeps running.
# Use this to reload boot-time state: config/initializers, config/*, Gemfile,
# env vars, and new/enum-backed DB columns. Everyday app code (models,
# controllers, views) is auto-reloaded and needs no restart.
#
# Note: this is NOT `touch tmp/restart.txt` — that only works with Passenger.

set -e

pid=$(pgrep -f 'puma .* \[YourApp\]' || true)   # match your app's Puma process tag

if [ -z "$pid" ]; then
  echo "No running Puma dev server found (is bin/dev running?)." >&2
  exit 1
fi

echo "Hot-restarting Puma (pid $pid) via SIGUSR2..."
kill -USR2 "$pid"
echo "Done. Watch the bin/dev terminal for the restart log."
```

### 8. Run the FULL suite after factory/fixture changes
Factory and fixture changes have cascading effects across the entire suite. After any such change (or when optimizing/refactoring factories), run the **full** test suite — not just the files you touched. Use `PARALLEL_WORKERS=1` when you need readable, debuggable output. See [[rails-testing]].

## When to reach for the other skills
- Architecture / "should I add a service object?" → [[rails-philosophy]]
- Code aesthetics, method ordering, REST routing, enforcing style on AI output with a RuboCop hook → [[rails-style]]
- Models, validations, callbacks, scopes → [[rails-models]]
- Thin controllers, concerns → [[rails-controllers]]
- Background jobs (Solid Queue) → [[rails-jobs]]
- Turbo Frames/Streams/broadcasts → [[rails-turbo]]
- Stimulus controllers → [[rails-stimulus]]
- Caching, ETags, N+1 → [[rails-performance]]
- Schema/index/query audits → [[rails-database-performance]]
- Auditing / reviewing an existing or inherited app, tech-debt health-check → [[rails-audit]]
- Auth & authorization → [[rails-security]]
- URL-based tenancy, Current → [[rails-multi-tenancy]]
- File uploads, variants → [[rails-activestorage]]
- Extracting ViewComponents → [[rails-viewcomponents]]
- New Rails 8 app setup → [[rails-project-setup]]
- Writing tests → [[rails-testing]]
- **Upgrading Rails versions** (2.3 → 8.1, breaking changes, deprecations, multi-hop plans) → [[rails-upgrade]] — the vendored OmbuLabs/FastRuby.io upgrade skill. Reach for it whenever an upgrade is on the table; do **not** hand-roll the version bump.
