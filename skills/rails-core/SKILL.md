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
See [[rails-models]] for transactions and data-integrity patterns.

### 6. Run the FULL suite after factory/fixture changes
Factory and fixture changes have cascading effects across the entire suite. After any such change (or when optimizing/refactoring factories), run the **full** test suite — not just the files you touched. Use `PARALLEL_WORKERS=1` when you need readable, debuggable output. See [[rails-testing]].

## When to reach for the other skills
- Architecture / "should I add a service object?" → [[rails-philosophy]]
- Code aesthetics, method ordering, REST routing → [[rails-style]]
- Models, validations, callbacks, scopes → [[rails-models]]
- Thin controllers, concerns → [[rails-controllers]]
- Background jobs (Solid Queue) → [[rails-jobs]]
- Turbo Frames/Streams/broadcasts → [[rails-turbo]]
- Stimulus controllers → [[rails-stimulus]]
- Caching, ETags, N+1 → [[rails-performance]]
- Schema/index/query audits → [[rails-database-performance]]
- Auth & authorization → [[rails-security]]
- URL-based tenancy, Current → [[rails-multi-tenancy]]
- File uploads, variants → [[rails-activestorage]]
- Extracting ViewComponents → [[rails-viewcomponents]]
- New Rails 8 app setup → [[rails-project-setup]]
- Writing tests → [[rails-testing]]
- **Upgrading Rails versions** (2.3 → 8.1, breaking changes, deprecations, multi-hop plans) → [[rails-upgrade]] — the vendored OmbuLabs/FastRuby.io upgrade skill. Reach for it whenever an upgrade is on the table; do **not** hand-roll the version bump.
