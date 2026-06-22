# Rails API

Apply when: building a JSON API with Rails, adding an API namespace to an existing Rails app, or evaluating API design choices.

---

## 1. API-only mode

For standalone APIs, generate with `--api` to strip unnecessary middleware (views, assets, sessions, cookies):

```bash
rails new my_api --api
```

`ApplicationController` inherits from `ActionController::API` instead of `ActionController::Base`. Renders nothing for unknown formats (no HTML fallback).

For an API namespace added to an existing full-stack app, keep `ApplicationController < ActionController::Base` and use a dedicated base for API controllers:

```ruby
# app/controllers/api/base_controller.rb
module Api
  class BaseController < ActionController::API
    include ActionController::MimeResponds

    before_action :require_api_authentication

    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    rescue_from ActionController::ParameterMissing, with: :unprocessable_entity
  end
end
```

## 2. Versioning

Namespace by version so you can introduce `v2` without breaking `v1` clients:

```ruby
# config/routes.rb
namespace :api do
  namespace :v1 do
    resources :articles, only: [:index, :show, :create, :update, :destroy]
    resources :users, only: [:show, :create]
  end
end
```

Controllers live at `app/controllers/api/v1/` and inherit from `Api::BaseController`. URL versioning (the above) is simpler and visible in logs; use `Accept` header versioning only if you have a specific reason.

## 3. Serialization

### Jbuilder (default, no extra gem)

Good for: straightforward response shapes, few endpoints, templates close to AR models.

```ruby
# app/views/api/v1/articles/show.json.jbuilder
json.id @article.id
json.title @article.title
json.body @article.body
json.author do
  json.id @article.author.id
  json.name @article.author.name
end
json.created_at @article.created_at.iso8601
```

Use `json.partial!` for shared representations. Add `json.cache! cache_key, expires_in: 1.hour do` for high-traffic endpoints.

### Blueprinter (explicit, fast)

Good for: many endpoints, consistent shape across controllers, easy unit testing.

```ruby
# app/blueprints/article_blueprint.rb
class ArticleBlueprint < Blueprinter::Base
  identifier :id
  fields :title, :body, :created_at

  view :with_author do
    association :author, blueprint: UserBlueprint
  end
end
```

```ruby
# controller
render json: ArticleBlueprint.render(@article, view: :with_author)
```

Pick one serialization approach per app — mixing Jbuilder and Blueprinter adds confusion without benefit.

## 4. CORS

Add `rack-cors` to `Gemfile`:

```ruby
gem "rack-cors"
```

Configure in `config/application.rb` (or an initializer):

```ruby
config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("CORS_ORIGINS", "http://localhost:3000").split(",")
    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      expose: ["X-Request-Id"],
      max_age: 600
  end
end
```

Keep `origins` locked down in production — never `origins "*"` on an authenticated API. Use an env var so staging/prod origins can differ without code changes.

## 5. Pagination

Use `pagy` — leaner than Kaminari/will_paginate for pure JSON APIs:

```ruby
gem "pagy"
```

```ruby
# app/controllers/api/base_controller.rb
include Pagy::Backend

private

def pagy_metadata_for(pagy)
  { count: pagy.count, page: pagy.page, pages: pagy.pages, per_page: pagy.limit }
end
```

```ruby
# controller action
pagy, @articles = pagy(Article.published, limit: params[:per_page] || 25)
render json: {
  data: ArticleBlueprint.render_as_hash(@articles),
  meta: pagy_metadata_for(pagy)
}
```

Always paginate collections — never return unbounded `Model.all` to an API client.

### Keyset (cursor) pagination for large or append-heavy collections

Offset pagination (`pagy`, `LIMIT/OFFSET`) is fine for admin lists, but it degrades on large datasets — the database still scans and discards every skipped row, so deep pages get slower — and it's unstable while the collection changes: a row inserted or deleted between requests shifts the window, so the client skips or repeats records. For big feeds, infinite scroll, and public list endpoints, paginate by a **cursor** on the ordered key instead:

```ruby
# controller action — /api/v1/articles?after=<cursor>&per_page=25
def index
  limit = (params[:per_page] || 25).to_i.clamp(1, 100)
  scope = Article.published.order(created_at: :desc, id: :desc)

  if (cursor = decode_cursor(params[:after]))
    created_at, id = cursor
    # row-value comparison walks straight to the next page — no offset scan
    scope = scope.where("(created_at, id) < (?, ?)", created_at, id)
  end

  articles = scope.limit(limit + 1).to_a   # fetch one extra to detect "more"
  has_more = articles.size > limit
  articles = articles.first(limit)

  render json: {
    data: ArticleBlueprint.render_as_hash(articles),
    meta: { has_more:, next_cursor: (encode_cursor(articles.last) if has_more) }
  }
end

private

def encode_cursor(record)
  Base64.urlsafe_encode64([record.created_at.iso8601(6), record.id].to_json)
end

def decode_cursor(value)
  return if value.blank?
  JSON.parse(Base64.urlsafe_decode64(value))
rescue ArgumentError, JSON::ParserError
  nil # treat a malformed cursor as "start from the beginning"
end
```

Key points:
- **Order by a unique, stable tuple** (`created_at, id`) so the cursor is unambiguous when timestamps collide — never order by `created_at` alone.
- Return an **opaque `next_cursor`** (encode the tuple) plus a **`has_more`** flag instead of total page counts; computing `count` on a huge table is its own slow query.
- A `(created_at, id)` composite index makes the row-value comparison an index range scan. See [[rails-database-performance]] for the index.
- Trade-off: no "jump to page N" and no total count. Keep offset pagination where the UI needs page numbers.

## 6. Standardized JSON errors

Consistent error shape across all endpoints makes client error handling predictable:

```ruby
# app/controllers/api/base_controller.rb
rescue_from ActiveRecord::RecordNotFound, with: :not_found
rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity
rescue_from ActionController::ParameterMissing, with: :unprocessable_entity

private

def not_found(e)
  render json: { error: "not_found", message: e.message }, status: :not_found
end

def unprocessable_entity(e)
  errors = e.respond_to?(:record) ? e.record.errors.as_json : { base: [e.message] }
  render json: { error: "unprocessable_entity", errors: errors }, status: :unprocessable_entity
end
```

Use Rails' symbolic HTTP status names (`:not_found`, `:unauthorized`, `:forbidden`, `:unprocessable_entity`) rather than integers — intent is readable in code.

## 7. Authentication

Token-based and session-based auth patterns belong in `rails-security`. For APIs specifically:

- Prefer bearer tokens (`Authorization: Bearer <token>`) over cookie sessions for cross-origin clients.
- If the API is consumed only by your own Hotwire frontend on the same origin, session-based auth (CSRF-protected) is simpler and more secure than rolling your own tokens.
- `authenticate_or_request_with_http_token` is built into Rails — reach for it before adding Devise Token Auth or similar gems.

## 8. Testing

### Request specs (RSpec)

```ruby
# spec/requests/api/v1/articles_spec.rb
RSpec.describe "GET /api/v1/articles", type: :request do
  let!(:articles) { create_list(:article, 3, :published) }

  it "returns paginated articles" do
    get "/api/v1/articles", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["data"].length).to eq(3)
    expect(body["meta"]["count"]).to eq(3)
  end

  it "returns 401 without auth" do
    get "/api/v1/articles"
    expect(response).to have_http_status(:unauthorized)
  end
end
```

### Minitest integration tests

```ruby
# test/integration/api/v1/articles_test.rb
class Api::V1::ArticlesTest < ActionDispatch::IntegrationTest
  def test_index_returns_paginated_articles
    get api_v1_articles_path, headers: { "Authorization" => "Bearer #{tokens(:alice)}" }
    assert_response :ok
    body = response.parsed_body
    assert_kind_of Array, body["data"]
    assert body["meta"]["count"] >= 0
  end
end
```

Test the HTTP contract (status, shape, pagination meta) — not serializer internals. Serializer unit tests belong separately if you use Blueprinter.

## API checklist

Before shipping an API endpoint:

- [ ] Route is namespaced and versioned (`api/v1/`)
- [ ] Controller inherits from `Api::BaseController`
- [ ] Collections are paginated; shape includes `meta.count`/`meta.pages`
- [ ] CORS origins locked to known values via env var (not `"*"`)
- [ ] `rescue_from` covers `RecordNotFound`, `RecordInvalid`, `ParameterMissing`
- [ ] Authentication gate via `before_action :require_api_authentication`
- [ ] JSON shape is stable: no Ruby class names, no `nil` fields leaking internal state
- [ ] Request spec or integration test covers happy path and at least one error path
