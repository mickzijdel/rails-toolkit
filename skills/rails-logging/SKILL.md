---
name: rails-logging
description: Rails logging and observability — Lograge for structured one-line request logs, tagged logging with request/user context, sensitive parameter filtering, ActiveSupport::Notifications for custom instrumentation, Sentry/error-tracker integration, health check endpoints, and log-level configuration. Use when setting up a new app's observability stack, debugging noisy logs, or adding structured logging.
---

# Rails Logging and Observability

## 1. Lograge — structured one-line request logs

The default Rails request log is multi-line and noisy. Lograge collapses it to one structured
JSON line per request, suitable for log aggregators (Datadog, Loki, Splunk).

```ruby
# Gemfile
gem "lograge"

# config/initializers/lograge.rb
Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new

  config.lograge.custom_options = lambda do |event|
    {
      request_id: event.payload[:headers]["X-Request-Id"],
      user_id:    event.payload[:user_id],
      account_id: event.payload[:account_id],
    }.compact
  end
end
```

Add user context from the controller:

```ruby
class ApplicationController < ActionController::Base
  def append_info_to_payload(payload)
    super
    payload[:user_id]    = current_user&.id
    payload[:account_id] = current_account&.id
  end
end
```

## 2. Tagged logging

Wrap every log line in a request with identifiers so you can grep a full request's story:

```ruby
# config/application.rb
config.log_tags = [:request_id]

# For custom tags (Rails 7.1+)
config.log_tags = [
  :request_id,
  ->(req) { req.session[:account_id] },
]
```

In application code, use `Rails.logger.tagged` for sub-operations:

```ruby
Rails.logger.tagged("BatchImport", batch.id) do
  batch.rows.each { |row| import_row(row) }
end
```

**Use Lograge OR tagged logging, not both** — Lograge replaces the multi-line format that
`log_tags` prefixes onto.

## 3. Log levels

| Level | Use for |
|---|---|
| `debug` | Detailed internals, only useful when actively debugging |
| `info` | Normal operations worth knowing happened |
| `warn` | Something unexpected that didn't cause a failure |
| `error` | A failure that was handled (rescued and recovered) |
| `fatal` | Unrecoverable failure; the process is about to exit |

```ruby
Rails.logger.info  "Charge succeeded for order #{order.id}"
Rails.logger.warn  "Payment gateway slow response: #{duration}ms"
Rails.logger.error "Stripe webhook signature mismatch — possible replay"
```

**Never use `puts`, `p`, or `pp` in application code.** They bypass the logger entirely —
no tags, no level, no structured output. Use `Rails.logger.debug` instead. See
**rails-toolkit:rails-clean-test-output** for finding and removing stray `puts` calls.

## 4. Filtering sensitive parameters

Rails logs request parameters by default. Ensure secrets never appear in logs:

```ruby
# config/application.rb
config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate,
  :otp, :ssn, :credit_card, :cvv, :card_number,
  # Add app-specific sensitive fields:
  :stripe_payload, :webhook_body,
]
```

For custom structured payloads logged manually, filter in `append_info_to_payload`:

```ruby
def append_info_to_payload(payload)
  super
  payload[:api_key] = "[FILTERED]" if params[:api_key].present?
end
```

## 5. `ActiveSupport::Notifications` — custom instrumentation

Instrument domain events so monitoring can track business metrics alongside
infrastructure metrics:

```ruby
# Emit an event from anywhere in the app
ActiveSupport::Notifications.instrument("order.charged", order_id: order.id, amount: amount)

# Subscribe in an initializer
ActiveSupport::Notifications.subscribe("order.charged") do |name, start, finish, _id, payload|
  duration_ms = ((finish - start) * 1000).round
  Rails.logger.info({ event: name, duration_ms: duration_ms }.merge(payload).to_json)
  StatsD.histogram("order.charge.duration_ms", duration_ms)
end
```

For long-lived subscribers (always on), use `subscribe`; for one-shot debugging, use
`subscribed` (automatically removes the listener after the block exits).

## 6. Error tracking (Sentry / Honeybadger)

```ruby
# Gemfile
gem "sentry-ruby"
gem "sentry-rails"

# config/initializers/sentry.rb
Sentry.init do |config|
  config.dsn = Rails.application.credentials.sentry_dsn!
  config.environment = Rails.env

  config.before_send = lambda do |event, hint|
    event.user = { id: Current.user&.id, email: Current.user&.email }
    event
  end

  config.traces_sample_rate  = Rails.env.production? ? 0.1 : 0
  config.profiles_sample_rate = 0.1  # requires traces_sample_rate > 0
end
```

Manually capture handled exceptions with context:

```ruby
begin
  ExternalService.call(payload)
rescue ExternalService::RateLimitError => e
  Sentry.capture_exception(e, extra: { payload_id: payload.id, retry_after: e.retry_after })
  raise
end
```

**Don't rescue and swallow exceptions without re-raising or capturing.** Silent rescues turn
real bugs into mysterious data corruption.

## 7. Health check endpoint

Uptime monitors and load balancer health checks need a lightweight endpoint that validates
the app's critical dependencies:

```ruby
# config/routes.rb
get "/health", to: "health#show"

# app/controllers/health_controller.rb
class HealthController < ActionController::Base
  allow_unauthenticated_access  # Rails 8 auth generator

  def show
    checks = {
      database: database_ok?,
      cache:    cache_ok?,
    }
    status = checks.values.all? ? :ok : :service_unavailable
    render json: checks.merge(status: status), status: status
  end

  private

    def database_ok?
      ActiveRecord::Base.connection.execute("SELECT 1")
      true
    rescue StandardError
      false
    end

    def cache_ok?
      Rails.cache.write("health_check", "ok", expires_in: 5.seconds)
      Rails.cache.read("health_check") == "ok"
    rescue StandardError
      false
    end
end
```

Return `503` when a critical dependency is down — load balancers interpret any non-2xx as
unhealthy. Exclude the health endpoint from authentication and request logging (it fires
every 30 seconds and clutters logs):

```ruby
# config/initializers/lograge.rb
config.lograge.ignore_actions = ["HealthController#show"]
```

## 8. Silencing noisy logs

Silence selectively rather than raising the log level globally:

```ruby
# Silence Active Job logs in development
ActiveJob::Base.logger = Logger.new(nil)

# Silence a noisy third-party gem
SemanticLogger[Devise].level = :error

# Silence a specific code path inline
Rails.logger.silence { SomeNoisyService.call }
```

## 9. Log rotation

In production, configure rotation to prevent unbounded disk growth:

```ruby
# config/environments/production.rb
config.logger = ActiveSupport::Logger.new(
  Rails.root.join("log", "#{Rails.env}.log"),
  5,             # keep 5 rotated files
  100.megabytes
)
config.log_level = :info
```

Or delegate to the OS: `config.logger = Logger.new(STDOUT)` and pipe to
`journald`/`logrotate`/your cloud provider's log collector.

## Quick reference

| Pattern | Purpose |
|---|---|
| `lograge` gem + JSON formatter | Structured one-line request logs for aggregators |
| `append_info_to_payload` | Attach user/account context to every request log |
| `config.log_tags = [:request_id]` | Correlate all lines within a request |
| `Rails.logger.tagged(...)` | Correlate lines within a sub-operation |
| `config.filter_parameters` | Keep secrets out of logs |
| `AS::Notifications.instrument` | Emit and subscribe to custom domain events |
| `Sentry.capture_exception` | Send handled errors with context to Sentry |
| `GET /health` returning 503 | Load balancer / uptime monitoring |
| `Logger.new(nil)` | Silence a specific noisy logger |
| `config.lograge.ignore_actions` | Exclude health/ping endpoints from request logs |

## Composing with other skills

- See **rails-toolkit:rails-performance** for ETags, fragment caching, and CDN headers —
  observability and caching are complementary layers of a production-ready app.
- See **rails-toolkit:rails-clean-test-output** for removing stray `puts`/`p`/`pp` calls
  that bypass the logger in test output.
- See **rails-toolkit:rails-security** for credential storage (`credentials.sentry_dsn!`)
  and filtering sensitive data at the framework level.
