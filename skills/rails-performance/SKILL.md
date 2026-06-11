---
name: rails-performance
description: Use when optimizing performance with caching, ETags, batching, and N+1 prevention
---

# Rails Performance Patterns

## When to Use
- Optimizing database queries
- Adding view caching
- Preventing N+1 queries
- Improving response times

---

## 1. Fragment Caching in Views

**Problem:** Views re-render expensive partials on every request.

**Solution:** Use `<% cache do %>` blocks to cache rendered HTML fragments.

**Example:**
```erb
<%# app/views/cards/_container.html.erb %>
<section id="<%= dom_id(card, :card_container) %>" class="card-perma">
  <% cache card do %>
    <div class="card-perma__actions">
      <%= render "cards/container/gild", card: card %>
      <%= render "cards/container/image", card: card %>
    </div>

    <div class="card-perma__bg">
      <%= card_article_tag card, class: "card" do %>
        <%= render "cards/display/perma/board", card: card %>
        <%= render "cards/display/perma/tags", card: card %>
      <% end %>
    </div>
  <% end %>
</section>
```

```erb
<%# app/views/events/_event.html.erb %>
<% cache event do %>
  <article class="event">
    <%= render "events/#{event.action}", event: event %>
  </article>
<% end %>
```

**Source:** [app/views/cards/_container.html.erb](app/views/cards/_container.html.erb), [app/views/events/_event.html.erb](app/views/events/_event.html.erb)

**Key Points:**
- Cache key is automatically derived from the record's `cache_key_with_version`
- Cache invalidates when the record's `updated_at` changes
- Nest cache blocks for granular invalidation

---

## 2. Collection Caching

**Problem:** Rendering collections of partials is slow without caching.

**Solution:** Use `cached: true` with collection rendering.

**Example:**
```erb
<%# app/views/cards/_messages.html.erb %>
<div class="messages">
  <%= render partial: "cards/comments/comment",
             collection: card.comments.preloaded.chronologically,
             cached: true %>
</div>
```

```erb
<%# app/views/public/boards/show/_columns.html.erb %>
<div class="columns">
  <%= render partial: "public/boards/show/column",
             collection: board.columns,
             cached: true %>
</div>
```

```erb
<%# app/views/cards/previews/index.turbo_stream.erb %>
<%= turbo_stream.append "cards" do %>
  <%= render partial: "cards/display/preview",
             collection: @page.records,
             as: :card,
             cached: true %>
<% end %>
```

**Source:** [app/views/cards/_messages.html.erb](app/views/cards/_messages.html.erb), [app/views/public/boards/show/_columns.html.erb](app/views/public/boards/show/_columns.html.erb)

**Key Points:**
- `cached: true` caches each item in the collection individually
- Rails uses `read_multi` to fetch all cached items in one call
- Combine with `preloaded` scope to avoid N+1 during rendering

---

## 3. JSON Caching

**Problem:** JSON API responses rebuild on every request.

**Solution:** Use `json.cache!` in Jbuilder templates.

**Example:**
```ruby
# app/views/webhooks/event.json.jbuilder
json.cache! @event do
  json.id @event.id
  json.action @event.action
  json.created_at @event.created_at
  json.eventable do
    json.partial! @event.eventable
  end
end
```

```ruby
# app/views/users/_user.json.jbuilder
json.cache! user do
  json.id user.id
  json.name user.name
  json.email user.email_address
end
```

```ruby
# app/views/cards/_card.json.jbuilder
json.cache! card do
  json.id card.id
  json.number card.number
  json.title card.title
  json.status card.status
end
```

**Source:** [app/views/webhooks/event.json.jbuilder](app/views/webhooks/event.json.jbuilder), [app/views/users/_user.json.jbuilder](app/views/users/_user.json.jbuilder)

---

## 4. Don't Over-Cache: The "Fast N+1" Anti-Pattern

**Problem:** Granular `Rails.cache.fetch` calls scattered through models and helpers turn a list page into dozens or hundreds of cache round-trips — an N+1 made of cache reads instead of queries. Each read is a network hop to Memcached/Redis; a hot DB query (primary-key lookup from buffer pool) is often *faster* than the cache round-trip it was "optimized" into.

**Real example (Speedshop's AO3 audit):** one bookmarks index page produced 179 cache operations — roughly 8 separate cache keys per rendered row (blurb, byline, kudos count, comment count, CSS classes...). The fix is one fragment per row.

**Solution:**
- Consolidate per-row cache calls into a single view-layer fragment cache per row (Patterns 1–2). The fragment caches the HTML *and* every query behind it, in one round-trip.
- Don't cache queries that are already ~1ms (single-row lookups, tiny tables read on every request). The cache read costs as much as the query and adds invalidation complexity for nothing.

```ruby
# ❌ Bad: helper-level micro-caches, hit once per row
def bookmark_count(work)
  Rails.cache.fetch([work, "bookmark_count"]) { work.bookmarks.count }
end

def byline(work)
  Rails.cache.fetch([work, "byline"]) { render_byline(work) }
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
- Rule of thumb: only cache when regeneration costs meaningfully more than the ~1ms cache round-trip.
- Collection caching (`cached: true`, Pattern 2) fetches all row fragments in a single `read_multi` — the end state to aim for.

---

## 5. ETags for HTTP Caching

**Problem:** Clients re-download unchanged content.

**Solution:** Use `fresh_when` and `stale?` to leverage HTTP caching.

**Example:**
```ruby
# app/controllers/my/pins_controller.rb
def index
  @pins = Current.user.pins.ordered
  fresh_when etag: [ @pins, @pins.collect(&:card) ]
end

# app/controllers/my/menus_controller.rb
def show
  fresh_when etag: [ @filters, @boards, @tags, @users, @accounts ]
end

# app/controllers/events_controller.rb
def index
  fresh_when @day_timeline
end

# app/controllers/boards_controller.rb
def show
  if stale?(etag: [ @board, @page.records, @user_filtering, Current.account ])
    respond_to do |format|
      format.html
      format.json
    end
  end
end
```

**With conditional rendering:**
```ruby
# app/controllers/prompts/users_controller.rb
def index
  @users = Current.account.users.active.alphabetically

  if stale? etag: @users
    render partial: "users/user", collection: @users
  end
end

# app/controllers/users/avatars_controller.rb
def show
  if @user.avatar.attached?
    redirect_to @user.avatar
  elsif stale? @user, cache_control: cache_control
    render
  end
end
```

**Source:** [app/controllers/my/pins_controller.rb](app/controllers/my/pins_controller.rb), [app/controllers/boards_controller.rb](app/controllers/boards_controller.rb)

**Key Points:**
- `fresh_when` automatically handles 304 Not Modified responses
- ETags are computed from the cache keys of all provided objects
- Use arrays to combine multiple objects into one ETag
- `stale?` returns true if the response needs to be rendered

---

## 6. Global ETags

**Problem:** ETags need to change when common elements change (e.g., assets).

**Solution:** Add global ETag components in ApplicationController.

**Example:**
```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  etag { "v1" }
  stale_when_importmap_changes
  allow_browser versions: :modern
end
```

**Source:** [app/controllers/application_controller.rb](app/controllers/application_controller.rb)

**Key Points:**
- `etag { "v1" }` adds a version string to all ETags
- Bump the version to invalidate all client caches
- `stale_when_importmap_changes` invalidates when JS changes

---

## 7. Preloading Scopes (N+1 Prevention)

**Problem:** Accessing associations in loops causes N+1 queries.

**Solution:** Create named scopes that preload all needed associations.

**Example:**
```ruby
# app/models/card.rb
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

# app/models/comment.rb
class Comment < ApplicationRecord
  scope :preloaded, -> {
    with_rich_text_body.includes(reactions: :reacter)
  }
end

# app/models/notification.rb
class Notification < ApplicationRecord
  scope :preloaded, -> {
    preload(:creator, :account,
            source: [ :board, :creator,
                     { eventable: [ :closure, :board, :assignments ] } ])
  }
end

# app/models/event.rb
class Event < ApplicationRecord
  scope :preloaded, -> {
    includes(:creator, :board, eventable: [ :board, :assignments, :closure ])
  }
end
```

**Usage:**
```ruby
# In controller
@cards = Current.user.accessible_cards.preloaded.published
@notifications = Current.user.notifications.preloaded.unread
```

**Source:** [app/models/card.rb](app/models/card.rb), [app/models/notification.rb](app/models/notification.rb)

**Key Points:**
- Name the scope `preloaded` for consistency
- Use `preload` for separate queries, `includes` for joins when filtering
- Include nested associations with hash syntax
- Use `with_rich_text_*_and_embeds` for ActionText

---

## 8. N+1 Detection with Prosopite

**Problem:** Preloading scopes (Pattern 7) prevent N+1s you know about, but nothing stops new ones from shipping.

**Solution:** Use the `prosopite` gem to detect N+1 queries and make them fail the test suite. Prosopite has near-zero false positives (unlike Bullet, which both misses N+1s and flags non-issues).

**Example:**
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

**Rolling out on an existing app with known N+1s:**
1. Install and log in development first; fix what's cheap to fix.
2. Enable scanning per test class (a tag/concern), starting with classes that are already clean.
3. Expand coverage as you remediate; keep a short ignore list (`Prosopite.allow_stack_paths = [...]`) for the final holdouts.
4. End state: `raise = true` suite-wide, so no feature ships with a proven N+1.

**Key Points:**
- Prosopite watches the query log for repeated query fingerprints — detection is accurate enough to `raise` on.
- Pair with Pattern 7: the detector finds the N+1, the `preloaded` scope is the fix.

---

## 9. Preload the Session User's Associations

**Problem:** Permission checks (`current_user.roles`, `current_user.admin?`, feature flags) run all over views and controllers. If the association isn't loaded, each check is another query — on every request.

**Solution:** Eager-load the associations that authorization touches at the moment the session user is materialized, so the rest of the request reads from memory.

**Example (Rails 8 Authentication concern):**
```ruby
# app/models/session.rb / authentication concern
def find_session_by_cookie
  Session.includes(user: :roles).find_by(id: cookies.signed[:session_id])
end
```

**Example (Devise):**
```ruby
# app/models/user.rb
def self.serialize_from_session(key, salt)
  record = includes(:roles).where(primary_key => key).first
  record if record && record.authenticatable_salt == salt
end
```

**Key Points:**
- Route permission checks through one method (`has_role?(name)`) that works on the loaded collection (`roles.loaded?` → `any? { ... }`), instead of `roles.where(...)` calls that bypass the preload.
- Only preload what authorization actually touches every request — this is not a license to `includes` the world.

---

## 10. Batching Operations

**Problem:** Loading/processing thousands of records at once uses too much memory.

**Solution:** Use `find_each` and `in_batches` for large collections.

**Example:**
```ruby
# app/models/concerns/storage/tracked.rb
BATCH_SIZE = 1000

def process_attachments
  attachable_ids.find_each(batch_size: BATCH_SIZE) do |id|
    process_attachment(id)
  end
end

# config/recurring.yml - Solid Queue cleanup with batching
clear_solid_queue_finished_jobs:
  command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
  schedule: every hour at minute 12

# app/models/search/record.rb
def self.reindex_all
  Card.find_each(batch_size: 1000) do |card|
    card.update_search_record
  end
end
```

**Source:** [app/models/concerns/storage/tracked.rb](app/models/concerns/storage/tracked.rb), [config/recurring.yml](config/recurring.yml)

**Key Points:**
- `find_each` yields records one at a time, loading in batches
- `in_batches` yields ActiveRecord::Relation objects
- Default batch size is 1000, adjust based on memory constraints
- Add `sleep_between_batches` for long-running jobs to reduce load

---

## 11. Keyset Pagination (Geared Pagination)

**Problem:** Offset-based pagination (`LIMIT/OFFSET`) is slow for large datasets.

**Solution:** Use keyset pagination with the `geared_pagination` gem.

**Example:**
```ruby
# Gemfile
gem "geared_pagination", "~> 1.2"

# app/controllers/boards_controller.rb
def show
  @page = set_page_and_extract_portion_from(
    @board.cards.preloaded.published.sorted_by(@filter.sort),
    per_page: [ 15, 30, 50, 100 ]
  )

  fresh_when etag: [ @board, @page.records ]
end
```

```erb
<%# app/views/boards/show.html.erb %>
<%= render @page.records %>

<% if @page.last? %>
  <p>No more cards</p>
<% else %>
  <%= link_to "Load more",
              board_path(@board, page: @page.next_param),
              data: { turbo_stream: true } %>
<% end %>
```

**Source:** [app/controllers/boards_controller.rb](app/controllers/boards_controller.rb)

**Key Points:**
- Keyset pagination uses cursor-based navigation (faster than OFFSET)
- `per_page: [15, 30, 50, 100]` provides "geared" page sizes
- First page loads 15, later pages load more as users scroll
- Use `@page.last?` to check if there are more records

---

## 12. Public Cache Headers

**Problem:** Public pages don't leverage CDN/browser caching.

**Solution:** Set cache headers for public content.

**Example:**
```ruby
# app/controllers/public/base_controller.rb
class Public::BaseController < ApplicationController
  allow_unauthenticated_access

  before_action :set_board, :set_card, :set_public_cache_expiration

  layout "public"

  private
    def set_public_cache_expiration
      expires_in 30.seconds, public: true
    end
end
```

**Source:** [app/controllers/public/base_controller.rb](app/controllers/public/base_controller.rb)

**Key Points:**
- `public: true` allows CDNs to cache the response
- Use short TTLs (30 seconds) for dynamic content
- Combine with ETags for validation

---

## 13. Read Replicas for GETs and Read-Only Jobs

**Problem:** The SQL primary is the hardest thing to scale; web requests and background jobs pile read load onto it while replicas sit idle.

**Solution:** Use Rails multi-database role switching to move read-only work to replicas — both web GETs and dedicated read-only job queues.

**Web requests (automatic role switching):**
```ruby
# config/environments/production.rb
config.active_record.database_selector = { delay: 2.seconds }
config.active_record.database_resolver = ActiveRecord::Middleware::DatabaseSelector::Resolver
config.active_record.database_resolver_context = ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
```

GET/HEAD requests go to the replica; for 2 seconds after any write, that browser session reads from the primary ("read your own writes"), so replication lag doesn't show users stale data they just changed. Before enabling, audit GET actions for side-effect writes (tracking columns, counters) — those will raise on a replica.

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
- Replica reads tolerate replication lag — only route work where slightly stale data is acceptable.
- Watch the metric that matters: active (non-idle) connections on the primary. A healthy target is at most ~50% of the database's CPU count.

---

## 14. Graceful Degradation for Non-Critical Datastores

**Problem:** Search and autocomplete backends (Elasticsearch, Redis) fail hard by default: 30-second client timeouts and unrescued errors mean a degraded search cluster ties up every Puma thread and takes the whole app down — an outage caused by a feature the page didn't need.

**Solution:** Treat non-critical datastores as best-effort. Bound every call, rescue failures, and render the page without the feature.

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
- Put a hard `LIMIT` on range reads. An autocomplete that runs `zrevrangebyscore` over thousands of entries and then truncates to 15 in Ruby should pass `limit: [0, 50]` to Redis instead.
- Redis is single-threaded: one unbounded query blocks every other client of that Redis. Slow autocomplete can stall sessions/caching sharing the instance.
- Add a circuit breaker (e.g. `circuitbox`, or Faraday retry/breaker middleware) so a down dependency fails in microseconds instead of holding threads for the timeout.
- Cache popular lookups in a small process-local LRU (`ActiveSupport::Cache::MemoryStore.new(size: 10.megabytes)`) — popular autocomplete prefixes are highly repetitive.

---

## 15. Autotuner for GC Optimization

**Problem:** Default Ruby GC settings aren't optimized for web workloads.

**Solution:** Use the `autotuner` gem for automatic GC tuning.

**Example:**
```ruby
# Gemfile
gem "autotuner"

# config/puma.rb
if ENV["RAILS_ENV"] == "production"
  # Report GC tuning suggestions
  Autotuner.report
end
```

**Source:** [Gemfile](Gemfile)

**Key Points:**
- Autotuner analyzes GC behavior and suggests tuning
- Reports heuristics for optimal `RUBY_GC_*` environment variables
- Particularly helpful for memory-constrained environments

---

## 16. YJIT

**Problem:** Plain Ruby interpretation leaves easy throughput on the table.

**Solution:** Enable YJIT — but treat it as a memory-for-speed trade, not a free win.

**Example:**
```ruby
# config/initializers/yjit.rb (or set RUBY_YJIT_ENABLE=1)
RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)
```

**Key Points:**
- Expect roughly 10–15% more throughput for 20–30% more memory per process.
- Rails 7.2+ enables YJIT automatically on Ruby 3.3+ — check `application.rb` and initializers for an explicit *disable* left behind from an older Ruby, and remove it.
- Skip it only when memory-constrained (small containers where the extra RSS would force fewer Puma workers).

---

## 17. Thruster HTTP/2 Proxy

**Problem:** Direct Puma connections lack HTTP/2 and compression.

**Solution:** Use Thruster as a lightweight proxy in front of Puma.

**Example:**
```ruby
# Gemfile
gem "thruster", require: false

# Dockerfile
CMD ["./bin/thrust", "./bin/rails", "server"]
```

```ruby
# config/puma.rb
# Thruster provides:
# - HTTP/2 support
# - Automatic SSL termination
# - Gzip compression
# - X-Sendfile support for static files
```

**Source:** [Gemfile](Gemfile), [Dockerfile](Dockerfile)

---

## 18. Jemalloc for Memory Efficiency

**Problem:** Ruby's default memory allocator can lead to memory bloat.

**Solution:** Use jemalloc in production Docker images.

**Example:**
```dockerfile
# Dockerfile
FROM docker.io/library/ruby:3.4.7-slim AS base

# Install jemalloc for better memory management
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libjemalloc2

# Use jemalloc as the memory allocator
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
```

**Source:** [Dockerfile](Dockerfile)

**Key Points:**
- Jemalloc reduces memory fragmentation
- Set via `LD_PRELOAD` environment variable
- Can reduce memory usage by 20-30%

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| `<% cache record do %>` | Cache expensive view fragments |
| `cached: true` | Cache collection partials |
| `json.cache!` | Cache JSON responses |
| `fresh_when etag:` | HTTP caching with ETags |
| `scope :preloaded` | Prevent N+1 queries |
| `find_each` | Process large collections |
| `geared_pagination` | Fast cursor-based pagination |
| `expires_in` | Set cache TTL headers |
| One fragment per row | Replace granular `Rails.cache.fetch` calls ("fast N+1") |
| `prosopite` | Detect N+1s, fail the suite on them |
| `includes(user: :roles)` at session load | Preload per-request permission checks |
| `connected_to(role: :reading)` | Route GETs / read-only jobs to replicas |
| Timeouts + rescue → degraded 200 | Keep search/autocomplete failures from becoming outages |
| `autotuner` | Optimize GC settings |
| YJIT | +10–15% throughput for +20–30% memory |
| `thruster` | HTTP/2 proxy |
| `jemalloc` | Memory efficiency |

| Scope Pattern | Example |
|---------------|---------|
| Basic preload | `preload(:creator, :board)` |
| Nested preload | `preload(board: [:columns, :entropy])` |
| ActionText | `with_rich_text_description_and_embeds` |
| Includes for filtering | `includes(:tags).where(tags: { title: "bug" })` |
