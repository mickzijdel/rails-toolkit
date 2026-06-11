---
name: rails-multi-tenancy
description: Use when implementing URL-based multi-tenancy, CurrentAttributes, or account context patterns
---

# Rails Multi-Tenancy Patterns

## Pattern 1: URL-Based Tenancy with Middleware

Scope requests to tenants without subdomains or separate databases: Rack middleware extracts the tenant ID from the URL path, moves it from `PATH_INFO` to `SCRIPT_NAME` (making Rails think it's "mounted" at that prefix), and sets the tenant context for the request.

```ruby
# config/initializers/tenanting/account_slug.rb
module AccountSlug
  PATTERN = /(\d{7,})/
  FORMAT = "%07d"
  PATH_INFO_MATCH = /\A(\/#{AccountSlug::PATTERN})/

  class Extractor
    def initialize(app)
      @app = app
    end

    # Account id prefixes in the URL path. Rather than namespace all routes,
    # we "mount" the Rails app at this URL prefix.
    def call(env)
      request = ActionDispatch::Request.new(env)

      # $1, $2, $' == script_name, slug, path_info
      if request.script_name && request.script_name =~ PATH_INFO_MATCH
        # Likely due to restarting the action cable connection after upgrade
        env["app.external_account_id"] = AccountSlug.decode($2)
      elsif request.path_info =~ PATH_INFO_MATCH
        # Yank the prefix off PATH_INFO and move it to SCRIPT_NAME
        request.engine_script_name = request.script_name = $1
        request.path_info   = $'.empty? ? "/" : $'

        env["app.external_account_id"] = AccountSlug.decode($2)
      end

      if env["app.external_account_id"]
        account = Account.find_by(external_account_id: env["app.external_account_id"])
        Current.with_account(account) do
          @app.call env
        end
      else
        Current.without_account do
          @app.call env
        end
      end
    end
  end

  def self.decode(slug) slug.to_i end
  def self.encode(id) FORMAT % id end
end

Rails.application.config.middleware.insert_after Rack::TempfileReaper, AccountSlug::Extractor
```

**Key Points:**
- URLs look like `/1234567/boards/1`; Rails routes see just `/boards/1`.
- All generated URLs automatically include the tenant prefix via `script_name`.
- The tenant ID is stashed in the env for non-middleware consumers (Action Cable, Pattern 8).

---

## Pattern 2: CurrentAttributes for Request Context

`ActiveSupport::CurrentAttributes` gives thread-safe, request-scoped tenant/user context without parameter passing:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :identity, :account
  attribute :http_method, :request_id, :user_agent, :ip_address, :referrer

  def session=(value)
    super(value)

    if value.present?
      self.identity = session.identity
    end
  end

  def identity=(identity)
    super(identity)

    if identity.present?
      self.user = identity.users.find_by(account: account)
    end
  end

  def with_account(value, &)
    with(account: value, &)
  end

  def without_account(&)
    with(account: nil, &)
  end
end
```

Setting `session` cascades to `identity`, and setting `identity` resolves the `user` *for the current account* — an identity can never act in an account it has no user in.

---

## Pattern 3: Context Switching with `with_account`

`Current.with_account(account) { ... }` executes a block in a different tenant context and restores the previous one afterwards — for background jobs, cross-tenant operations, and tests. `Current.without_account` runs explicitly outside any tenant context.

```ruby
def deliver
  user.in_time_zone do
    Current.with_account(user.account) do
      processing!
      Notification::BundleMailer.notification(self).deliver if deliverable?
      delivered!
    end
  end
end
```

---

## Pattern 4: Default Account in Associations

Every tenant-scoped model carries `account_id`, populated automatically via `belongs_to ... default:`:

```ruby
# Derive from parent association (preferred — less reliance on global state)
class Card < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :board
end

# Use Current.account when there's no parent to derive from
class Tag < ApplicationRecord
  belongs_to :account, default: -> { Current.account }
end
```

```ruby
# config/initializers/uuid_framework_models.rb — framework models need it too
Rails.application.config.to_prepare do
  ActionText::RichText.belongs_to :account, default: -> { record.account }
  ActiveStorage::Attachment.belongs_to :account, default: -> { record.account }
  ActiveStorage::Blob.belongs_to :account, default: -> { Current.account }
  ActiveStorage::VariantRecord.belongs_to :account, default: -> { blob.account }
end
```

---

## Pattern 5: Job Context Serialization

Jobs need the tenant context that was active at enqueue time. Prepend a module to `ActiveJob::Base` that captures `Current.account` on initialize, serializes it as a GlobalID, and restores it around `perform` — no manual passing in any job class.

```ruby
# config/initializers/active_job.rb
module TenantedActiveJobExtensions
  extend ActiveSupport::Concern

  prepended do
    attr_reader :account
    self.enqueue_after_transaction_commit = true
  end

  def initialize(...)
    super
    @account = Current.account
  end

  def serialize
    super.merge({ "account" => @account&.to_gid })
  end

  def deserialize(job_data)
    super
    if _account = job_data.fetch("account", nil)
      @account = GlobalID::Locator.locate(_account)
    end
  end

  def perform_now
    if account.present?
      Current.with_account(account) { super }
    else
      super
    end
  end
end

ActiveSupport.on_load(:active_job) do
  prepend TenantedActiveJobExtensions
end
```

---

## Pattern 6: Tenant-Aware Turbo Streams from Jobs

Turbo Streams rendered outside a request need the account's URL prefix as `script_name`:

```ruby
# config/initializers/tenanting/turbo.rb
module TurboStreamsJobExtensions
  extend ActiveSupport::Concern

  class_methods do
    def render_format(format, **rendering)
      if Current.account.present?
        ApplicationController.renderer.new(script_name: Current.account.slug).render(formats: [ format ], **rendering)
      else
        super
      end
    end
  end
end

Rails.application.config.after_initialize do
  Turbo::StreamsChannel.prepend TurboStreamsJobExtensions
end
```

```ruby
# app/models/account.rb
def slug
  "/#{AccountSlug.encode(external_account_id)}"
end
```

---

## Pattern 7: Controller Account Validation

`require_account` is the default; tenant-independent controllers (login, signup) opt out with `disallow_account_scope`:

```ruby
# app/controllers/concerns/authentication.rb
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_account # Checking and setting account must happen first
    before_action :require_authentication
  end

  class_methods do
    def disallow_account_scope(**options)
      skip_before_action :require_account, **options
      before_action :redirect_tenanted_request, **options
    end
  end

  private
    def require_account
      unless Current.account.present?
        redirect_to main_app.session_menu_path(script_name: nil)
      end
    end

    def redirect_tenanted_request
      redirect_to main_app.root_url if Current.account.present?
    end
end
```

```ruby
class SessionsController < ApplicationController
  disallow_account_scope
end
```

Use `script_name: nil` when generating URLs without the tenant prefix.

---

## Pattern 8: Action Cable Connection Context

WebSocket connections don't go through the regular middleware stack on reconnect. Set `Current.account` from the env key the middleware stashed:

```ruby
# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      def set_current_user
        if session = find_session_by_cookie
          account = Account.find_by(external_account_id: request.env["app.external_account_id"])
          Current.account = account
          self.current_user = session.identity.users.find_by!(account: account) if account
        end
      end

      def find_session_by_cookie
        Session.find_signed(cookies.signed[:session_token])
      end
  end
end
```

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| URL Middleware | Request routing and tenant extraction |
| CurrentAttributes | Thread-safe request context |
| `with_account` | Temporary context switching |
| Default Account | Automatic `account_id` on creation |
| Job Serialization | Background job tenant context |
| Turbo Extensions | Tenant-aware Turbo Streams from jobs |
| `require_account` | Default controller behavior |
| `disallow_account_scope` | Tenant-independent controllers |
| Action Cable | WebSocket connection context |
