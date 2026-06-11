---
name: rails-performance
description: Use when optimizing performance with caching, ETags, batching, and N+1 prevention
---

# Rails Performance Patterns

## 1. Fragment Caching in Views

Cache expensive partials with `<% cache record do %>`. The key derives from `cache_key_with_version`, so the fragment invalidates when the record's `updated_at` changes. Nest cache blocks for granular invalidation.

```erb
<% cache card do %>
  <div class="card-perma__actions">
    <%= render "cards/container/gild", card: card %>
    <%= render "cards/container/image", card: card %>
  </div>
  <%= card_article_tag card, class: "card" do %>
    <%= render "cards/display/perma/board", card: card %>
    <%= render "cards/display/perma/tags", card: card %>
  <% end %>
<% end %>
```

---

## 2. Collection Caching

`cached: true` on collection renders caches each item individually and fetches all of them in one `read_multi` call. Combine with a `preloaded` scope (Pattern 7) to avoid N+1 during rendering.

```erb
<%= render partial: "cards/comments/comment",
           collection: card.comments.preloaded.chronologically,
           cached: true %>
```

---

## 3. JSON Caching

Use `json.cache!` in Jbuilder templates:

```ruby
json.cache! @event do
  json.id @event.id
  json.action @event.action
  json.eventable do
    json.partial! @event.eventable
  end
end
```

---

## 4. Don't Over-Cache: The "Fast N+1" Anti-Pattern

Granular `Rails.cache.fetch` calls scattered through models and helpers turn a list page into dozens or hundreds of cache round-trips — an N+1 made of cache reads instead of queries. Each read is a network hop to Memcached/Redis; a hot DB query (primary-key lookup from buffer pool) is often *faster* than the cache round-trip it was "optimized" into.

**Real example (Speedshop's AO3 audit):** one bookmarks index page produced 179 cache operations — roughly 8 separate cache keys per rendered row (blurb, byline, kudos count, comment count, CSS classes...). The fix is one fragment per row.

```ruby
# ❌ Bad: helper-level micro-caches, hit once per row
def bookmark_count(work)
  Rails.cache.fetch([work, "bookmark_count"]) { work.bookmarks.count }
end
```

```erb
<%# ✅ Good: one fragment per row covers all of it %>
<% cache work do %>
  <%= render "works/blurb", work: work %>
<% end %>
```

**Key Points:**
- Cache at the highest level that invalidates correctly — usually the HTML fragment, not the individual query.
- Only cache when regeneration costs meaningfully more than the ~1ms cache round-trip; don't cache single-row lookups or tiny always-hot tables.
- Collection caching (Pattern 2) is the end state: all row fragments in a single `read_multi`.

---

## 5. ETags for HTTP Caching

`fresh_when` computes an ETag from the cache keys of the given objects and handles 304 Not Modified automatically. Use `stale?` when rendering is conditional.

```ruby
def index
  @pins = Current.user.pins.ordered
  fresh_when etag: [ @pins, @pins.collect(&:card) ]   # arrays combine objects
end

# optional resource: fall back to a literal so "absent" is cacheable too
def show_watch
  fresh_when etag: @card.watch_for(Current.user) || "none"
end

def show
  if stale?(etag: [ @board, @page.records, @user_filtering, Current.account ])
    respond_to do |format|
      format.html
      format.json
    end
  end
end
```

---

## 6. Global ETags

Add global ETag components in ApplicationController so all ETags change when shared elements change:

```ruby
class ApplicationController < ActionController::Base
  etag { "v1" }                    # bump to invalidate all client caches
  stale_when_importmap_changes     # invalidates when JS changes
end
```

---

## 7. Preloading Scopes (N+1 Prevention)

Create a named `preloaded` scope per model that preloads everything its standard rendering touches.

```ruby
class Card < ApplicationRecord
  scope :preloaded, -> {
    with_users
      .preload(:column, :tags, :steps, :closure, :goldness,
               :activity_spike, :image_attachment,
               board: [ :entropy, :columns ],
               not_now: [ :user ])
      .with_rich_text_description_and_embeds
  }

  scope :with_users, -> {
    preload(:creator, assignments: :user)
  }
end

# In controller
@cards = Current.user.accessible_cards.preloaded.published
```

**Key Points:**
- Name the scope `preloaded` for consistency.
- Use `preload` for separate queries, `includes` when you need to filter on the association.
- Use `with_rich_text_*_and_embeds` for ActionText (see [[rails-activestorage]] for attachment preload names).

---

## 8. N+1 Detection with Prosopite

Preloading scopes prevent the N+1s you know about; `prosopite` stops new ones from shipping. It watches the query log for repeated query fingerprints with near-zero false positives (unlike Bullet, which both misses N+1s and flags non-issues) — accurate enough to `raise` on.

```ruby
# Gemfile
group :development, :test do
  gem "prosopite"
end

# test/test_helper.rb
Prosopite.rails_logger = true
Prosopite.raise = true

module ActiveSupport
  class TestCase
    setup    { Prosopite.scan }
    teardown { Prosopite.finish }
  end
end
```

**Rolling out on an existing app with known N+1s:** install and log in development first; enable scanning per test class starting with the clean ones; keep a short ignore list (`Prosopite.allow_stack_paths = [...]`) for the final holdouts; end state is `raise = true` suite-wide.

---

## 9. Preload the Session User's Associations

Permission checks (`current_user.roles`, `current_user.admin?`, feature flags) run all over views and controllers — each unloaded association check is another query, on every request. Eager-load what authorization touches at the moment the session user is materialized.

```ruby
# Rails 8 Authentication concern
def find_session_by_cookie
  Session.includes(user: :roles).find_by(id: cookies.signed[:session_id])
end

# Devise equivalent
def self.serialize_from_session(key, salt)
  record = includes(:roles).where(primary_key => key).first
  record if record && record.authenticatable_salt == salt
end
```

**Key Points:**
- Route permission checks through one method (`has_role?(name)`) that works on the loaded collection, instead of `roles.where(...)` calls that bypass the preload.
- Only preload what authorization touches every request — not a license to `includes` the world.

---

## 10. Batching Operations

Use `find_each`/`in_batches` for large collections; add `sleep_between_batches`-style throttling for long-running cleanup.

```ruby
def self.reindex_all
  Card.find_each(batch_size: 1000) do |card|
    card.update_search_record
  end
end

# config/recurring.yml — Solid Queue cleanup with batching
clear_solid_queue_finished_jobs:
  command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
  schedule: every hour at minute 12
```

---

## 11. Keyset Pagination (Geared Pagination)

Offset pagination (`LIMIT/OFFSET`) degrades linearly with page number. Use cursor-based pagination via the `geared_pagination` gem; "geared" page sizes load 15 first, more as users scroll.

```ruby
def show
  @page = set_page_and_extract_portion_from(
    @board.cards.preloaded.published.sorted_by(@filter.sort),
    per_page: [ 15, 30, 50, 100 ]
  )
  fresh_when etag: [ @board, @page.records ]
end
```

```erb
<%= render @page.records %>
<% unless @page.last? %>
  <%= link_to "Load more", board_path(@board, page: @page.next_param), data: { turbo_stream: true } %>
<% end %>
```

---

## 12. Public Cache Headers

Let CDNs/browsers cache public pages — short TTLs for dynamic content, combined with ETags for validation:

```ruby
class Public::BaseController < ApplicationController
  allow_unauthenticated_access
  before_action :set_public_cache_expiration

  private
    def set_public_cache_expiration
      expires_in 30.seconds, public: true
    end
end
```

---

## 13. Read Replicas for GETs and Read-Only Jobs

The SQL primary is the hardest thing to scale; move read-only work to replicas — both web GETs and dedicated read-only job queues.

**Web requests (automatic role switching):**
```ruby
# config/environments/production.rb
config.active_record.database_selector = { delay: 2.seconds }
config.active_record.database_resolver = ActiveRecord::Middleware::DatabaseSelector::Resolver
config.active_record.database_resolver_context = ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
```

GET/HEAD requests go to the replica; for 2 seconds after any write, that browser session reads from the primary ("read your own writes"). Before enabling, audit GET actions for side-effect writes (tracking columns, counters) — those will raise on a replica.

**Background jobs (read-only queue variants):**
```ruby
# app/jobs/application_job.rb
around_perform do |job, block|
  if job.queue_name.to_s.end_with?("_read_only")
    ActiveRecord::Base.connected_to(role: :reading) { block.call }
  else
    block.call
  end
rescue ActiveRecord::ReadOnlyError
  # Job turned out to write — retry it on the writer queue
  job.class.set(queue: job.queue_name.to_s.delete_suffix("_read_only"))
     .perform_later(*job.arguments)
end
```

Duplicate heavy read-mostly queues (reports, exports, stat rollups) as `*_read_only` variants and move jobs over incrementally; the rescue is the safety net for jobs that unexpectedly write.

**Key Points:**
- Only route work where slightly stale data is acceptable.
- Watch active (non-idle) connections on the primary — healthy target is ≤ ~50% of the database's CPU count (see [[rails-database-performance]]).

---

## 14. Graceful Degradation for Non-Critical Datastores

Search and autocomplete backends (Elasticsearch, Redis) fail hard by default: 30-second client timeouts and unrescued errors mean a degraded search cluster ties up every Puma thread and takes the whole app down — an outage caused by a feature the page didn't need. Bound every call, rescue failures, render the page without the feature.

```ruby
# 1. Short client timeouts — never the 30s default
config = { transport_options: { request: { timeout: 2, open_timeout: 1 } } }

# 2. Server-side timeout inside the query itself
def search(query)
  client.search(body: { query: query, timeout: "2s" })
end

# 3. Rescue and degrade to a 200, not a 500
def results
  Work.search(params[:q])
rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Searchkick::Error
  SearchResults.unavailable   # page renders with a "search is unavailable" notice
end
```

**Key Points:**
- Put a hard `LIMIT` on range reads. An autocomplete that runs `zrevrangebyscore` over thousands of entries and truncates to 15 in Ruby should pass `limit: [0, 50]` to Redis instead.
- Redis is single-threaded: one unbounded query blocks every other client of that instance (sessions, caching).
- Add a circuit breaker (e.g. `circuitbox`, or Faraday retry/breaker middleware) so a down dependency fails in microseconds instead of holding threads for the timeout.
- Cache popular lookups in a small process-local LRU (`ActiveSupport::Cache::MemoryStore.new(size: 10.megabytes)`) — popular autocomplete prefixes are highly repetitive.

---

## 15. Runtime: YJIT, jemalloc, Autotuner, Thruster

- **YJIT** — a memory-for-speed trade, not a free win: roughly +10–15% throughput for +20–30% memory per process. Rails 7.2+ enables it automatically on Ruby 3.3+; check for an explicit *disable* left behind from an older Ruby and remove it. Skip only when memory-constrained.
- **jemalloc** — reduces memory fragmentation, often 20–30% less memory. In Docker: install `libjemalloc2`, set `ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2`.
- **autotuner** gem — analyzes GC behavior in production and suggests `RUBY_GC_*` tuning; call `Autotuner.report` from `config/puma.rb` in production.
- **thruster** — lightweight HTTP/2 proxy in front of Puma (`CMD ["./bin/thrust", "./bin/rails", "server"]`): HTTP/2, SSL termination, gzip, X-Sendfile. See [[rails-project-setup]].

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| `<% cache record do %>` | Cache expensive view fragments |
| `cached: true` | Cache collection partials (single `read_multi`) |
| `json.cache!` | Cache JSON responses |
| One fragment per row | Replace granular `Rails.cache.fetch` calls ("fast N+1") |
| `fresh_when etag:` / `etag { "v1" }` | HTTP caching with ETags |
| `scope :preloaded` | Prevent N+1 queries |
| `prosopite` | Detect N+1s, fail the suite on them |
| `includes(user: :roles)` at session load | Preload per-request permission checks |
| `find_each` | Process large collections |
| `geared_pagination` | Cursor-based pagination |
| `expires_in 30.seconds, public: true` | CDN/browser caching for public pages |
| `connected_to(role: :reading)` | Route GETs / read-only jobs to replicas |
| Timeouts + rescue → degraded 200 | Keep search/autocomplete failures from becoming outages |
| YJIT / jemalloc / autotuner / thruster | Runtime-level wins (memory trade-offs noted above) |
