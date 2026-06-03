---
name: rails-project-setup
description: Use when setting up a new Rails 8 project with modern stack (Solid Queue, Solid Cache, Solid Cable, Kamal deployment)
---

# Rails 8 Project Setup

## When to Use

- Starting a new Rails 8 project
- Adding Solid Stack to an existing project
- Setting up Kamal deployment
- Configuring multiple databases for cache, queue, and cable
- Creating production-ready Dockerfiles

---

## 1. Gemfile Essentials

### Problem
You need to identify the key gems for a Rails 8 application with modern infrastructure that eliminates Redis dependency.

### Solution
Use the Solid Stack gems (solid_queue, solid_cache, solid_cable) along with propshaft, importmap-rails, kamal, and thruster for a complete Rails 8 setup.

### Example
From `/Gemfile`:

```ruby
source "https://rubygems.org"

gem "rails", github: "rails/rails", branch: "main"

# Assets & front end
gem "importmap-rails"
gem "propshaft"
gem "stimulus-rails"
gem "turbo-rails"

# Deployment and drivers
gem "bootsnap", require: false
gem "kamal", require: false
gem "puma", ">= 5.0"
gem "solid_cable", ">= 3.0"
gem "solid_cache", "~> 1.0"
gem "solid_queue", "~> 1.2"
gem "sqlite3", ">= 2.0"
gem "thruster", require: false
gem "trilogy", "~> 2.9"

# Operations
gem "mission_control-jobs"
```

**Key gems explained:**
- `propshaft` - Modern asset pipeline replacing Sprockets
- `importmap-rails` - JavaScript without Node.js bundling
- `solid_queue` - Database-backed job queue (no Redis)
- `solid_cache` - Database-backed cache store (no Redis)
- `solid_cable` - Database-backed ActionCable (no Redis)
- `thruster` - HTTP/2 proxy for Rails (replaces nginx for simple setups)
- `kamal` - Zero-downtime deployment tool
- `mission_control-jobs` - Web UI for monitoring Solid Queue

---

## 2. Solid Queue Configuration

### Problem
You need to configure background job processing with dynamic concurrency and multiple queues without Redis.

### Solution
Use `config/queue.yml` to define dispatchers and workers with dynamic process counts based on available CPUs.

### Example
From `/config/queue.yml`:

```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: [ "default", "solid_queue_recurring", "backend", "webhooks" ]
      threads: 3
      processes: <%= Integer(ENV.fetch("JOB_CONCURRENCY") { Concurrent.physical_processor_count }) %>
      polling_interval: 0.1

development: *default
test: *default
beta: *default
staging: *default
production: *default
```

**Configuration options:**
- `polling_interval` - How often to check for new jobs (seconds)
- `batch_size` - Number of jobs to fetch per poll
- `threads` - Threads per worker process
- `processes` - Number of worker processes (dynamic based on CPU count)

### Running Solid Queue with Puma

From `/config/puma.rb`:

```ruby
# Run Solid Queue with Puma by default.
# Disabled when running via SOLID_QUEUE_IN_PUMA=false.
unless ENV["SOLID_QUEUE_IN_PUMA"] == "false"
  plugin :solid_queue
end
```

This eliminates the need for a separate job worker process in simple deployments.

---

## 3. Solid Cache Configuration

### Problem
You need database-backed caching with configurable expiration and environment namespacing.

### Solution
Use `config/cache.yml` to define cache settings with max age and namespace.

### Example
From `/config/cache.yml`:

```yaml
default_options: &default_options
  store_options:
    max_age: <%= 60.days.to_i %>
    namespace: <%= Rails.env %>

default_connection: &default_connection
  database: cache

default: &default
  <<: *default_connection
  <<: *default_options

development: *default
test: *default_options
beta: *default
staging: *default
production: *default
```

**Key settings:**
- `max_age` - Cache entry TTL (60 days = 5,184,000 seconds)
- `namespace` - Isolate cache per environment
- `database` - Name of the database connection to use

---

## 4. Solid Cable Configuration

### Problem
You need WebSocket support for ActionCable without Redis dependency.

### Solution
Use `config/cable.yml` with solid_cable adapter and a separate database connection.

### Example
From `/config/cable.yml`:

```yaml
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
beta: *cable
staging: *cable
production: *cable
```

**Key settings:**
- `adapter: solid_cable` - Use database instead of Redis
- `connects_to` - Specify the database connection
- `polling_interval` - How often to poll for messages
- `message_retention` - How long to keep messages

---

## 5. Database Setup (Multiple Databases)

### Problem
You need separate databases for primary data, cache, queue, and cable to prevent contention and allow independent scaling.

### Solution
Configure multiple database connections with separate migration paths for each.

### Example (SQLite)
From `/config/database.sqlite.yml`:

```yaml
default: &default
  adapter: sqlite3
  pool: 5
  timeout: 5000

development:
  primary:
    <<: *default
    database: storage/development.sqlite3
    schema_dump: schema_sqlite.rb
  cable:
    <<: *default
    database: storage/development_cable.sqlite3
    migrations_paths: db/cable_migrate

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

### Example (MySQL/Trilogy)
From `/config/database.mysql.yml`:

```yaml
default: &default
  adapter: trilogy
  host: <%= ENV.fetch("MYSQL_HOST", "127.0.0.1") %>
  port: <%= ENV.fetch("MYSQL_PORT", "3306") %>
  username: <%= ENV.fetch("MYSQL_USER", "root") %>
  password: <%= ENV["MYSQL_PASSWORD"] %>
  pool: 50
  ssl_mode: <%= ENV["MYSQL_SSL_MODE"] %>
  timeout: 5000

production:
  primary:
    <<: *default
    database: fizzy_production
  cable:
    <<: *default
    database: fizzy_production_cable
    migrations_paths: db/cable_migrate
  queue:
    <<: *default
    database: fizzy_production_queue
    migrations_paths: db/queue_migrate
  cache:
    <<: *default
    database: fizzy_production_cache
    migrations_paths: db/cache_migrate
```

**Key patterns:**
- Use `trilogy` adapter for MySQL (faster than mysql2)
- Separate `migrations_paths` for each database
- Higher `pool` size for production (50 vs 5)
- Environment variables for credentials

---

## 6. Kamal Deployment

### Problem
You need zero-downtime deployment with automatic SSL, secrets management, and persistent storage.

### Solution
Configure `config/deploy.yml` with server definitions, proxy settings, environment variables, and volume mounts.

### Example
From `/config/deploy.yml`:

```yaml
# Name of this app
service: fizzy
image: fizzy

# Where to deploy
servers:
  web:
    - fizzy.example.com

# How you connect to your server
ssh:
  user: root

# Automatic SSL
proxy:
  ssl: true
  host: fizzy.example.com

# Application configuration (secrets come from .kamal/secrets)
env:
  secret:
    - SECRET_KEY_BASE
    - VAPID_PUBLIC_KEY
    - VAPID_PRIVATE_KEY
    - SMTP_USERNAME
    - SMTP_PASSWORD
  clear:
    BASE_URL: https://fizzy.example.com
    MAILER_FROM_ADDRESS: support@example.com
    SMTP_ADDRESS: mail.example.com
    SOLID_QUEUE_IN_PUMA: true

# Use a local registry to deploy
registry:
  server: localhost:5555

# Handy aliases
aliases:
  console: app exec --interactive --reuse "bin/rails console"
  shell: app exec --interactive --reuse "bash"
  logs: app logs -f
  dbc: app exec --interactive --reuse "bin/rails dbconsole --include-password"

# Persistent storage for sqlite and Active Storage
volumes:
  - "fizzy_storage:/rails/storage"

# Bridge assets between versions
asset_path: /rails/public/assets

# Configure the image builder
builder:
  arch: amd64
```

**Key patterns:**
- Separate `secret` and `clear` environment variables
- `SOLID_QUEUE_IN_PUMA: true` runs jobs in the web container
- Volume mount for SQLite databases and Active Storage
- `asset_path` bridges assets during zero-downtime deploys
- Aliases for common operations

---

## 7. Dockerfile Best Practices

### Problem
You need a production-ready Docker image with optimized memory usage, fast boot times, and security best practices.

### Solution
Use multi-stage builds with jemalloc, bootsnap precompilation, and non-root user.

### Example
From `/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
# check=error=true

ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 libssl-dev && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment and enable jemalloc
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Build stage
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install gems
COPY Gemfile Gemfile.lock vendor ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap and assets
RUN bundle exec bootsnap precompile -j 1 app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage
FROM base

# Create non-root user
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
```

**Key practices:**
1. **Multi-stage build** - Build dependencies don't bloat final image
2. **jemalloc** - Reduces memory fragmentation (20-30% memory savings)
3. **bootsnap precompile** - Faster boot times in production
4. **Non-root user** - Security best practice (user 1000)
5. **Thruster** - HTTP/2 proxy via `./bin/thrust`
6. **SECRET_KEY_BASE_DUMMY=1** - Allows asset precompilation without real secrets

### Docker Entrypoint
From `/bin/docker-entrypoint`:

```bash
#!/bin/bash -e

# If running the rails server then create or migrate existing database
if [ "${1}" == "./bin/thrust" ] && [ "${2}" == "./bin/rails" ] && [ "${3}" == "server" ]; then
  MIGRATE=1 ./bin/rails db:prepare
fi

exec "${@}"
```

This automatically runs migrations on deploy.

---

## 8. Recurring Jobs Configuration

### Problem
You need to schedule recurring background tasks for cleanup, notifications, and maintenance.

### Solution
Use `config/recurring.yml` with Solid Queue's native recurring job support.

### Example
From `/config/recurring.yml`:

```yaml
production: &production
  # Application functionality
  deliver_bundled_notifications:
    command: "Notification::Bundle.deliver_all_later"
    schedule: every 30 minutes

  # Application cleanup
  auto_postpone_all_due:
    command: "Card.auto_postpone_all_due"
    schedule: every hour at minute 50
  delete_unused_tags:
    class: DeleteUnusedTagsJob
    schedule: every day at 04:02

  # Solid Queue maintenance
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12
  clear_solid_queue_recurring_executions:
    command: "SolidQueue::RecurringExecution.clear_in_batches"
    schedule: every hour at minute 52

  # General cleanup
  cleanup_webhook_deliveries:
    command: "Webhook::Delivery.cleanup"
    schedule: every 4 hours at minute 51
  cleanup_magic_links:
    command: "MagicLink.cleanup"
    schedule: every 4 hours
  cleanup_exports:
    command: "Account::Export.cleanup"
    schedule: every hour at minute 20

staging: *production
development: *production
```

**Schedule syntax:**
- `every 30 minutes`
- `every hour at minute 50`
- `every day at 04:02`
- `every 4 hours at minute 51`

**Two ways to define jobs:**
1. `command:` - Inline Ruby code to execute
2. `class:` - Reference a job class

---

## 9. Puma Configuration for Production

### Problem
You need optimized Puma configuration for production with proper worker counts and GC settings.

### Solution
Configure workers based on CPU count, optimize threads for local database, and defer GC during requests.

### Example
From `/config/puma.rb`:

```ruby
port ENV.fetch("PORT", 3000)
pidfile ENV.fetch("PIDFILE", "tmp/pids/server.pid")
plugin :tmp_restart

# Run Solid Queue with Puma
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

**Key optimizations:**
- `plugin :solid_queue` - Run jobs in same process
- `Process.warmup` - Triggers GC and compaction before forking
- Deferred GC - Major GC runs between requests, not during
- 1 thread per worker - Optimal for SQLite (low I/O wait)

---

## Quick Reference

### New Project Checklist

1. Add Solid Stack gems to Gemfile
2. Create `config/queue.yml` for Solid Queue
3. Create `config/cache.yml` for Solid Cache
4. Create `config/cable.yml` for Solid Cable
5. Configure multiple databases in `config/database.yml`
6. Add `plugin :solid_queue` to `config/puma.rb`
7. Create `config/deploy.yml` for Kamal
8. Create production Dockerfile with jemalloc and bootsnap
9. Set up `config/recurring.yml` for scheduled tasks
10. Configure `bin/docker-entrypoint` for auto-migrations

### Environment Variables

```bash
# Required secrets (in .kamal/secrets)
SECRET_KEY_BASE=...
RAILS_MASTER_KEY=...

# Database (for MySQL)
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_USER=root
MYSQL_PASSWORD=...

# Concurrency tuning
WEB_CONCURRENCY=4        # Puma workers
JOB_CONCURRENCY=4        # Solid Queue processes
SOLID_QUEUE_IN_PUMA=true # Run jobs in web process
```
