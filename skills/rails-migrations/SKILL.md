---
name: rails-migrations
description: Use when writing, reviewing, or executing database migrations — especially on tables with existing data in production. Covers safe zero-downtime patterns, the strong_migrations gem, concurrent index creation, column and table renames, data backfills, and removing columns safely. Extends rails-core rule 5 (multi-step nullable columns) with the full toolkit. Triggers on "migration", "add column", "rename column", "backfill", "index", "drop column", "change column type", "zero-downtime".
---

# Safe Rails Migrations

Rails migrations are easy to write and easy to break production with. Schema changes on populated tables can lock rows or the whole table for minutes — enough to time out requests and trigger an incident. These patterns work on PostgreSQL (the common production default); MySQL equivalents are noted where they differ.

Start with [[rails-core]] rule 5 (multi-step nullable columns) and rule 6 (multi-DB rollback) — this skill extends those.

---

## 1. `strong_migrations` — catch unsafe operations before they ship

Install `strong_migrations` to auto-detect dangerous migration operations at startup. It raises in development and CI for any migration that would lock a production table.

```ruby
# Gemfile
gem "strong_migrations"
```

After install, run `bin/rails generate strong_migrations:install` — it creates `config/initializers/strong_migrations.rb` where you can configure the production table-size threshold (default 10 MB). Operations it catches: adding a column with a non-null default (on older stacks), adding a non-concurrent index, changing a column type, renaming a column or table, and several others.

When `strong_migrations` raises, it tells you the safe alternative. Read the message before adding a `safety_assured { }` bypass — the bypass is for cases you've genuinely reasoned through, not for making the error go away.

---

## 2. Adding a column with a default value

**Rails 11+ on PostgreSQL 11+:** adding a `NOT NULL` column with a `default:` is safe — PostgreSQL 11 supports instant non-null column addition via a stored default. Add it directly.

**Older stacks:** the column addition rewrites the table. Use the multi-step pattern from [[rails-core]] rule 5:

```ruby
# Migration 1: add as nullable, no default
add_column :users, :timezone, :string

# Run a backfill (see Pattern 6), then:

# Migration 2: add the constraint
change_column_null :users, :timezone, false, "UTC"
```

---

## 3. Adding an index — always concurrent on PostgreSQL

A standard index creation locks the table for writes. On PostgreSQL, always use `algorithm: :concurrently`. Concurrent index creation cannot run inside a transaction, so disable it for that migration:

```ruby
class AddIndexToUsersEmail < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :users, :email, algorithm: :concurrently, if_not_exists: true
  end
end
```

`strong_migrations` will raise if you omit `algorithm: :concurrently` on a non-tiny table. One index per migration file when using `disable_ddl_transaction!` — concurrent operations need a separate connection state per index.

MySQL uses `ALGORITHM=INPLACE, LOCK=NONE` for online DDL; check the `strong_migrations` docs for the MySQL-specific safe alternatives.

---

## 4. Removing a column — ignore it first

Active Record caches the column list at boot. Dropping a column the running application still references causes `ActiveModel::MissingAttributeError` until the app restarts. Safe sequence requires two deploys:

**Deploy 1 — tell Active Record to ignore the column:**
```ruby
class User < ApplicationRecord
  self.ignored_columns += ["old_column"]
end
```

**Deploy 2 — drop it after all running processes have the new code:**
```ruby
remove_column :users, :old_column
# Also remove the ignored_columns entry
```

`strong_migrations` will warn you if you try to drop a column that isn't already in `ignored_columns`.

---

## 5. Renaming a column — dual-write sequence

Never use `rename_column` directly on a live table; the running app will reference the old name and break immediately. Safe pattern (four to five steps across deploys):

1. **Add the new column** (nullable).
2. **Write to both** — update the model and all writes to set both old and new columns.
3. **Backfill** the new column for all existing rows (see Pattern 6).
4. **Switch reads** to the new column; remove dual writes.
5. **Drop the old column** (see Pattern 4 — use `ignored_columns` first).

`strong_migrations` guides you through this with a `rename_column_safely` suggestion when it raises.

---

## 6. Data backfills — never in a schema migration

Never call `Model.all.each { |r| r.update(...) }` inside a schema migration:
- It holds the migration open (and its transaction) while iterating potentially millions of rows.
- Any application error rolls back the schema change along with the data.
- It loads every record into memory.

**Option A — `data-migrate` gem (separate data migration):**
```ruby
# db/data/20250101000000_backfill_user_timezone.rb
class BackfillUserTimezone < ActiveRecord::DataMigration
  def up
    User.in_batches(of: 1_000) do |batch|
      batch.update_all(timezone: "UTC")
    end
  end
end
```

**Option B — `maintenance_tasks` gem** for long-running or resumable backfills (minutes to hours, needs monitoring or re-queueing on failure).

**Option C — inline `update_all`** only when the table is new or empty (no rows to iterate), or a single `update_all` without looping is genuinely safe:
```ruby
User.where(timezone: nil).update_all(timezone: "UTC")
```

Use `update_all` in batches — never `.each { |r| r.update }`, which triggers callbacks and N+1 saves:
```ruby
User.in_batches(of: 1_000) { |b| b.update_all(timezone: "UTC") }
```

---

## 7. Changing a column type

`change_column` almost always rewrites the table on PostgreSQL. Safe zero-downtime pattern:

1. Add a new column of the desired type (nullable).
2. Write to both the old and new columns.
3. Backfill the new column (Pattern 6).
4. Switch reads to the new column.
5. Remove the old column (Pattern 4).

`strong_migrations` blocks `change_column` on non-trivially-sized tables and points you here.

---

## 8. Reversibility

Always define `down` or use the `reversible` block so `db:rollback` works cleanly in development and CI:

```ruby
def change
  reversible do |dir|
    dir.up   { add_column :users, :timezone, :string }
    dir.down { remove_column :users, :timezone }
  end
end
```

For data migrations, define `down` to undo the backfill, or explicitly raise `ActiveRecord::IrreversibleMigration` with a comment explaining why reversal isn't safe.

---

## Quick Reference

| Situation | Pattern |
|-----------|---------|
| Add nullable column | Direct `add_column` — always safe |
| Add NOT NULL with default (Rails 11+, Postgres 11+) | Direct — safe |
| Add NOT NULL with default (older stack) | Nullable → backfill → add constraint (two migrations) |
| Add index on large table | `disable_ddl_transaction!` + `algorithm: :concurrently` |
| Remove a column | `ignored_columns` first, drop in next deploy |
| Rename a column | Dual-write sequence (4–5 steps) |
| Bulk backfill | `in_batches` with `update_all`, not `.each { update }` |
| Change column type | New column → dual-write → backfill → switch → drop |
| Auto-catch unsafe ops | `strong_migrations` gem |
