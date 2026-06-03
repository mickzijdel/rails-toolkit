---
name: rails-database-performance
description: "Use when reviewing or auditing a Rails app's database schema for missing indexes, slow query patterns, or database performance issues. Triggers on: schema review, slow queries, EXPLAIN ANALYZE output, missing index warnings, or any request to audit db/schema.rb."
---

# Rails Database Index & Query Performance Audit

## Overview

A systematic checklist for auditing `db/schema.rb` and ActiveRecord models for missing indexes and query anti-patterns. Work through every section below — do not stop early.

## How to Run This Audit

1. Open `db/schema.rb`
2. Open all model files (`app/models/**/*.rb`)
3. Work through every checklist item below
4. For each issue found: generate a migration, do not bundle unrelated indexes together

---

## Checklist

### 1. Foreign Key Indexes

Every column ending in `_id` must have an index.

```bash
grep -n "_id" db/schema.rb | grep -v "index\|#"
```

Cross-reference with:
```bash
grep -n "add_index\|t\.index" db/schema.rb | grep "_id"
```

**Fix:**
```ruby
add_index :table_name, :other_model_id
```

---

### 2. Polymorphic Association Indexes

Any polymorphic association (`_type` + `_id` pair) needs a **composite** index on both columns together, not two separate indexes.

```bash
grep -n "_type" db/schema.rb
```

**Fix:**
```ruby
add_index :comments, [:commentable_type, :commentable_id]
```

---

### 3. Frequently Queried Scope Columns

Check every model for scopes using `where`. Each column in a `where` clause on a frequently-called scope is a candidate for an index.

```bash
grep -rn "scope.*where" app/models/
```

Common patterns that need indexes:
- `where(published: true)` → index on `published`
- `where(featured: true)` → index on `featured`
- `where(active: true)` → index on `active`
- `where(status: ...)` → index on `status`
- `where(account_id: ...)` + another column → consider composite index

**Fix:**
```ruby
add_index :articles, :published
add_index :articles, :featured
```

---

### 4. Status / State Columns

Columns named `status`, `state`, `aasm_state`, `workflow_state` that are queried with `where` need an index. These are often used in scopes like `where(status: "published")`.

```bash
grep -n "status\|state\|aasm_state" db/schema.rb
```

Check models for transitions and scopes on these columns.

**Fix:**
```ruby
add_index :posts, :status
```

---

### 5. Sort / Order Columns

Any column used in `ORDER BY` should have an index so the database can read pre-sorted data instead of sorting at query time.

```bash
grep -rn "\.order(" app/models/ app/controllers/
```

Common columns: `created_at`, `updated_at`, `position`, `published_at`, `name`.

Already indexed by default in many Rails setups: `created_at`, `updated_at` — verify they're actually present.

**Fix:**
```ruby
add_index :articles, :published_at
add_index :items, :position
```

For multi-column sorts, include sort direction:
```ruby
add_index :articles, [:account_id, :created_at]
```

---

### 6. Position / Sortable List Columns

Columns named `position` or `sort_order` for drag-and-drop ordered lists need an index.

```bash
grep -n "position\|sort_order\|rank" db/schema.rb
```

---

### 7. Login / Authentication Columns

Any column used to look up users during authentication must have a **unique** index.

```bash
grep -rn "find_by.*email\|find_by.*username\|where.*email\|where.*username" app/models/
```

Check: `email_address`, `email`, `username`, `token`, `reset_password_token`, `confirmation_token`

**Fix:**
```ruby
add_index :users, :email_address, unique: true
add_index :users, :username, unique: true
```

---

### 8. Counter Cache Columns

`*_count` columns added by `counter_cache: true` should have no index (they're read, not searched), but verify the **parent model** declares `counter_cache: true`.

```bash
grep -n "_count" db/schema.rb
grep -rn "counter_cache" app/models/
```

If you find a `count > 0` or `.count` call on a large association without a counter cache, consider adding one:
```ruby
belongs_to :project, counter_cache: true
```

---

### 9. Counting Anti-Pattern

`Model.count` performs a full table scan. Check controllers and models for count calls on large tables.

```bash
grep -rn "\.count\b" app/models/ app/controllers/ app/helpers/
```

**Replace:**
- `items.count > 0` → `items.exists?`
- `items.count == 0` → `items.none?` or `!items.exists?`
- Frequently displayed counts → `counter_cache`

---

### 10. Offset Pagination Anti-Pattern

`LIMIT/OFFSET` pagination degrades linearly — page 100 is ~100x slower than page 1.

```bash
grep -rn "\.offset\|paginate\|page(" app/models/ app/controllers/
```

**Fix:** Use keyset/cursor pagination. In this project, `geared_pagination` is already available:
```ruby
@page = set_page_and_extract_portion_from(scope, per_page: [15, 30, 50])
```

Or use range-based queries:
```ruby
Fault.where("created_at > ? AND created_at < ?", 100.days.ago, 101.days.ago)
```

---

### 11. Sorting Without Indexes

Any `ORDER BY` on an unindexed column causes the database to sort the full result set in memory.

Run `EXPLAIN ANALYZE` on your slowest queries to spot sequential scans on large tables with sorts:
```sql
EXPLAIN ANALYZE SELECT * FROM faults ORDER BY created_at DESC LIMIT 25;
```

Look for: `Sort Method: external merge  Disk` or `Seq Scan` — these indicate missing indexes.

---

## Generating Migrations

For each group of related indexes, generate a descriptive migration:

```bash
rails generate migration AddMissingIndexesToArticles
rails generate migration AddPolymorphicIndexToComments
rails generate migration AddAuthIndexesToUsers
```

Keep each migration focused. Do not combine unrelated tables in one migration.

---

## Quick Reference

| Column Pattern | Required Index |
|---|---|
| `*_id` (foreign key) | Single index |
| `*_type` + `*_id` (polymorphic) | Composite index on both |
| Scope `where` columns | Single index |
| `status`, `state` columns | Single index |
| `ORDER BY` columns | Single index (with direction if needed) |
| `position`, `sort_order` | Single index |
| `email`, `username` (login) | Unique index |
| `*_token` (auth tokens) | Unique index |

## Common Mistakes

- Adding separate indexes for polymorphic `_type` and `_id` instead of a composite index
- Forgetting that `email_address` on the `users` table should be unique
- Indexing boolean columns with very low cardinality on small tables (not worth it — only index if the table is large and the `where` is frequent)
- Not using `EXPLAIN ANALYZE` to verify the index is actually being used after adding it
