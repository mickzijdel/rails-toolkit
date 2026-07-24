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

**Don't let `ApplicationController` become a dumping ground.** Because it's already a
grab-bag, every new method feels free — "will one more method among 25 really hurt?" — and
the file grows into a pile of unrelated helpers (current-user checks, default redirects,
`production?`/`staging?` environment checks, `www`-canonicalisation, response-header
setters, …) that nobody dares move or delete because they might be referenced from
anywhere. That's not a crisis, but it's real cognitive load on every controller in the app.

When you add a method to `ApplicationController` — or find one already bloated — apply three rules:

1. **Group related methods and label each group with a comment.** Similar methods should sit
   together, not be scattered, so the next reader can scan the file.
2. **Don't make a method globally accessible unless it needs to be.** A method that backs a
   `before_action` running on every request earns its place here. A method used by only one
   or two controllers (out of 20+) does not — move it into a concern and `include` it only in
   the controllers that need it (see Pattern 2 and the `*Scoped` concerns below).
3. **Two or more related methods → extract them into a named concern.** A cluster like
   CDN/cache header setters becomes `app/controllers/concerns/akamai.rb`, leaving a single
   `include Akamai` line. The behaviour stays available but is contained, named, and testable
   in isolation.

```ruby
# Bad: a dumping ground — unrelated helpers, no grouping, all global
class ApplicationController < ActionController::Base
  def current_account; ...; end
  def set_cache_headers; response.headers["Cache-Control"] = ...; end
  def force_www; redirect_to "https://www.#{request.host}..." unless ...; end
  def production?; Rails.env.production?; end
  def purge_cdn(path); ...; end
  def redirect_to_dashboard; ...; end
  def staging?; Rails.env.staging?; end
  def set_surrogate_key(*keys); response.headers["Surrogate-Key"] = ...; end
  # ...20 more, in no particular order
end

# Good: each cluster extracted into a named concern, base stays a manifest
class ApplicationController < ActionController::Base
  include Authentication      # current_account & friends
  include CanonicalHost       # force_www, host canonicalisation
  include Akamai              # set_cache_headers, set_surrogate_key, purge_cdn
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

**Turning a verb into a noun.** When you reach for a custom action, name the *thing* the verb produces and route to its `create`/`destroy`:

| Tempting verb action | Noun resource | Maps to |
|---|---|---|
| `POST cards/:id/close` | `resource :closure` | `Cards::ClosuresController#create` (`destroy` = reopen) |
| `POST posts/:id/archive` | `resource :archive` | `Posts::ArchivesController#create` (`destroy` = unarchive) |
| `POST posts/:id/publish` | `resource :publication` | `Posts::PublicationsController#create` |
| `POST users/:id/follow` | `resource :follow` | `Users::FollowsController#create` (`destroy` = unfollow) |
| `POST pages/:id/visit` | `resource :visit` | `Pages::VisitsController#create` |

The on/off pair (`create`/`destroy`) keeps the controller RESTful and the routes guessable. Reserve `member`/`collection` custom routes for genuinely actionless endpoints that don't represent a resource.

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

## Pattern 10: One-Line Route Docstrings on Actions

Give each public action a single comment naming its HTTP verb and path. It makes the controller scannable as a route map and catches actions that have drifted from their route (or shouldn't exist).

```ruby
class PostsController < ApplicationController
  # GET /posts
  def index; end

  # GET /posts/:id
  def show; end

  # POST /posts
  def create; end

  # DELETE /posts/:id
  def destroy; end
end
```

Keep it to one line per action; the docstring describes the route, not the implementation. `bin/rails routes -c posts` is the source of truth if a comment and the routes disagree.

---

## Pattern 11: Treat `params` as Read-Only — Never Mutate It

`params` is an `ActionController::Parameters`, and because it quacks like a Hash it's tempting to treat it as a scratchpad: normalise a value, delete a key a third-party API chokes on, merge in a default. Don't. `params` is **shared request state**. Every later line in the request — and any other code the params flow into (`update`, `create!`, a job, a serializer) — reads from the same object. Mutate it in one spot and you've silently changed the input for everything downstream. It's a debugging nightmare: the data is present at the top of the action and gone by the bottom, with nothing in the diff of the failing code to explain where it went.

```ruby
# Bad — writing back into the request's params
def create
  params[:title] = params[:title].strip        # normalise in place
  params.delete(:honeypot)                      # drop a field before handing off
  params.merge!(account: Current.account)       # inject a value
  Thing.create!(thing_params)
end

# Good — read from params freely; build a SEPARATE hash and shape that
def create
  attrs = thing_params.merge(account: Current.account)  # non-bang merge → a new copy
  attrs[:title] = attrs[:title].to_s.strip              # []= on OUR copy is fine — attrs isn't params
  Thing.create!(attrs)
end
```

Two things make the "good" version fine, and they're the crux of the rule:

- **The rule is "don't mutate `params`", not "never merge or assign".** `merge` and `[]=` are perfectly fine the moment the receiver is an object *you* own (`attrs`) rather than the shared `params`.
- **Bang vs non-bang matters even on a copy.** `merge`/`except` return a **new** object; only `merge!`/`except!`/`delete` mutate the receiver in place. And `:honeypot` needs no handling at all — `thing_params` simply never permitted it (see Pattern 4), so it's already gone; reaching into `params` to delete it was solving a problem strong params already solved.

**The aliasing trap.** Assigning `params` to another variable does **not** copy it — both names point at the same object, so mutating the "copy" mutates `params`:

```ruby
mine = params
mine.delete(:q)   # params[:q] is now gone too
```

`.dup`/`.clone` only shallow-copy, so nested hashes are still shared. If you genuinely need a mutable structure, build your own: `params.permit(...).to_h` gives a plain, detached `Hash` you can do anything to.

**Where the need really comes from.** Almost every in-place mutation is a workaround for something that belongs elsewhere:

| Temptation | Do this instead |
|---|---|
| Set a default value | Default in the DB column, the model (`attribute :x, default:`), or `before_validation` |
| Normalise user input | Model `normalizes :attr, with:` (Rails 7.1+), or derive a local before use |
| Strip a key a 3rd-party API rejects | Build the API payload as its own hash from permitted params — don't reach back into `params` |

The mechanical version of this rule is enforceable with a small custom RuboCop cop — see [[rails-style]] §10.

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
| Verb→noun nested resource | Naming a non-CRUD action (archive→`ArchivesController#create`) |
| `# GET /posts/:id` docstrings | Every public action — scannable route map |
| Never mutate `params` | Always — derive a new hash; `params` is shared request state |
