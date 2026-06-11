---
name: rails-controllers
description: Use when writing thin controllers with concerns, resource-oriented design, and REST patterns
---

# Rails Controller Patterns

## Pattern 1: Thin ApplicationController with Concerns

The base controller is just a composition of concerns plus a few global settings. All logic lives in the included modules.

```ruby
class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
  include BlockSearchEngineIndexing
  include CurrentRequest, CurrentTimezone, SetPlatform
  include RequestForgeryProtection
  include TurboFlash, ViewTransitions

  etag { "v1" }
  stale_when_importmap_changes
  allow_browser versions: :modern
end
```

---

## Pattern 2: Resource Scoping Concerns

When multiple controllers load the same parent resource, create a `*Scoped` concern that handles the loading and provides shared helpers:

```ruby
# app/controllers/concerns/card_scoped.rb
module CardScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_card, :set_board
  end

  private
    def set_card
      @card = Current.user.accessible_cards.find_by!(number: params[:card_id])
    end

    def set_board
      @board = @card.board
    end

    def render_card_replacement
      render turbo_stream: turbo_stream.replace(
        [ @card, :card_container ],
        partial: "cards/container",
        method: :morph,
        locals: { card: @card.reload }
      )
    end
end
```

```ruby
class Cards::CommentsController < ApplicationController
  include CardScoped   # sets @card and @board via before_action

  before_action :set_comment, only: %i[ show edit update destroy ]
end
```

---

## Pattern 3: Resource-Oriented Design (Non-CRUD as Nested Resources)

Actions like "close", "reopen", "watch" don't map to CRUD verbs. Don't add custom routes — model the state change as a singular resource nested under the parent: create = turn on, destroy = turn off.

```ruby
# Bad: custom actions
resources :cards do
  post :close
  post :reopen
end

# Good: singular nested resources
resources :cards do
  scope module: :cards do
    resource :closure        # POST = close, DELETE = reopen
    resource :goldness       # POST = gild, DELETE = ungild
    resource :watch          # POST = watch, DELETE = unwatch
    resource :pin            # POST = pin, DELETE = unpin
    resource :publish        # POST = publish
  end
end
```

```ruby
class Cards::ClosuresController < ApplicationController
  include CardScoped

  def create
    @card.close

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  def destroy
    @card.reopen

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
```

---

## Pattern 4: Scoped Resource Loading with Authorization

Raw `Card.find(params[:id])` bypasses access control. Always load resources through scoped associations that respect user permissions:

```ruby
def set_card
  # accessible_cards respects board access permissions
  @card = Current.user.accessible_cards.find_by!(number: params[:id])
end

def set_user
  # scoped to current account and active users only
  @user = Current.account.users.active.find(params[:id])
end
```

---

## Pattern 5: Permission Checks with before_action

Centralize authorization in `before_action` filters named `ensure_permission_to_*` that `head :forbidden` when denied:

```ruby
class CardsController < ApplicationController
  before_action :set_card, only: %i[ show edit update destroy ]
  before_action :ensure_permission_to_administer_card, only: %i[ destroy ]

  private
    def ensure_permission_to_administer_card
      head :forbidden unless Current.user.can_administer_card?(@card)
    end
end
```

Put shared checks in the scoping concern (e.g. `ensure_permission_to_admin_board` in `BoardScoped`) so controllers just declare `before_action :ensure_permission_to_admin_board`.

---

## Pattern 6: ETags for HTTP Caching

Use `fresh_when` with ETags based on the data being rendered; Rails returns 304 Not Modified when the client's cached version matches.

```ruby
def index
  @columns = @board.columns.sorted
  fresh_when etag: @columns
end
```

Full treatment (multi-object ETags, `stale?`, global etag components): [[rails-performance]].

---

## Pattern 7: Multiple Format Responses

Use `respond_to` blocks for HTML, JSON, and Turbo Stream. Conventions: HTML redirects, JSON returns status codes, Turbo Stream renders the matching `.turbo_stream.erb` template.

```ruby
def create
  respond_to do |format|
    format.html do
      card = @board.cards.find_or_create_by!(creator: Current.user, status: "drafted")
      redirect_to card
    end

    format.json do
      card = @board.cards.create! card_params.merge(creator: Current.user, status: "published")
      head :created, location: card_path(card, format: :json)
    end
  end
end

def update
  @card.update! card_params

  respond_to do |format|
    format.turbo_stream
    format.json { render :show }
  end
end
```

```ruby
# HTML with validation errors
def update
  if @user.update(user_params)
    respond_to do |format|
      format.html { redirect_to @user }
      format.json { head :no_content }
    end
  else
    respond_to do |format|
      format.html { render :edit, status: :unprocessable_entity }
      format.json { render json: @user.errors, status: :unprocessable_entity }
    end
  end
end
```

---

## Pattern 8: Thin Controllers with Rich Models

Controllers handle HTTP concerns only (params, responses, redirects). Business logic lives in model methods with intention-revealing names; plain ActiveRecord operations are fine too — no service layer in between.

```ruby
class Boards::PublicationsController < ApplicationController
  include BoardScoped

  before_action :ensure_permission_to_admin_board

  def create
    @board.publish    # business logic lives in Board
  end

  def destroy
    @board.unpublish
  end
end

# Plain ActiveRecord is fine
def create
  @comment = @card.comments.create!(comment_params)
end
```

---

## Pattern 9: URL as State for GET Actions

Filters, tabs, search terms, and sort orders stored in session or JavaScript state make views impossible to link, bookmark, or share, and a refresh loses them. For GET actions, keep UI state in readable URL query params — shareable, bookmarkable, refresh-safe, back-button-friendly.

```ruby
# /opportunities?category=acting&company=eutc&sort=newest
def index
  @opportunities = Opportunity.listable
    .then { |scope| params[:category].present? ? scope.where(category: params[:category]) : scope }
    .then { |scope| params[:company].present? ? scope.joins(:company).where(companies: { slug: params[:company] }) : scope }
end
```

```erb
<%# Tabs and filters are plain links that change params — no JS state %>
<%= link_to "Acting", opportunities_path(category: :acting) %>
```

**Key Points:**
- Prefer human-readable values (`?category=acting`, slugs) over opaque ids where possible.
- Forms that filter should use `method: :get` so submissions land in the URL.
- Session/cookies are for cross-request identity, not view state.

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| Thin ApplicationController | Always - compose with concerns |
| Resource Scoping Concerns | When multiple controllers share parent resource |
| Nested Singular Resources | Non-CRUD state changes (close, watch, pin) |
| Scoped Resource Loading | Always - load through user's accessible scope |
| Permission before_actions | Restricting actions to authorized users |
| ETags with fresh_when | Cacheable GET requests → [[rails-performance]] |
| respond_to blocks | Supporting multiple response formats |
| Thin Controllers | Always - delegate logic to models |
| URL as State | GET actions with filters, tabs, search, or sort |
