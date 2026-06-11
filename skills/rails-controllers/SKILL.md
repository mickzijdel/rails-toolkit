---
name: rails-controllers
description: Use when writing thin controllers with concerns, resource-oriented design, and REST patterns
---

# Rails Controller Patterns

## When to Use
- Creating new controllers
- Organizing controller logic with concerns
- Designing RESTful resources
- Adding caching with ETags
- Handling multiple response formats

---

## Pattern 1: Thin ApplicationController with Concerns

### Problem
ApplicationController becomes bloated with authentication, authorization, request handling, and cross-cutting concerns.

### Solution
Keep ApplicationController minimal by extracting all behavior into focused concerns. Each concern handles one responsibility.

### Example

**From** `app/controllers/application_controller.rb`:
```ruby
class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
  include BlockSearchEngineIndexing
  include CurrentRequest, CurrentTimezone, SetPlatform
  include RequestForgeryProtection
  include TurboFlash, ViewTransitions
  include RoutingHeaders

  etag { "v1" }
  stale_when_importmap_changes
  allow_browser versions: :modern
end
```

The base controller is just a composition of concerns plus a few global settings. All logic lives in the included modules.

---

## Pattern 2: Resource Scoping Concerns

### Problem
Multiple controllers need to load the same parent resource and perform similar setup. Duplicating `before_action :set_card` leads to inconsistency.

### Solution
Create `*Scoped` concerns that handle resource loading and provide shared helper methods for controllers working with that resource.

### Example

**From** `app/controllers/concerns/card_scoped.rb`:
```ruby
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

    def capture_card_location
      @source_column = @card.column
      @was_in_stream = @card.awaiting_triage?
    end
end
```

**From** `app/controllers/concerns/board_scoped.rb`:
```ruby
module BoardScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_board
  end

  private
    def set_board
      @board = Current.user.boards.find(params[:board_id])
    end

    def ensure_permission_to_admin_board
      unless Current.user.can_administer_board?(@board)
        head :forbidden
      end
    end
end
```

**From** `app/controllers/concerns/column_scoped.rb`:
```ruby
module ColumnScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_column
  end

  private
    def set_column
      @column = Current.user.accessible_columns.find(params[:column_id])
    end
end
```

**Usage in a controller** - `app/controllers/cards/comments_controller.rb`:
```ruby
class Cards::CommentsController < ApplicationController
  include CardScoped

  before_action :set_comment, only: %i[ show edit update destroy ]
  # CardScoped already sets @card and @board via before_action
end
```

---

## Pattern 3: Resource-Oriented Design (Non-CRUD as Nested Resources)

### Problem
Actions like "close", "reopen", "watch", "gild" don't map to standard CRUD verbs. Adding custom routes creates inconsistent APIs.

### Solution
Model state changes as separate singular resources nested under the parent. Create = turn on, Destroy = turn off.

### Example

**Routes** - `config/routes.rb`:
```ruby
# Bad: custom actions
resources :cards do
  post :close
  post :reopen
  post :watch
  post :unwatch
  post :gild
  post :ungild
end

# Good: singular nested resources
resources :cards do
  scope module: :cards do
    resource :closure        # POST = close, DELETE = reopen
    resource :goldness       # POST = gild, DELETE = ungild
    resource :watch          # POST = watch, DELETE = unwatch
    resource :pin            # POST = pin, DELETE = unpin
    resource :not_now        # POST = postpone
    resource :triage         # POST = return to triage
    resource :publish        # POST = publish
  end
end
```

**Controller** - `app/controllers/cards/closures_controller.rb`:
```ruby
class Cards::ClosuresController < ApplicationController
  include CardScoped

  def create
    capture_card_location
    @card.close
    refresh_stream_if_needed

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  def destroy
    @card.reopen
    refresh_stream_after_reopen

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
```

**Controller** - `app/controllers/cards/goldnesses_controller.rb`:
```ruby
class Cards::GoldnessesController < ApplicationController
  include CardScoped

  def create
    @card.gild

    respond_to do |format|
      format.turbo_stream { render_card_replacement }
      format.json { head :no_content }
    end
  end

  def destroy
    @card.ungild

    respond_to do |format|
      format.turbo_stream { render_card_replacement }
      format.json { head :no_content }
    end
  end
end
```

**Controller** - `app/controllers/cards/watches_controller.rb`:
```ruby
class Cards::WatchesController < ApplicationController
  include CardScoped

  def show
    fresh_when etag: @card.watch_for(Current.user) || "none"
  end

  def create
    @card.watch_by Current.user

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  def destroy
    @card.unwatch_by Current.user

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
```

---

## Pattern 4: Scoped Resource Loading with Authorization

### Problem
Loading resources without considering user access creates security holes. Raw `Card.find(params[:id])` bypasses access control.

### Solution
Always load resources through scoped associations that respect user permissions: `Current.user.accessible_cards`, `Current.user.boards`, etc.

### Example

**From** `app/controllers/cards_controller.rb`:
```ruby
class CardsController < ApplicationController
  before_action :set_card, only: %i[ show edit update destroy ]

  private
    def set_card
      # Uses accessible_cards scope which respects board access permissions
      @card = Current.user.accessible_cards.find_by!(number: params[:id])
    end
end
```

**From** `app/controllers/boards_controller.rb`:
```ruby
class BoardsController < ApplicationController
  before_action :set_board, except: %i[ index new create ]

  private
    def set_board
      # Only returns boards the user has access to
      @board = Current.user.boards.find params[:id]
    end
end
```

**From** `app/controllers/users_controller.rb`:
```ruby
class UsersController < ApplicationController
  before_action :set_user, except: %i[ index ]

  private
    def set_user
      # Scoped to current account and active users only
      @user = Current.account.users.active.find(params[:id])
    end
end
```

**From** `app/controllers/concerns/column_scoped.rb`:
```ruby
def set_column
  @column = Current.user.accessible_columns.find(params[:column_id])
end
```

---

## Pattern 5: Permission Checks with before_action

### Problem
Authorization logic scattered throughout controller actions is error-prone and hard to audit.

### Solution
Use `before_action` with `ensure_permission_to_*` methods that call `head :forbidden` when access is denied.

### Example

**From** `app/controllers/cards_controller.rb`:
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

**From** `app/controllers/boards_controller.rb`:
```ruby
class BoardsController < ApplicationController
  before_action :set_board, except: %i[ index new create ]
  before_action :ensure_permission_to_admin_board, only: %i[ update destroy ]

  private
    def ensure_permission_to_admin_board
      unless Current.user.can_administer_board?(@board)
        head :forbidden
      end
    end
end
```

**From** `app/controllers/users/roles_controller.rb`:
```ruby
class Users::RolesController < ApplicationController
  before_action :set_user
  before_action :ensure_permission_to_administer_user

  private
    def ensure_permission_to_administer_user
      head :forbidden unless Current.user.can_administer?(@user)
    end
end
```

**From** `app/controllers/boards/publications_controller.rb`:
```ruby
class Boards::PublicationsController < ApplicationController
  include BoardScoped

  before_action :ensure_permission_to_admin_board  # From BoardScoped concern

  def create
    @board.publish
  end

  def destroy
    @board.unpublish
    @board.reload
  end
end
```

**From** `app/controllers/webhooks_controller.rb`:
```ruby
class WebhooksController < ApplicationController
  include BoardScoped

  before_action :ensure_admin  # From Authorization concern
  before_action :set_webhook, except: %i[ index new create ]
end
```

---

## Pattern 6: ETags for HTTP Caching

### Problem
Responses that haven't changed are re-rendered and sent, wasting server resources and bandwidth.

### Solution
Use `fresh_when` with ETags based on the data being rendered. Rails returns 304 Not Modified when the client's cached version matches.

### Example

**Simple ETag with single record** - `app/controllers/events_controller.rb`:
```ruby
class EventsController < ApplicationController
  include DayTimelinesScoped

  def index
    fresh_when @day_timeline
  end
end
```

**ETag with collection** - `app/controllers/boards/columns_controller.rb`:
```ruby
class Boards::ColumnsController < ApplicationController
  include BoardScoped

  def index
    @columns = @board.columns.sorted
    fresh_when etag: @columns
  end

  def show
    set_page_and_extract_portion_from @column.cards.active.latest.with_golden_first.preloaded
    fresh_when etag: @page.records
  end
end
```

**ETag with multiple values** - `app/controllers/boards_controller.rb`:
```ruby
class BoardsController < ApplicationController
  def show
    # ...
    fresh_when etag: [ @board, @page.records, @user_filtering, Current.account ]
  end
end
```

**ETag with optional resource** - `app/controllers/cards/watches_controller.rb`:
```ruby
class Cards::WatchesController < ApplicationController
  include CardScoped

  def show
    fresh_when etag: @card.watch_for(Current.user) || "none"
  end
end
```

**ETag with complex dependencies** - `app/controllers/my/menus_controller.rb`:
```ruby
def show
  # ...
  fresh_when etag: [ @filters, @boards, @tags, @users, @accounts ]
end
```

**Global ETag in ApplicationController** - `app/controllers/application_controller.rb`:
```ruby
class ApplicationController < ActionController::Base
  etag { "v1" }  # Bump when changing response format
end
```

---

## Pattern 7: Multiple Format Responses

### Problem
Controllers need to support HTML, JSON API, and Turbo Stream responses with appropriate behavior for each.

### Solution
Use `respond_to` blocks to handle different formats. Common patterns: HTML redirects, JSON returns status codes, Turbo Stream renders partials.

### Example

**Standard CRUD response** - `app/controllers/cards_controller.rb`:
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

def destroy
  @card.destroy!

  respond_to do |format|
    format.html { redirect_to @card.board, notice: "Card deleted" }
    format.json { head :no_content }
  end
end
```

**State change response** - `app/controllers/cards/closures_controller.rb`:
```ruby
def create
  capture_card_location
  @card.close
  refresh_stream_if_needed

  respond_to do |format|
    format.turbo_stream
    format.json { head :no_content }
  end
end
```

**Conditional success/failure** - `app/controllers/cards/assignments_controller.rb`:
```ruby
def create
  if @card.toggle_assignment @board.users.active.find(params[:assignee_id])
    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  else
    respond_to do |format|
      format.turbo_stream
      format.json { head :unprocessable_entity }
    end
  end
end
```

**HTML with validation errors** - `app/controllers/users_controller.rb`:
```ruby
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

### Problem
Controllers grow fat with business logic, making testing difficult and creating coupling between HTTP concerns and domain logic.

### Solution
Keep controllers thin - they should only handle HTTP concerns (params, responses, redirects). Delegate all business logic to model methods with intention-revealing names.

### Example

**Thin controller** - `app/controllers/cards/goldnesses_controller.rb`:
```ruby
class Cards::GoldnessesController < ApplicationController
  include CardScoped

  def create
    @card.gild  # Business logic lives in Card model

    respond_to do |format|
      format.turbo_stream { render_card_replacement }
      format.json { head :no_content }
    end
  end

  def destroy
    @card.ungild  # Business logic lives in Card model

    respond_to do |format|
      format.turbo_stream { render_card_replacement }
      format.json { head :no_content }
    end
  end
end
```

**Thin controller** - `app/controllers/boards/publications_controller.rb`:
```ruby
class Boards::PublicationsController < ApplicationController
  include BoardScoped

  before_action :ensure_permission_to_admin_board

  def create
    @board.publish  # Business logic lives in Board model
  end

  def destroy
    @board.unpublish  # Business logic lives in Board model
    @board.reload
  end
end
```

**Thin controller** - `app/controllers/boards/involvements_controller.rb`:
```ruby
class Boards::InvolvementsController < ApplicationController
  include BoardScoped

  def update
    @board.access_for(Current.user).update!(involvement: params[:involvement])
  end
end
```

**Plain ActiveRecord operations are fine** - `app/controllers/cards/comments_controller.rb`:
```ruby
def create
  @comment = @card.comments.create!(comment_params)

  respond_to do |format|
    format.turbo_stream
    format.json { head :created, location: card_comment_path(@card, @comment, format: :json) }
  end
end
```

---

## Pattern 9: URL as State for GET Actions

**Problem:** Filters, tabs, search terms, and sort orders stored in session or JavaScript state make views impossible to link, bookmark, or share, and a refresh loses them.

**Solution:** For GET actions, keep UI state in readable URL query params. The URL is the canonical state: shareable, bookmarkable, refresh-safe, and back-button-friendly.

**Example:**
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
- Filter links become shareable deep links (e.g. a per-company listing URL) for free.
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
| ETags with fresh_when | Cacheable GET requests |
| respond_to blocks | Supporting multiple response formats |
| Thin Controllers | Always - delegate logic to models |
| URL as State | GET actions with filters, tabs, search, or sort |
