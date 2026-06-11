---
name: rails-security
description: Use when implementing authentication, authorization, or security features in Rails
---

# Rails Security Patterns

## 1. Passwordless Authentication (Magic Links)

Password-based auth brings weak passwords, reuse, and credential stuffing. Magic links instead: user enters email, receives a short-lived code, enters it to authenticate.

```ruby
# app/models/magic_link.rb
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
    destroy   # codes are single-use
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

```ruby
# app/models/identity.rb
def send_magic_link(**attributes)
  magic_links.create!(attributes).tap do |magic_link|
    MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
  end
end

# app/controllers/sessions/magic_links_controller.rb
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

**Key Points:**
- `secure_compare` prevents timing attacks on the email comparison.
- A `Code.sanitize` step handles common user typos (O→0, I/L→1).

---

## 2. Session Management

Store session records in the database, reference them via signed cookies — sessions become trackable, revocable, and auditable.

```ruby
# app/controllers/concerns/authentication.rb
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
    value: session.signed_id,    # tamper-proof token
    httponly: true,              # no JavaScript access
    same_site: :lax              # CSRF protection
  }
end

def resume_session
  if session = find_session_by_cookie
    set_current_session session
  end
end

def find_session_by_cookie
  Session.find_signed(cookies.signed[:session_token])
end

def terminate_session
  Current.session.destroy
  cookies.delete(:session_token)
end
```

---

## 3. Authorization Concern (Role-Based Access)

Define role checks as concern methods, apply them via `before_action` filters.

```ruby
# app/models/user/role.rb
module User::Role
  extend ActiveSupport::Concern

  included do
    enum :role, %i[ owner admin member system ].index_by(&:itself), scopes: false

    scope :owner, -> { where(active: true, role: :owner) }
    scope :admin, -> { where(active: true, role: %i[ owner admin ]) }
    scope :active, -> { where(active: true, role: %i[ owner admin member ]) }

    def admin?
      super || owner?  # owners are also admins
    end
  end

  def can_administer?(other)
    admin? && !other.owner? && other != self
  end
end
```

```ruby
# app/controllers/concerns/authorization.rb
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

```ruby
# Usage
class WebhooksController < ApplicationController
  before_action :ensure_admin
end

class Account::SettingsController < ApplicationController
  before_action :ensure_admin, only: :update
end
```

---

## 4. Bearer Token API Access

Access tokens with read/write permission levels; API requests authenticate via the Authorization header as a fallback to the session.

```ruby
# app/models/identity/access_token.rb
class Identity::AccessToken < ApplicationRecord
  belongs_to :identity

  has_secure_token
  enum :permission, %w[ read write ].index_by(&:itself), default: :read

  def allows?(method)
    method.in?(%w[ GET HEAD ]) || write?
  end
end
```

```ruby
# app/controllers/concerns/authentication.rb
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

```ruby
# Show the token only once: a 10-second expiring signed id for the redirect
class My::AccessTokensController < ApplicationController
  def create
    access_token = Current.identity.access_tokens.create!(access_token_params)
    expiring_id = Rails.application.message_verifier(:access_tokens)
      .generate(access_token.id, expires_in: 10.seconds)

    redirect_to my_access_token_path(expiring_id)
  end
end
```

---

## 5. Rate Limiting

Rails 8's built-in `rate_limit` on brute-forceable endpoints, with a handler for exceeded limits:

```ruby
class SessionsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :create, with: :rate_limit_exceeded

  private
    def rate_limit_exceeded
      respond_to do |format|
        format.html { redirect_to new_session_path, alert: "Try again later." }
        format.json { render json: { message: "Try again later." }, status: :too_many_requests }
      end
    end
end

# Inline handler variant
class SignupsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_signup_path, alert: "Try again later." }
end
```

Scale limits to the endpoint: login/signup 10 per 3 minutes, magic-link verification 10 per 15 minutes, email changes 5 per hour.

---

## 6. Account Scoping (Multi-Tenant Security)

Tenant isolation is the highest-stakes authorization boundary. The mechanism — account-slug middleware, `Current` attributes, `require_account` / `disallow_account_scope` — lives in [[rails-multi-tenancy]]. The security properties to preserve:

- Account is extracted from the URL path by middleware, never from user input.
- `Current.account` is scoped to the request lifecycle; `Current.user` is resolved from identity *and* account, so an identity can never act in an account it has no user in.
- Every tenant-scoped query goes through `Current.account` / the user's accessible scopes ([[rails-controllers]] Pattern 4) — `Model.find(params[:id])` is a cross-tenant leak.
- Routes without account scope must explicitly opt out (`disallow_account_scope`) and redirect tenanted requests away.

---

## 7. CSRF Protection (Request Forgery Protection)

Modern browsers send the `Sec-Fetch-Site` header; verifying it replaces token plumbing that fights page caching (`csrf_meta_tags` in cached layouts, token-refresh JavaScript, "token dispenser" endpoints).

**On Rails 8.2+, use the built-in strategy:**
```ruby
# config/application.rb
config.action_controller.forgery_protection_strategy = :header_or_legacy_token
```
This verifies `Sec-Fetch-Site` and falls back to the classic token for browsers that don't send it. Browser support floor: Chrome 76+ (2019), Edge 79+ (2020), Firefox 90+ (2021), Safari 16.4+ (2023).

**On older Rails, implement it yourself:**

```ruby
# app/controllers/concerns/request_forgery_protection.rb
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
      request.format.json?   # JSON without the header uses bearer token auth
    end

    def sec_fetch_site_value
      request.headers["Sec-Fetch-Site"].to_s.downcase.presence
    end
end
```

Skip forgery protection only for truly public endpoints (e.g. the PWA service worker controller).

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
