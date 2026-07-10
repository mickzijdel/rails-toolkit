---
name: rails-search
description: Use when adding or auditing in-app search — Postgres full-text search with pg_search, trigram fuzzy matching for autocomplete/typo tolerance, ranking, multi-model search, tenant scoping, background reindexing, and when to escalate to a dedicated search service (Elasticsearch, Meilisearch, Algolia). Triggers on "search", "full-text search", "fuzzy match", "autocomplete", "typeahead", "search results are wrong/slow", "add a search bar".
---

# Rails Search

Postgres already ships two search primitives — `tsvector` full-text and `pg_trgm` trigram
similarity — that cover the overwhelming majority of in-app search needs without a new
service to run, deploy, and keep in sync. Reach for a dedicated search engine only once a
concrete requirement outgrows them (see §6).

## 1. Full-Text Search with pg_search

[`pg_search`](https://github.com/Casecommons/pg_search) wraps Postgres's `tsvector`/`tsquery`
machinery in an ActiveRecord scope — no separate index process to run.

```ruby
# Gemfile
gem "pg_search"
```

```ruby
class Card < ApplicationRecord
  include PgSearch::Model

  pg_search_scope :search_full_text,
    against: { title: "A", description: "B" }, # weighted columns: A > B > C > D
    using: {
      tsearch: { prefix: true, dictionary: "english" }, # prefix: true matches "post" against "posting"
    }
end
```

```ruby
Card.search_full_text("ship dashboard")
```

`against` accepts a hash of `column => weight` so a title match ranks above a body match —
`ts_rank` (below) reads these weights back out. Store the language as a column
(`dictionary: :language`) rather than hardcoding `"english"` if the app is multilingual;
falling back to `"simple"` (no stemming) avoids silently dropping non-English content.

## 2. Ranking Results

`pg_search_scope` returns results ordered by relevance by default, but expose the raw rank
when you need to blend it with other signals (recency, popularity):

```ruby
class Card < ApplicationRecord
  include PgSearch::Model

  pg_search_scope :search_full_text,
    against: { title: "A", description: "B" },
    using: { tsearch: { prefix: true } },
    ranked_by: ":tsearch"
end

Card.search_full_text("ship dashboard").with_pg_search_rank
# each result has #pg_search_rank
```

Combine the text rank with a recency boost when fresher content should win close ties:

```ruby
ranked_by: "(:tsearch) * (1 + 1.0 / (1 + EXTRACT(EPOCH FROM (now() - cards.updated_at)) / 86400))"
```

## 3. Trigram Fuzzy Matching (Typos, Autocomplete)

`tsearch` matches whole words after stemming — it won't catch `"strat"` -> `"strategy"` mid-word
or a typo like `"stratgey"`. `pg_trgm` scores by shared 3-character substrings instead, so it
tolerates both:

```ruby
# migration
enable_extension "pg_trgm"
add_index :cards, :title, using: :gin, opclass: :gin_trgm_ops
```

```ruby
pg_search_scope :search_autocomplete,
  against: :title,
  using: { trigram: { threshold: 0.2 } } # lower threshold = more lenient matches
```

**Pick by intent:** `tsearch` for "find the card about invoicing" (whole-word, ranked,
stemmed); `trigram` for "user is still typing" autocomplete and typo-tolerant lookups.
Combining both (`using: { tsearch: {...}, trigram: {...} }`) is common — `pg_search` unions
them and de-dupes.

## 4. Multi-Model Search

Search across several models with `PgSearch.multisearch`, which maintains a single
`pg_search_documents` table:

```ruby
class Card < ApplicationRecord
  include PgSearch::Model
  multisearchable against: [ :title, :description ]
end

class Comment < ApplicationRecord
  include PgSearch::Model
  multisearchable against: :body
end
```

```ruby
PgSearch.multisearch("ship dashboard").map(&:searchable) # heterogeneous results, ordered by rank
```

The `pg_search_documents` rows are maintained via `after_save`/`after_destroy` callbacks —
for a bulk import, wrap it in `PgSearch::Multisearch.rebuild(Card)` afterward rather than
letting thousands of individual callbacks fire.

## 5. Guard Against N+1 and Cross-Tenant Leaks

Search results are just an ActiveRecord relation — the [[rails-database-performance]]
N+1 rules apply directly. Preload what the results view needs:

```ruby
Card.search_full_text(query).includes(:account, :labels)
```

In a multi-tenant app, scope every search to the tenant **before** searching, not after —
filtering post-hoc still executes the full-text query across every tenant's rows and risks
a result leaking through an unscoped code path. Fold it into the same pattern
[[rails-multi-tenancy]] uses for `policy_scope`:

```ruby
Current.account.cards.search_full_text(query)
```

For `PgSearch.multisearch`, add tenant/searchable-type columns to `pg_search_documents`
(`multisearchable against: [...], additional_attributes: -> (record) { { account_id: record.account_id } }`)
and filter on them, since a bare multisearch query has no per-model scope to hang tenancy off.

## 6. Reindexing in the Background

Reindexing thousands of `multisearchable` rows, or rebuilding after a schema/weighting
change, belongs in a job — not a request or a migration that blocks deploys. Reuse the
retry-and-idempotency shape from [[rails-jobs]]:

```ruby
class RebuildSearchIndexJob < ApplicationJob
  def perform(model_name)
    PgSearch::Multisearch.rebuild(model_name.constantize)
  end
end
```

Trigger it from a migration's `up` (via `after_commit`, or a one-off rake task) instead of
running the rebuild inline — a multi-minute `UPDATE` across every row is exactly the
migration anti-pattern [[rails-migrations]] warns about.

## 7. When to Escalate Beyond Postgres

Stay on `pg_search` until a **specific, measured** requirement demands more:

| Need | Signal it's time to escalate |
|---|---|
| Typo tolerance beyond trigram, relevance tuning, facets/filters at scale | `pg_trgm` matches feel wrong even after tuning `threshold`, or query latency climbs with table size despite GIN indexes |
| Faceted search (filter by category + price range + rating, all with counts) | Building it by hand in SQL becomes a maze of `GROUP BY`/`HAVING` |
| Search volume that competes with transactional queries for DB resources | `pg_search` queries show up as the slowest queries in production APM against the primary DB |
| Geo-distance ranking, synonyms, ML-based relevance | Postgres has partial answers (`earthdistance`, manual synonym tables) that don't compose well past a point |

**Escalation ladder**, cheapest integration first:

1. **[Meilisearch](https://www.meilisearch.com/)** or **[Typesense](https://typesense.org/)** — self-hosted, typo-tolerant out of the box, simple JSON HTTP API; good next step when trigram tuning plateaus.
2. **[Elasticsearch](https://www.elastic.co/)/OpenSearch** — full faceting, aggregations, and relevance control, at the cost of running and syncing a second datastore (reach for the `searchkick` or `elasticsearch-rails` gems to keep the sync code out of your models).
3. **[Algolia](https://www.algolia.com/)** — hosted, fastest to integrate, per-record pricing; reach for it when you'd rather pay than run infrastructure.

Whichever you pick, keep the sync one-directional and asynchronous (an `after_commit` hook
enqueuing an index job — see §6) so a search-service outage never blocks a save.

## 8. Testing Search

Test against real Postgres (fixtures/transactional tests already run against it) rather than
stubbing the scope — a `pg_search_scope` is SQL, and the fastest way to ship a broken `against:`
weighting is to never actually run the query in a test:

```ruby
test "finds by title but not by unrelated description text" do
  matching = cards(:invoice_dashboard)
  other = cards(:unrelated_card)

  results = Card.search_full_text("invoice")

  assert_includes results, matching
  assert_not_includes results, other
end
```

For trigram/autocomplete, assert the typo-tolerant case explicitly — it's the one a plain
`tsearch` test would pass without proving anything about fuzziness:

```ruby
test "autocomplete tolerates a typo" do
  assert_includes Card.search_autocomplete("stratgey"), cards(:strategy_doc)
end
```
