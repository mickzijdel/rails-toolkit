---
name: rails-project-setup
description: Use when setting up a new Rails 8 project with modern stack (Solid Queue, Solid Cache, Solid Cable, Kamal deployment)
---

# Rails 8 Project Setup

## 1. Gemfile Essentials

The Solid Stack (solid_queue, solid_cache, solid_cable) plus propshaft, importmap-rails, kamal, and thruster — a complete Rails 8 setup with no Redis dependency.

```ruby
# cooldown: gems must be public 4 days before resolving (supply-chain defense, Bundler 4.0.6+)
source "https://rubygems.org", cooldown: 4

gem "rails", "~> 8.1"

# Assets & front end
gem "importmap-rails"   # JavaScript without Node bundling
gem "propshaft"         # modern asset pipeline (replaces Sprockets)
gem "stimulus-rails"
gem "turbo-rails"

# Deployment and drivers
gem "bootsnap", require: false
gem "kamal", require: false    # zero-downtime deployment
gem "puma", ">= 5.0"
gem "solid_cable", ">= 3.0"    # database-backed ActionCable
gem "solid_cache", "~> 1.0"    # database-backed cache store
gem "solid_queue", "~> 1.2"    # database-backed job queue
gem "sqlite3", ">= 2.0"
gem "thruster", require: false # HTTP/2 proxy (replaces nginx for simple setups)
gem "trilogy", "~> 2.9"        # MySQL adapter, faster than mysql2

# Operations
gem "mission_control-jobs"     # web UI for Solid Queue
```

**Bundler cooldown (supply-chain defense):**
- `cooldown: 4` on the `source` line means gems must have been public for 4 days before Bundler will resolve them, so freshly-hijacked releases can be vetted/yanked first ([announcement](https://blog.rubygems.org/2026/06/03/cooldown-let-new-gems-be-vetted.html), Bundler 4.0.6+).
- Complement it machine-wide with `bundle config set --global cooldown 4`; the explicit per-Gemfile line documents the policy and survives global-config changes.
- Scope: own projects only — never add it to vendored gem Gemfiles, `.ruby-lsp/Gemfile`, or appraisal gemfiles.

**Vite + pnpm apps (alternative front-end stack):**
- importmap-rails/no-Node is the default for *new* apps, but apps with heavier JavaScript needs may run **Vite** (+ Tailwind, Stimulus) alongside Propshaft, with Propshaft still serving page-specific assets from `app/assets`. Don't migrate such an app to importmaps.
- When Node packages are involved, use **pnpm** — not npm, yarn, or bun.

### Optional add-on gems (beyond the defaults)

The stack above is everything a new app *needs*. The toolkit blesses a short list of add-ons beyond it — reach for each only when the need is real; the linked skill covers it in depth.

```ruby
# Gemfile — add only what the app actually uses
gem "simple_form"     # form-builder DSL (DRYs labels/wrappers); plain `form_with` is fine too
gem "friendly_id"     # SEO slugs in URLs — see [[rails-models]]
gem "pundit"          # per-resource authorization policies — see [[rails-security]]

group :development, :test do
  gem "stackprof"       # CPU/wall profiler — see [[rails-performance]] / [[rails-testing]]
  gem "test-prof"       # test-suite profiling (mainly inherited factory suites) — see [[rails-testing]]
end

group :test do
  gem "shoulda-matchers" # one-line model declaration checks — see [[rails-testing]]
  gem "shoulda-context"  # `should` macro for Minitest
end
```

**Already standard elsewhere in the toolkit** (don't re-decide these): `pagy` (pagination — [[rails-api]]), `prosopite` (N+1 detection — [[rails-performance]]), `simplecov` + `simplecov_json_formatter` (coverage — [[rails-testing]]), `bundler-audit` + `brakeman` (security audit — [[rails-audit]]).

**Deliberately *not* recommended** (a default already covers the need): `kaminari` → use `pagy`; `bullet` → use `prosopite`; `good_job` → use `solid_queue`; `devise` → Rails 8 built-in auth ([[rails-security]]); `factory_bot`/`faker` → fixtures-first ([[rails-testing]]); `dry-rb`/Sorbet/`reek` → against the vanilla-Rails grain ([[rails-philosophy]]).

---

## 2. Solid Queue Configuration

`config/queue.yml` defines dispatchers and workers, with process counts derived from CPU count:

```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: [ "default", "solid_queue_recurring" ]
      threads: 3
      processes: <%= Integer(ENV.fetch("JOB_CONCURRENCY") { Concurrent.physical_processor_count }) %>
      polling_interval: 0.1

development: *default
test: *default
production: *default
```

For queue *naming* (SLO tiers, worker-per-queue), see [[rails-jobs]] Pattern 5.

```ruby
# config/puma.rb — run Solid Queue inside Puma, no separate worker process
unless ENV["SOLID_QUEUE_IN_PUMA"] == "false"
  plugin :solid_queue
end
```

---

## 3. Solid Cache Configuration

```yaml
# config/cache.yml
default_options: &default_options
  store_options:
    max_age: <%= 60.days.to_i %>
    namespace: <%= Rails.env %>   # isolate cache per environment

default_connection: &default_connection
  database: cache

default: &default
  <<: *default_connection
  <<: *default_options

development: *default
test: *default_options
production: *default
```

---

## 4. Solid Cable Configuration

```yaml
# config/cable.yml
cable: &cable
  adapter: solid_cable
  connects_to:
    database:
      writing: cable
      reading: cable
  polling_interval: 0.1.seconds
  message_retention: 1.day

development: *cable
test:
  adapter: test
production: *cable
```

---

## 5. Database Setup (Multiple Databases)

Separate databases for primary data, cache, queue, and cable prevent contention and allow independent scaling. Each gets its own `migrations_paths`.

```yaml
# SQLite
default: &default
  adapter: sqlite3
  pool: 5
  timeout: 5000

production:
  primary:
    <<: *default
    database: storage/production.sqlite3
    schema_dump: schema_sqlite.rb
  cable:
    <<: *default
    database: storage/production_cable.sqlite3
    migrations_paths: db/cable_migrate
  cache:
    <<: *default
    database: storage/production_cache.sqlite3
    migrations_paths: db/cache_migrate
  queue:
    <<: *default
    database: storage/production_queue.sqlite3
    migrations_paths: db/queue_migrate
```

```yaml
# MySQL via trilogy — note the much larger pool in production
default: &default
  adapter: trilogy
  host: <%= ENV.fetch("MYSQL_HOST", "127.0.0.1") %>
  port: <%= ENV.fetch("MYSQL_PORT", "3306") %>
  username: <%= ENV.fetch("MYSQL_USER", "root") %>
  password: <%= ENV["MYSQL_PASSWORD"] %>
  pool: 50
  timeout: 5000

production:
  primary:
    <<: *default
    database: app_production
  cable:
    <<: *default
    database: app_production_cable
    migrations_paths: db/cable_migrate
  queue:
    <<: *default
    database: app_production_queue
    migrations_paths: db/queue_migrate
  cache:
    <<: *default
    database: app_production_cache
    migrations_paths: db/cache_migrate
```

---

## 6. Kamal Deployment

`config/deploy.yml`: servers, automatic SSL via the proxy, secrets from `.kamal/secrets`, and persistent volumes for SQLite/Active Storage.

```yaml
service: app
image: app

servers:
  web:
    - app.example.com

ssh:
  user: root

# Automatic SSL
proxy:
  ssl: true
  host: app.example.com

# Secrets come from .kamal/secrets; clear vars are plain
env:
  secret:
    - SECRET_KEY_BASE
    - SMTP_USERNAME
    - SMTP_PASSWORD
  clear:
    BASE_URL: https://app.example.com
    SOLID_QUEUE_IN_PUMA: true    # jobs run in the web container

registry:
  server: localhost:5555

aliases:
  console: app exec --interactive --reuse "bin/rails console"
  shell: app exec --interactive --reuse "bash"
  logs: app logs -f
  dbc: app exec --interactive --reuse "bin/rails dbconsole --include-password"

# Persistent storage for sqlite and Active Storage
volumes:
  - "app_storage:/rails/storage"

# Bridge assets between versions during zero-downtime deploys
asset_path: /rails/public/assets

builder:
  arch: amd64
```

---

## 7. Dockerfile Best Practices

Multi-stage build with jemalloc, bootsnap precompilation, and a non-root user:

```dockerfile
# syntax=docker/dockerfile:1
# check=error=true

ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 libssl-dev && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Build stage
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock vendor ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

COPY . .

RUN bundle exec bootsnap precompile -j 1 app/ lib/
# SECRET_KEY_BASE_DUMMY=1 allows asset precompilation without real secrets
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage
FROM base

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
```

```bash
#!/bin/bash -e
# bin/docker-entrypoint — auto-migrate on deploy when starting the server
if [ "${1}" == "./bin/thrust" ] && [ "${2}" == "./bin/rails" ] && [ "${3}" == "server" ]; then
  MIGRATE=1 ./bin/rails db:prepare
fi

exec "${@}"
```

---

## 8. Recurring Jobs Configuration

Scheduled tasks live in `config/recurring.yml`:

```yaml
production: &production
  cleanup_magic_links:
    command: "MagicLink.cleanup"
    schedule: every 4 hours
```

Full pattern (command vs class, Solid Queue maintenance entries, schedule syntax): [[rails-jobs]] Pattern 4.

---

## 9. Puma Configuration for Production

Workers per CPU, single thread per worker (optimal for SQLite's low I/O wait), copy-on-write warmup, and GC deferred to between requests:

```ruby
# config/puma.rb
port ENV.fetch("PORT", 3000)
plugin :tmp_restart

unless ENV["SOLID_QUEUE_IN_PUMA"] == "false"
  plugin :solid_queue
end

if !Rails.env.local?
  # 1 worker per CPU, 1 thread per worker (optimal for SQLite)
  workers Integer(ENV.fetch("WEB_CONCURRENCY") { Concurrent.physical_processor_count })
  threads 1, 1

  # Optimize for copy-on-write
  before_fork do
    Process.warmup
  end

  # Defer major GC until after request handling
  before_worker_boot do
    GC.config(rgengc_allow_full_mark: false)
  end

  out_of_band do
    GC.start if GC.latest_gc_info(:need_major_by)
  end
end
```

---

## Quick Reference

### New Project Checklist

1. Add Solid Stack gems to Gemfile (with `cooldown: 4` on the source line)
2. Create `config/queue.yml`, `config/cache.yml`, `config/cable.yml`
3. Configure multiple databases in `config/database.yml`
4. Add `plugin :solid_queue` to `config/puma.rb`
5. Create `config/deploy.yml` for Kamal
6. Create production Dockerfile with jemalloc and bootsnap
7. Set up `config/recurring.yml` for scheduled tasks
8. Configure `bin/docker-entrypoint` for auto-migrations

### Environment Variables

```bash
# Required secrets (in .kamal/secrets)
SECRET_KEY_BASE=...
RAILS_MASTER_KEY=...

# Database (for MySQL)
MYSQL_HOST=127.0.0.1
MYSQL_PASSWORD=...

# Concurrency tuning
WEB_CONCURRENCY=4        # Puma workers
JOB_CONCURRENCY=4        # Solid Queue processes
SOLID_QUEUE_IN_PUMA=true # Run jobs in web process
```
