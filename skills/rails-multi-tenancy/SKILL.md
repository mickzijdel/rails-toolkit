---
name: rails-multi-tenancy
description: Use when implementing URL-based multi-tenancy, CurrentAttributes, or account context patterns
---

# Rails Multi-Tenancy Patterns

## When to Use
- Adding multi-tenant support to a Rails application
- Managing account/tenant context across requests
- Scoping data by tenant
- Handling tenant context in background jobs and Action Cable
- Building routes that include tenant identifiers

---

## Pattern 1: URL-Based Tenancy with Middleware

### Problem
You need to scope requests to specific tenants without using subdomains or separate databases. URLs should include tenant identification.

### Solution
Use Rack middleware to extract the tenant ID from the URL path, move it from `PATH_INFO` to `SCRIPT_NAME` (making Rails think it's "mounted" at that path), and set the tenant context for the request.

### Example

**Source**: `config/initializers/tenanting/account_slug.rb`

```ruby
module AccountSlug
  PATTERN = /(\d{7,})/
  FORMAT = "%07d"
  PATH_INFO_MATCH = /\A(\/#{AccountSlug::PATTERN})/

  class Extractor
    def initialize(app)
      @app = app
    end

    # We're using account id prefixes in the URL path. Rather than namespace
    # all our routes, we're "mounting" the Rails app at this URL prefix.
    def call(env)
      request = ActionDispatch::Request.new(env)

      # $1, $2, $' == script_name, slug, path_info
      if request.script_name && request.script_name =~ PATH_INFO_MATCH
        # Likely due to restarting the action cable connection after upgrade
        env["fizzy.external_account_id"] = AccountSlug.decode($2)
      elsif request.path_info =~ PATH_INFO_MATCH
        # Yanks the prefix off PATH_INFO and move it to SCRIPT_NAME
        request.engine_script_name = request.script_name = $1
        request.path_info   = $'.empty? ? "/" : $'

        # Stash the account's external ID
        env["fizzy.external_account_id"] = AccountSlug.decode($2)
      end

      if env["fizzy.external_account_id"]
        account = Account.find_by(external_account_id: env["fizzy.external_account_id"])
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

Key points:
- URLs look like `/1234567/boards/1` where `1234567` is the tenant ID
- The middleware moves `/1234567` to `SCRIPT_NAME`, so Rails routes see just `/boards/1`
- All generated URLs automatically include the tenant prefix via `script_name`
- The tenant ID is stashed in `env["fizzy.external_account_id"]` for later use

---

## Pattern 2: CurrentAttributes for Request Context

### Problem
You need thread-safe access to the current tenant (and related user context) throughout your application without passing it as parameters.

### Solution
Use `ActiveSupport::CurrentAttributes` to store request-scoped context. Add convenience methods for working with account context.

### Example

**Source**: `app/models/current.rb`

```ruby
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

Key points:
- `Current.account` is available anywhere in the request cycle
- Setting `session` cascades to set `identity` automatically
- Setting `identity` finds the correct `user` for the current account
- `with_account` provides block-scoped context switching

---

## Pattern 3: Context Switching with `with_account`

### Problem
Sometimes you need to temporarily switch tenant context (for background jobs, cross-tenant operations, or testing).

### Solution
Use `Current.with_account(account)` to execute code in a different tenant context. The context is automatically restored after the block.

### Example

**Source**: `app/models/notification/bundle.rb`

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

**Source**: `config/initializers/tenanting/account_slug.rb`

```ruby
if env["fizzy.external_account_id"]
  account = Account.find_by(external_account_id: env["fizzy.external_account_id"])
  Current.with_account(account) do
    @app.call env
  end
else
  Current.without_account do
    @app.call env
  end
end
```

Use `Current.without_account` when you explicitly need to operate outside any tenant context.

---

## Pattern 4: Default Account in Associations

### Problem
Every tenant-scoped model needs an `account_id` column, and you want it populated automatically based on the current context.

### Solution
Use `belongs_to :account, default: -> { ... }` to automatically set the account from the parent record or from `Current.account`.

### Example

**Source**: Various model files

```ruby
# Derive from parent association (preferred when possible)
class Card < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :board
end

class Comment < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card
end

class Event < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :board
end

# Use Current.account when there's no parent to derive from
class Tag < ApplicationRecord
  belongs_to :account, default: -> { Current.account }
end

class Board < ApplicationRecord
  belongs_to :creator, class_name: "User", default: -> { Current.user }
  belongs_to :account, default: -> { creator.account }
end
```

**Source**: `config/initializers/uuid_framework_models.rb`

```ruby
# Inject account associations into Rails framework models
Rails.application.config.to_prepare do
  ActionText::RichText.belongs_to :account, default: -> { record.account }

  ActiveStorage::Attachment.belongs_to :account, default: -> { record.account }

  ActiveStorage::Blob.belongs_to :account, default: -> { Current.account }

  ActiveStorage::VariantRecord.belongs_to :account, default: -> { blob.account }
end
```

Key points:
- Derive account from parent associations when possible (more explicit, less reliance on global state)
- Use `Current.account` only for top-level records or framework models
- Framework models (ActionText, ActiveStorage) need explicit account associations added

---

## Pattern 5: Job Context Serialization

### Problem
Background jobs need access to the tenant context that was active when they were enqueued. Without this, jobs run without tenant context.

### Solution
Prepend a module to `ActiveJob::Base` that captures `Current.account` during job initialization, serializes it with the job, and restores it when the job executes.

### Example

**Source**: `config/initializers/active_job.rb`

```ruby
module FizzyActiveJobExtensions
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
  prepend FizzyActiveJobExtensions
end
```

Key points:
- Account is captured automatically when any job is created
- Uses GlobalID for safe serialization of ActiveRecord objects
- `perform_now` wraps execution in `Current.with_account`
- No manual context passing needed in job classes

---

## Pattern 6: Account Scoping Middleware Details

### Problem
URL helpers need to generate tenant-prefixed URLs, and Turbo Streams rendered from jobs need the correct URL prefix.

### Solution
Configure the `script_name` on the Rails renderer when working outside a request context.

### Example

**Source**: `config/initializers/tenanting/turbo.rb`

```ruby
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

**Source**: `app/models/account.rb`

```ruby
class Account < ApplicationRecord
  def slug
    "/#{AccountSlug.encode(external_account_id)}"
  end
end
```

Key points:
- Account provides a `slug` method that returns the URL prefix (e.g., `/1234567`)
- Turbo Streams from jobs use the account slug as `script_name`
- All URL helpers automatically include the tenant prefix

---

## Pattern 7: Controller Account Validation

### Problem
Controllers need to ensure a valid tenant context exists before processing requests. Some controllers (login, signup) should work without tenant context.

### Solution
Use `before_action :require_account` as the default, with `disallow_account_scope` for tenant-independent controllers.

### Example

**Source**: `app/controllers/concerns/authentication.rb`

```ruby
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

**Usage in controllers**:

```ruby
# Default: requires account context
class BoardsController < ApplicationController
  # require_account is automatically applied
end

# Opt out for tenant-independent pages
class SessionsController < ApplicationController
  disallow_account_scope
end

class SignupsController < ApplicationController
  disallow_account_scope
end

class SessionsController < ApplicationController
  disallow_account_scope
end
```

Key points:
- `require_account` redirects to account selection if no tenant context
- `disallow_account_scope` is used for login, signup, and global pages
- Use `script_name: nil` when generating URLs without tenant prefix

---

## Pattern 8: Action Cable Connection Context

### Problem
WebSocket connections need tenant context, but they don't go through the regular middleware stack on reconnect.

### Solution
Set `Current.account` in the Action Cable connection based on the account ID stashed in the Rack environment.

### Example

**Source**: `app/channels/application_cable/connection.rb`

```ruby
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      def set_current_user
        if session = find_session_by_cookie
          account = Account.find_by(external_account_id: request.env["fizzy.external_account_id"])
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

Key points:
- Access `request.env["fizzy.external_account_id"]` from the middleware
- Set `Current.account` before finding the user
- The user lookup is scoped to the current account

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

---

## Architecture Benefits

This URL-based multi-tenancy approach provides:

1. **Simple local development**: No subdomain configuration needed
2. **Single database**: All tenants share tables, isolated by `account_id`
3. **Automatic URL generation**: All helpers produce tenant-prefixed URLs
4. **Transparent context**: Jobs and channels get tenant context automatically
5. **Easy testing**: Set `Current.account` in tests, no special setup
