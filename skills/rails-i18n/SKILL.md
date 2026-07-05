---
name: rails-i18n
description: Use when adding or auditing internationalization (I18n) — locale file organization, lazy lookup, pluralization, number/date/currency formatting, per-request locale selection, fallbacks, translating validation errors and model/attribute names, and catching missing/unused keys with i18n-tasks. Triggers on "i18n", "internationalization", "translate", "locale", "pluralize", "missing translation", "l10n", "add a language".
---

# Rails Internationalization (I18n)

## 1. Locale File Organization

Nest keys by the same path the code lives at — `views.<controller>.<action>`, `<mailer>.<action>`, `activerecord.models`/`attributes`/`errors` — so a translator (or `grep`) can find a string from its call site alone. One file per locale, not per feature; features already nest under the top-level key.

```yaml
# config/locales/en.yml
en:
  boards:
    show:
      empty_state: "No cards yet. Add the first one."
    create:
      success: "Board created."
  activerecord:
    models:
      board: "Board"
      card:
        one: "Card"
        other: "Cards"
    attributes:
      card:
        title: "Title"
        due_on: "Due date"
    errors:
      models:
        card:
          attributes:
            title:
              blank: "can't be empty"
```

```ruby
# config/application.rb
config.i18n.default_locale = :en
config.i18n.available_locales = %i[ en fr de ja ]
config.i18n.fallbacks = true                        # see Pattern 6
# config.i18n.load_path is auto-extended to config/locales/**/*.{rb,yml}; keep locale
# files there rather than adding a custom load_path unless a gem needs one.
```

**Key Points:**
- Split by locale (`en.yml`, `fr.yml`), not by feature (`boards.yml`, `cards.yml`) — a locale file is a translator's unit of work; a feature split forces them to hop files mid-review.
- For large apps, `config/locales/en/boards.yml` (subdirectory, still keyed `en:` at the top) is fine — Rails loads the whole tree. Don't invent a second top-level key per file.
- Keep translator-facing copy out of Ruby string literals entirely, including flash messages and `raise`d user-facing errors — a literal is invisible to `i18n-tasks` (Pattern 7) and silently ships untranslated.

---

## 2. Lazy Lookup — the Leading Dot

Inside a view, controller, or mailer, `t(".key")` infers the scope from the current template/action, so the same partial reused across pages doesn't need the full key spelled out. [[rails-mailers]] Pattern 3 covers this for mailer subjects; the same shorthand applies everywhere:

```erb
<%# app/views/boards/show.html.erb — resolves to boards.show.empty_state %>
<%= t(".empty_state") %>
```

```ruby
class BoardsController < ApplicationController
  def create
    @board = Current.account.boards.create!(board_params)
    redirect_to @board, notice: t(".success")   # boards.create.success
  end
end
```

Lazy lookup only works from a view/controller/mailer context — helpers and models have no implicit scope, so spell the full key there (`I18n.t("activerecord.models.card")`, not a leading dot).

---

## 3. Pluralization

Never string-interpolate a count into a hand-picked singular/plural — locales vary in plural rule count (English has 2, Arabic has 6). Pass `count:` and let I18n pick the CLDR-correct key.

```yaml
en:
  cards:
    count:
      zero: "No cards"
      one: "1 card"
      other: "%{count} cards"
```

```ruby
t("cards.count", count: @cards.size)
```

```ruby
# ❌ Bad — breaks in any locale with more than two plural forms, and reads awkwardly even in English at zero
"#{@cards.size} card#{'s' unless @cards.size == 1}"
```

`ActiveRecord::Base#human_attribute_name` and `Model.model_name.human(count:)` pick up `activerecord.attributes.<model>.<attr>` and `activerecord.models.<model>` the same way — a model translated with `one`/`other` (Pattern 1's `card:` example) renders correctly in both singular and collection contexts without a second lookup.

---

## 4. Number, Date, and Time Formatting

`l` (alias for `I18n.l`) formats `Date`/`Time`/`ActiveSupport::TimeWithZone` per-locale; `number_to_currency`/`number_with_delimiter` do the same for numbers. Both read named formats from the locale file instead of a hardcoded `strftime`.

```yaml
en:
  date:
    formats:
      short_month_day: "%b %-d"     # "Jul 5"
  time:
    formats:
      short: "%b %-d, %l:%M%P"      # "Jul 5, 2:30pm"
  number:
    currency:
      format:
        unit: "$"
        delimiter: ","
        format: "%u%n"
```

```erb
<%= l @card.due_on, format: :short_month_day %>
<%= l @card.created_at, format: :short %>
<%= number_to_currency @invoice.total_cents / 100.0 %>
```

A locale file that only translates `%b`/`%-d`-style keys but never touches `number.currency` will silently render US-formatted currency in every locale — currency and number formats need their own locale entries, they don't fall out of the date/time ones.

---

## 5. Setting the Locale Per Request

Resolve the locale once per request from an explicit signal — URL param, subdomain, or a stored user preference — not solely from `Accept-Language`, which reflects the browser/OS, not necessarily what the signed-in user chose. Fall back to `Accept-Language` only for anonymous visitors.

```ruby
# app/controllers/concerns/setting_locale.rb
module SettingLocale
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
  end

  private
    def switch_locale(&action)
      I18n.with_locale(locale_for_request, &action)
    end

    def locale_for_request
      params[:locale].presence ||
        Current.user&.locale.presence ||
        http_accept_locale ||
        I18n.default_locale
    end

    def http_accept_locale
      request.headers["Accept-Language"].to_s.scan(/^[a-z]{2}/).first
        &.to_sym
        &.then { |candidate| candidate if I18n.available_locales.include?(candidate) }
    end
end
```

`I18n.with_locale` scopes the override to the block and restores the previous value afterward — safe under threaded servers, unlike assigning `I18n.locale =` directly, which leaks across requests sharing a thread if an exception skips the reset.

**Key Points:**
- Persist an explicit user choice (`Current.user.update!(locale: params[:locale])`) rather than re-deriving it from the browser every request — a user who prefers `en` on a `fr` browser shouldn't get overridden silently.
- Validate `params[:locale]` against `I18n.available_locales` before using it — an unvalidated locale param is an easy way to trigger `I18n::InvalidLocale` in production or, worse, load an arbitrary locale file path.

---

## 6. Fallbacks for Partial Translations

New locales are rarely 100% translated on day one. `config.i18n.fallbacks = true` (Pattern 1) falls back missing keys to `I18n.default_locale` instead of raising or rendering `translation missing`. For locale families (regional variants), declare an explicit chain:

```ruby
# config/initializers/i18n.rb
I18n::Backend::Simple.include(I18n::Backend::Fallbacks)
I18n.fallbacks[:"fr-CA"] = [ :"fr-CA", :fr, :en ]
```

Without fallbacks, a single missing key in a 95%-translated locale renders `translation missing: fr.boards.show.new_feature_banner` directly in production HTML — fallbacks degrade to English instead of leaking the raw key to users.

---

## 7. Catching Missing and Unused Keys with i18n-tasks

Locale files drift: keys get added in code but forgotten in non-default locales, or removed from views but left behind in `en.yml`. `i18n-tasks` finds both, and its `health` check is cheap enough to run in CI.

```ruby
# Gemfile
group :development, :test do
  gem "i18n-tasks"
end
```

```bash
bin/rails g i18n-tasks:install     # writes config/i18n-tasks.yml

i18n-tasks missing               # keys used in code but absent from a locale
i18n-tasks unused                # keys defined but never referenced
i18n-tasks normalize             # re-sorts/reformats locale files consistently
i18n-tasks health                # missing + unused + inconsistent interpolations, one summary
```

```yaml
# config/i18n-tasks.yml — the defaults miss dynamic keys; teach it your patterns
ignore_missing:
  - "activerecord.attributes.card.*"   # backfilled from schema, not hand-written
search:
  paths:
    - app/views
    - app/controllers
    - app/mailers
```

CI gate:

```bash
# .github/workflows/ci.yml
- run: bundle exec i18n-tasks health
```

`i18n-tasks missing` only catches keys reachable through its static scan of `t("literal.key")` calls — a dynamically built key (`t("cards.status.#{card.status}")`) needs a `search.strict: false` opt-in or an explicit `ignore_missing` entry, or every dynamic-key locale will look falsely clean.

---

## 8. Testing Translation Coverage

Rather than eyeballing rendered pages, raise on any missing key during the test run so a removed/renamed translation fails the suite instead of shipping a visible `translation missing` string:

```ruby
# test/test_helper.rb (or spec/rails_helper.rb)
I18n.exception_handler = ->(exception, *) { raise exception }
```

For a single test asserting a specific translated string renders (not just "no exception"):

```ruby
test "empty board shows the localized empty state" do
  I18n.with_locale(:fr) do
    get board_path(boards(:empty))
    assert_select "p", text: I18n.t("boards.show.empty_state", locale: :fr)
  end
end
```

Combine with `i18n-tasks health` in CI (Pattern 7) rather than choosing one — the exception handler catches keys hit during the tests that actually run; `i18n-tasks` catches keys no test path exercises at all.

---

## Common Mistakes

| Mistake | Why it's bad | Fix |
|---------|--------------|-----|
| Hand-built plural strings (`"#{n} card#{'s' if n != 1}"`) | Wrong for locales with more than 2 plural forms; also wrong in English at zero | `t(key, count: n)` with `zero`/`one`/`other` |
| `I18n.locale = params[:locale]` directly in a `before_action` | Leaks across requests on threaded servers if an exception skips resetting it; also an open redirect-style vector if unvalidated | `I18n.with_locale(...) { }` (Pattern 5), validated against `available_locales` |
| Literal English strings in flash messages / raised errors | Invisible to `i18n-tasks`, silently never translated | Route every user-facing string through a locale file |
| No `config.i18n.fallbacks` | One missing key in a partially-translated locale renders the raw `translation missing: ...` key in production | Enable fallbacks (Pattern 6) |
| Currency/number formatting via hardcoded `sprintf`/`round` | Ignores locale-specific delimiters, currency symbol placement | `number_to_currency`, `number_with_delimiter`, locale `number.currency.format` |
| Dynamic keys (`t("status.#{status}")`) with no `i18n-tasks` allowance | `i18n-tasks missing` can't statically find them — locale gaps go undetected forever | `ignore_missing` entry or enumerate the literal keys somewhere `i18n-tasks` can scan |

---

## Quick Reference

| Need | Reach for |
|------|-----------|
| String near a view/controller/mailer | `t(".key")` — lazy lookup |
| Pluralized string | `t(key, count:)` with `zero`/`one`/`other` in the locale file |
| Model/attribute name | `Model.model_name.human`, `human_attribute_name` — reads `activerecord.*` |
| Validation message | `activerecord.errors.models.<model>.attributes.<attr>.<error>` |
| Date/time | `l(value, format: :name)` + `time.formats`/`date.formats` in the locale file |
| Money | `number_to_currency` + `number.currency.format` |
| Per-request locale | `I18n.with_locale` in an `around_action`, resolved from an explicit signal (Pattern 5) |
| Partially-translated locale | `config.i18n.fallbacks = true` (+ explicit chain for regional variants) |
| Find missing/unused keys | `i18n-tasks missing` / `unused` / `health`, gated in CI |
| Fail tests on a missing key | `I18n.exception_handler = ->(e, *) { raise e }` in the test helper |
