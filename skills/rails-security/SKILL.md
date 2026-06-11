---
name: rails-security
description: Use when implementing authentication, authorization, or security features in Rails
---

# Rails Security Patterns

## When to Use
- Implementing user authentication
- Adding authorization checks
- Securing sensitive endpoints
- Implementing rate limiting
- Multi-tenant data isolation

---

## 1. Passwordless Authentication (Magic Links)

### Problem
Users need to authenticate without managing passwords. Password-based auth introduces security risks (weak passwords, password reuse, credential stuffing) and UX friction.

### Solution
Implement magic link authentication: users enter their email, receive a time-limited code via email, and enter that code to authenticate.

### Example

**Magic Link Model** (`app/models/magic_link.rb`):
```ruby
class MagicLink < ApplicationRecord
  CODE_LENGTH = 6
  EXPIRATION_TIME = 15.minutes

  belongs_to :identity

  enum :purpose, %w[ sign_in sign_up ], prefix: :for, default: :sign_in

  scope :active, -> { where(expires_at: Time.current...) }
  scope :stale, -> { where(expires_at: ..Time.current) }

  before_validation :generate_code, on: :create
  before_validation :set_expiration, on: :create

  validates :code, uniqueness: true, presence: true

  class << self
    def consume(code)
      active.find_by(code: Code.sanitize(code))&.consume
    end

    def cleanup
      stale.delete_all
    end
  end

  def consume
    destroy
    self
  end

  private
    def generate_code
      self.code ||= loop do
        candidate = Code.generate(CODE_LENGTH)
        break candidate unless self.class.exists?(code: candidate)
      end
    end

    def set_expiration
      self.expires_at ||= EXPIRATION_TIME.from_now
    end
end
```

**Sending Magic Links** (`app/models/identity.rb`):
```ruby
def send_magic_link(**attributes)
  attributes[:purpose] = attributes.delete(:for) if attributes.key?(:for)

  magic_links.create!(attributes).tap do |magic_link|
    MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
  end
end
```

**Consuming Magic Links** (`app/controllers/sessions/magic_links_controller.rb`):
```ruby
def create
  if magic_link = MagicLink.consume(code)
    authenticate magic_link
  else
    invalid_code
  end
end

private
  def authenticate(magic_link)
    if ActiveSupport::SecurityUtils.secure_compare(
      email_address_pending_authentication || "",
      magic_link.identity.email_address
    )
      sign_in magic_link
    else
      email_address_mismatch
    end
  end
```

Key security features:
- Short-lived codes (15 minutes)
- Codes are consumed (destroyed) on use
- Uses `secure_compare` to prevent timing attacks
- Code sanitization handles user typos (O->0, I->1, L->1)

**Source files**:
- `app/models/magic_link.rb`
- `app/models/magic_link/code.rb`
- `app/controllers/sessions/magic_links_controller.rb`
- `app/controllers/concerns/authentication/via_magic_link.rb`

---

## 2. Session Management

### Problem
Sessions must be secure, persistent, and easily revocable. Cookie-based sessions should be tamper-proof.

### Solution
Store session records in the database, reference them via signed cookies. This allows tracking active sessions, revoking access, and auditing login history.

### Example

**Session Model** (`app/models/session.rb`):
```ruby
class Session < ApplicationRecord
  belongs_to :identity
end
```

**Starting Sessions** (`app/controllers/concerns/authentication.rb`):
```ruby
def start_new_session_for(identity)
  identity.sessions.create!(
    user_agent: request.user_agent,
    ip_address: request.remote_ip
  ).tap do |session|
    set_current_session session
  end
end

def set_current_session(session)
  Current.session = session
  cookies.signed.permanent[:session_token] = {
    value: session.signed_id,
    httponly: true,
    same_site: :lax
  }
end
```

**Resuming Sessions**:
```ruby
def resume_session
  if session = find_session_by_cookie
    set_current_session session
  end
end

def find_session_by_cookie
  Session.find_signed(cookies.signed[:session_token])
end
```

**Terminating Sessions**:
```ruby
def terminate_session
  Current.session.destroy
  cookies.delete(:session_token)
end
```

Key security features:
- `signed_id` creates tamper-proof tokens
- `httponly: true` prevents JavaScript access
- `same_site: :lax` provides CSRF protection
- Sessions stored in DB allow revocation

**Source file**: `app/controllers/concerns/authentication.rb`

---

## 3. Authorization Concern (Role-Based Access)

### Problem
Different users need different access levels. Admins can manage settings, staff can access internal tools, regular members have limited access.

### Solution
Define role checks as concern methods, apply them via `before_action` filters.

### Example

**User Roles** (`app/models/user/role.rb`):
```ruby
module User::Role
  extend ActiveSupport::Concern

  included do
    enum :role, %i[ owner admin member system ].index_by(&:itself), scopes: false

    scope :owner, -> { where(active: true, role: :owner) }
    scope :admin, -> { where(active: true, role: %i[ owner admin ]) }
    scope :member, -> { where(active: true, role: :member) }
    scope :active, -> { where(active: true, role: %i[ owner admin member ]) }

    def admin?
      super || owner?  # owners are also admins
    end
  end

  def can_change?(other)
    (admin? && !other.owner?) || other == self
  end

  def can_administer?(other)
    admin? && !other.owner? && other != self
  end
end
```

**Authorization Concern** (`app/controllers/concerns/authorization.rb`):
```ruby
module Authorization
  extend ActiveSupport::Concern

  included do
    before_action :ensure_can_access_account, if: -> { Current.account.present? && authenticated? }
  end

  class_methods do
    def allow_unauthorized_access(**options)
      skip_before_action :ensure_can_access_account, **options
    end
  end

  private
    def ensure_admin
      head :forbidden unless Current.user.admin?
    end

    def ensure_staff
      head :forbidden unless Current.identity.staff?
    end

    def ensure_can_access_account
      if Current.user.blank? || !Current.user.active?
        respond_to do |format|
          format.html { redirect_to session_menu_path(script_name: nil) }
          format.json { head :forbidden }
        end
      end
    end
end
```

**Usage in Controllers**:
```ruby
# Admin-only endpoints
class WebhooksController < ApplicationController
  before_action :ensure_admin
  # ...
end

# Staff-only (internal) endpoints
class AdminController < ApplicationController
  disallow_account_scope
  before_action :ensure_staff
end

# Mixed access
class Account::SettingsController < ApplicationController
  before_action :ensure_admin, only: :update
end
```

**Source files**:
- `app/controllers/concerns/authorization.rb`
- `app/models/user/role.rb`
- `app/controllers/webhooks_controller.rb`

---

## 4. Bearer Token API Access

### Problem
API clients need stateless authentication without cookies or sessions. Tokens should have configurable permissions.

### Solution
Create access tokens with read/write permissions. Authenticate API requests via Bearer tokens in the Authorization header.

### Example

**Access Token Model** (`app/models/identity/access_token.rb`):
```ruby
class Identity::AccessToken < ApplicationRecord
  belongs_to :identity

  has_secure_token
  enum :permission, %w[ read write ].index_by(&:itself), default: :read

  def allows?(method)
    method.in?(%w[ GET HEAD ]) || write?
  end
end
```

**Finding Identity by Token** (`app/models/identity.rb`):
```ruby
def self.find_by_permissable_access_token(token, method:)
  if (access_token = AccessToken.find_by(token: token)) && access_token.allows?(method)
    access_token.identity
  end
end
```

**Authentication Fallback** (`app/controllers/concerns/authentication.rb`):
```ruby
def require_authentication
  resume_session || authenticate_by_bearer_token || request_authentication
end

def authenticate_by_bearer_token
  if request.authorization.to_s.include?("Bearer")
    authenticate_or_request_with_http_token do |token|
      if identity = Identity.find_by_permissable_access_token(token, method: request.method)
        Current.identity = identity
      end
    end
  end
end
```

**Token Management Controller** (`app/controllers/my/access_tokens_controller.rb`):
```ruby
class My::AccessTokensController < ApplicationController
  def create
    access_token = my_access_tokens.create!(access_token_params)
    expiring_id = verifier.generate access_token.id, expires_in: 10.seconds

    redirect_to my_access_token_path(expiring_id)
  end

  private
    def my_access_tokens
      Current.identity.access_tokens
    end

    def verifier
      Rails.application.message_verifier(:access_tokens)
    end
end
```

Key features:
- Read-only tokens for safe operations
- Write tokens required for mutations
- Token only displayed once (10-second expiry on view)
- Uses `has_secure_token` for cryptographic tokens

**Source files**:
- `app/models/identity/access_token.rb`
- `app/controllers/my/access_tokens_controller.rb`
- `app/controllers/concerns/authentication.rb`

---

## 5. Rate Limiting

### Problem
Sensitive endpoints (login, signup, magic link verification) are targets for brute-force attacks. Need to limit request frequency.

### Solution
Use Rails 8's built-in `rate_limit` helper with custom handlers for exceeded limits.

### Example

**Sessions Controller** (`app/controllers/sessions_controller.rb`):
```ruby
class SessionsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :create, with: :rate_limit_exceeded

  private
    def rate_limit_exceeded
      rate_limit_exceeded_message = "Try again later."

      respond_to do |format|
        format.html { redirect_to new_session_path, alert: rate_limit_exceeded_message }
        format.json { render json: { message: rate_limit_exceeded_message }, status: :too_many_requests }
      end
    end
end
```

**Magic Links Controller** (`app/controllers/sessions/magic_links_controller.rb`):
```ruby
class Sessions::MagicLinksController < ApplicationController
  rate_limit to: 10, within: 15.minutes, only: :create, with: :rate_limit_exceeded

  private
    def rate_limit_exceeded
      rate_limit_exceeded_message = "Try again in 15 minutes."
      respond_to do |format|
        format.html { redirect_to session_magic_link_path, alert: rate_limit_exceeded_message }
        format.json { render json: { message: rate_limit_exceeded_message }, status: :too_many_requests }
      end
    end
end
```

**Inline Handler** (`app/controllers/signups_controller.rb`):
```ruby
class SignupsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_signup_path, alert: "Try again later." }
end
```

**Email Change Rate Limiting** (`app/controllers/users/email_addresses_controller.rb`):
```ruby
class Users::EmailAddressesController < ApplicationController
  rate_limit to: 5, within: 1.hour, only: :create
end
```

Different endpoints use different limits:
- Login/signup: 10 per 3 minutes
- Magic link verification: 10 per 15 minutes
- Email changes: 5 per hour

**Source files**:
- `app/controllers/sessions_controller.rb`
- `app/controllers/sessions/magic_links_controller.rb`
- `app/controllers/signups_controller.rb`

---

## 6. Account Scoping (Multi-Tenant Security)

### Problem
In multi-tenant applications, users must only access data belonging to their account. Data leakage between tenants is a critical security risk.

### Solution
Extract account ID from URL path via middleware, set `Current.account`, and require account context for most actions.

### Example

**Account Slug Middleware** (`config/initializers/tenanting/account_slug.rb`):
```ruby
module AccountSlug
  PATTERN = /(\d{7,})/
  PATH_INFO_MATCH = /\A(\/#{AccountSlug::PATTERN})/

  class Extractor
    def initialize(app)
      @app = app
    end

    def call(env)
      request = ActionDispatch::Request.new(env)

      if request.path_info =~ PATH_INFO_MATCH
        # Move prefix from PATH_INFO to SCRIPT_NAME
        request.engine_script_name = request.script_name = $1
        request.path_info = $'.empty? ? "/" : $'
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
end

Rails.application.config.middleware.insert_after Rack::TempfileReaper, AccountSlug::Extractor
```

**Require Account** (`app/controllers/concerns/authentication.rb`):
```ruby
included do
  before_action :require_account  # Must happen first
  before_action :require_authentication
end

private
  def require_account
    unless Current.account.present?
      redirect_to main_app.session_menu_path(script_name: nil)
    end
  end
```

**Disallow Account Scope** (for global routes):
```ruby
class_methods do
  def disallow_account_scope(**options)
    skip_before_action :require_account, **options
    before_action :redirect_tenanted_request, **options
  end
end
```

**Current Attributes** (`app/models/current.rb`):
```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :identity, :account

  def session=(value)
    super(value)
    self.identity = session.identity if value.present?
  end

  def identity=(identity)
    super(identity)
    self.user = identity.users.find_by(account: account) if identity.present?
  end

  def with_account(value, &)
    with(account: value, &)
  end
end
```

Key security features:
- Account extracted from URL path, not user input
- `Current.account` scoped to request lifecycle
- `Current.user` automatically resolved from identity + account
- Routes without account scope redirect appropriately

**Source files**:
- `config/initializers/tenanting/account_slug.rb`
- `app/controllers/concerns/authentication.rb`
- `app/models/current.rb`

---

## 7. CSRF Protection (Request Forgery Protection)

### Problem
Cross-Site Request Forgery (CSRF) attacks trick authenticated users into submitting malicious requests. Traditional CSRF tokens can be cumbersome with modern JavaScript frameworks.

### Solution
Use the `Sec-Fetch-Site` header (available in modern browsers) for origin verification, falling back to standard CSRF for older browsers.

**On Rails 8.2+, use the built-in strategy instead of the custom concern below:**
```ruby
# config/application.rb
config.action_controller.forgery_protection_strategy = :header_or_legacy_token
```
This verifies `Sec-Fetch-Site` and falls back to the classic token for browsers that don't send it. Browser support floor: Chrome 76+ (2019), Edge 79+ (2020), Firefox 90+ (2021), Safari 16.4+ (2023). Header-based CSRF also removes the need for token plumbing that fights page caching — `csrf_meta_tags` in cached layouts, token-refresh JavaScript, and "token dispenser" endpoints can all go.

On older Rails, implement it yourself:

### Example

**Custom Forgery Protection** (`app/controllers/concerns/request_forgery_protection.rb`):
```ruby
module RequestForgeryProtection
  extend ActiveSupport::Concern

  included do
    after_action :append_sec_fetch_site_to_vary_header
  end

  private
    def append_sec_fetch_site_to_vary_header
      vary_header = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:blank?)
      response.headers["Vary"] = (vary_header + [ "Sec-Fetch-Site" ]).join(",")
    end

    def verified_request?
      request.get? || request.head? || !protect_against_forgery? ||
        (valid_request_origin? && safe_fetch_site?)
    end

    SAFE_FETCH_SITES = %w[ same-origin same-site ]

    def safe_fetch_site?
      SAFE_FETCH_SITES.include?(sec_fetch_site_value) ||
        (sec_fetch_site_value.nil? && api_request?)
    end

    def api_request?
      request.format.json?
    end

    def sec_fetch_site_value
      request.headers["Sec-Fetch-Site"].to_s.downcase.presence
    end
end
```

**Including in Application Controller** (`app/controllers/application_controller.rb`):
```ruby
class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
  include RequestForgeryProtection
  # ...
end
```

**Skipping for PWA** (`app/controllers/pwa_controller.rb`):
```ruby
class PwaController < ApplicationController
  disallow_account_scope
  skip_forgery_protection

  def service_worker
  end
end
```

Key features:
- Modern browsers send `Sec-Fetch-Site` header automatically
- Only "same-origin" and "same-site" requests are allowed
- API requests (JSON) without the header are allowed (use bearer token auth)
- Adds `Vary: Sec-Fetch-Site` for proper caching
- Skip only for truly public endpoints (PWA service worker)

**Source files**:
- `app/controllers/concerns/request_forgery_protection.rb`
- `app/controllers/application_controller.rb`
- `app/controllers/pwa_controller.rb`

---

## Security Checklist

When implementing new features, verify:

- [ ] **Authentication required?** Use `require_authentication` (default) or explicitly `allow_unauthenticated_access`
- [ ] **Admin-only?** Add `before_action :ensure_admin`
- [ ] **Staff-only?** Add `before_action :ensure_staff`
- [ ] **Rate limit sensitive actions?** Add `rate_limit to: N, within: X.minutes`
- [ ] **Account-scoped?** Ensure data queries include `Current.account`
- [ ] **Timing-safe comparisons?** Use `ActiveSupport::SecurityUtils.secure_compare` for secrets
- [ ] **Signed/encrypted cookies?** Use `cookies.signed` or `cookies.encrypted`
- [ ] **Signed IDs for URLs?** Use `model.signed_id` for unguessable references
