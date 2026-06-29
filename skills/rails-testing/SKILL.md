---
name: rails-testing
description: Use when writing tests with fixtures, system tests, VCR cassettes, and parallel execution, or when profiling/speeding up a slow test suite (Stackprof, Speedscope, TestProf)
---

# Rails Testing Patterns

## 1. Test Helper Setup

Configure the suite once in `test/test_helper.rb`: parallel workers, fixtures, helper modules, and `Current` setup/teardown.

```ruby
# test/test_helper.rb
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

require "rails/test_help"
require "webmock/minitest"
require "vcr"
require "mocha/minitest"
require "turbo/broadcastable/test_helper"

WebMock.allow_net_connect!

module ActiveSupport
  class TestCase
    parallelize workers: :number_of_processors, work_stealing: ENV["WORK_STEALING"] != "false"
    fixtures :all

    include ActiveJob::TestHelper
    include ActionTextTestHelper, CachingTestHelper, SessionTestHelper
    include Turbo::Broadcastable::TestHelper

    setup do
      Current.account = accounts("37s")
    end

    teardown do
      Current.clear_all   # prevent Current leaking between tests
    end
  end
end
```

---

## 2. Fixture Patterns with Deterministic UUIDs

Apps with UUID primary keys need deterministic fixture IDs for cross-references. Use `ActiveRecord::FixtureSet.identify` with `:uuid`, and reference other fixtures with the `_uuid` suffix.

```yaml
# test/fixtures/accounts.yml
37s:
  id: <%= ActiveRecord::FixtureSet.identify("37s", :uuid) %>
  name: 37signals
  external_account_id: <%= ActiveRecord::FixtureSet.identify("37signals") %>

# test/fixtures/users.yml
david:
  id: <%= ActiveRecord::FixtureSet.identify("david", :uuid) %>
  name: David
  identity: david        # non-UUID FK: plain fixture name
  account: 37s_uuid      # UUID FK: reference with _uuid suffix
  verified_at: <%= Time.current.to_fs(:db) %>
```

**Key Points:**
- Stock `identify(:uuid)` is deterministic but *unordered*. To make fixtures also sort before runtime-created records (so `.first`/`.last` behave predictably), prepend a module into `ActiveRecord::FixtureSet` (via `ActiveSupport.on_load(:active_record_fixture_set)`) that overrides `identify` to emit UUIDv7s with past timestamps derived from the label: `Zlib.crc32("fixtures/#{label}")` milliseconds after a fixed `Time.utc(2024, 1, 1)` base. The same override can treat a `_uuid` label suffix as an implicit `:uuid` column type.
- **A fixture with an explicit `id:` breaks association-by-label references to it.** If `users.yml` `admin` sets `id: 1`, then `creator: admin` elsewhere writes the FK as `FixtureSet.identify(:admin)` — a *hashed* id that does **not** equal the explicit `1` — so `record.creator` loads `nil` even though `creator_id` is set. Reference the explicit id directly (`creator_id: 1`), not the label.

---

## 3. System Tests with Capybara and Selenium

Use `ApplicationSystemTestCase` with Chrome/Selenium, headless by default, visible via env var.

```ruby
# test/application_system_test_case.rb
require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  browser_options = Selenium::WebDriver::Chrome::Options.new.tap do |opts|
    opts.add_argument("--window-size=1200,800")
    opts.add_argument("--disable-extensions")
    opts.add_argument("--deny-permission-prompts")
    opts.add_argument("--enable-automation")
  end

  Capybara.register_driver :chrome_headless do |app|
    browser_options.add_argument("--headless")
    Capybara::Selenium::Driver.new(app, browser: :chrome, options: browser_options)
  end

  Capybara.register_driver :chrome do |app|
    Capybara::Selenium::Driver.new(app, browser: :chrome, options: browser_options)
  end

  # SYSTEM_TESTS_BROWSER=true to watch the browser
  if ENV["SYSTEM_TESTS_BROWSER"]
    driven_by :chrome, screen_size: [ 1200, 1000 ]
  else
    driven_by :chrome_headless, screen_size: [ 1200, 1000 ]
  end
end
```

```ruby
# test/system/smoke_test.rb
class SmokeTest < ApplicationSystemTestCase
  test "create a card" do
    sign_in_as(users(:david))

    visit board_url(boards(:writebook))
    click_on "Add a card"
    fill_in "card_title", with: "Hello, world!"
    fill_in_lexxy with: "I am editing this thing"
    click_on "Create card"

    assert_selector "h3", text: "Hello, world!"
  end

  private
    def sign_in_as(user)
      visit session_transfer_url(user.identity.transfer_id, script_name: nil)
      assert_selector "h1", text: "Latest Activity"
    end

    # Rich-text editors that read their value live need execute_script, not fill_in
    def fill_in_lexxy(selector = "lexxy-editor", with:)
      editor_element = find(selector)
      editor_element.set with
      page.execute_script("arguments[0].value = '#{with}'", editor_element)
    end
end
```

---

## 4. VCR Cassettes for HTTP Stubbing

Record external API calls (e.g. OpenAI) once, replay them in future runs.

```ruby
# test/test_helper.rb
VCR.configure do |config|
  config.allow_http_connections_when_no_cassette = true
  config.cassette_library_dir = "test/vcr_cassettes"
  config.hook_into :webmock

  # Redact API keys from recordings
  config.filter_sensitive_data("<OPEN_AI_KEY>") {
    Rails.application.credentials.openai_api_key || ENV["OPEN_AI_API_KEY"]
  }

  # Ignore timestamps in request bodies for matching
  config.before_record do |i|
    if i.request&.body
      i.request.body.gsub!(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/, "<TIME>")
    end
  end

  config.register_request_matcher :body_without_times do |r1, r2|
    b1 = (r1.body || "").gsub(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/, "<TIME>")
    b2 = (r2.body || "").gsub(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/, "<TIME>")
    b1 == b2
  end

  config.default_cassette_options = {
    match_requests_on: [ :method, :uri, :body_without_times ]
  }
end
```

```ruby
# test/test_helpers/vcr_test_helper.rb
module VcrTestHelper
  extend ActiveSupport::Concern

  included do
    class_attribute :vcr_record

    setup do
      @casette_name = "#{self.class.name.tableize.singularize}-#{name}"
      VCR.insert_cassette @casette_name,
        record: recording? ? :all : :none,
        preserve_exact_body_bytes: true
    end

    teardown do
      VCR.eject_cassette
    end

    def recording?
      vcr_record || ENV["VCR_RECORD"]
    end
  end

  class_methods do
    def vcr_record!
      raise "#vcr_record! is meant for dev time. You are not supposed to run it in CI." if ENV["CI"]
      self.vcr_record = true
    end
  end
end
```

Include `VcrTestHelper` in tests that hit HTTP; record new cassettes with `VCR_RECORD=true` (or a temporary `vcr_record!` in the class).

---

## 5. Parallel Test Execution

Unit/integration tests parallelize across CPUs (Pattern 1); system tests must run with `PARALLEL_WORKERS=1` — they can't run reliably in parallel. Also use `PARALLEL_WORKERS=1` when debugging flaky tests.

**Sharding across multiple CI jobs:** when a suite outgrows one machine, split it with a queue, never a static file list. Hardcoded slices ("job 3 runs `test/system/a*`–`test/system/m*`") always drift unbalanced, and the build is only as fast as its unluckiest job. With a queue, every worker pulls the next test file as it finishes, so all shards end at roughly the same time (the same work-stealing principle `parallelize` already applies in-process). Tools: `test-queue`, `parallel_tests` (runtime-based balancing), `spec-wrk` (networked queue across GitHub Actions jobs), or paid services like Knapsack Pro.

---

## 6. Current Context in Tests

`Current.account` is set globally in setup (Pattern 1); set `Current.session = sessions(:david)` when a test needs a logged-in user, and always `Current.clear_all` in teardown.

```ruby
# test/test_helpers/session_test_helper.rb — temporary user context
module SessionTestHelper
  def with_current_user(user)
    user = users(user) unless user.is_a? User
    @old_session = Current.session
    begin
      Current.session = Session.new(identity: user.identity)
      yield
    ensure
      Current.session = @old_session
    end
  end
end
```

```ruby
# URL-tenanted apps: set the account prefix for generated URLs
class ActionDispatch::IntegrationTest
  setup do
    integration_session.default_url_options[:script_name] = "/#{ActiveRecord::FixtureSet.identify("37signals")}"
  end
end
```

---

## 7. Integration Test Authentication

A `sign_in_as` helper drives the real (magic link) authentication flow; tests then exercise protected endpoints normally.

```ruby
# test/test_helpers/session_test_helper.rb
module SessionTestHelper
  def sign_in_as(identity)
    cookies.delete :session_token

    if identity.is_a?(User)
      user = identity
      identity = user.identity
      raise "User #{user.name} doesn't have an associated identity" unless identity
    elsif !identity.is_a?(Identity)
      identity = identities(identity)
    end

    identity.send_magic_link
    magic_link = identity.magic_links.order(id: :desc).first

    untenanted do
      post session_path, params: { email_address: identity.email_address }
      post session_magic_link_url, params: { code: magic_link.code }
    end

    assert_response :redirect, "Magic Link code should grant access"
    assert_not_nil cookies.get_cookie("session_token"), "Expected session_token cookie"
  end

  def logout_and_sign_in_as(identity)
    Session.delete_all
    sign_in_as identity
  end

  # Temporarily drop the account URL prefix
  def untenanted(&block)
    original_script_name = integration_session.default_url_options[:script_name]
    integration_session.default_url_options[:script_name] = ""
    yield
  ensure
    integration_session.default_url_options[:script_name] = original_script_name
  end
end
```

---

## 8. Test Assertions and Helpers

Put domain-specific assertion helpers in `test/test_helpers/` and include them in `test_helper.rb`. Use `assert_difference` with lambdas (and hashes for multiple counts), `assert_turbo_stream` for Turbo responses.

```ruby
test "assignment toggling" do
  assert_difference({
    -> { cards(:logo).assignees.count } => -1,
    -> { Event.count } => +1
  }) do
    cards(:logo).toggle_assignment users(:kevin)
  end
end
```

---

## 9. i18n-Customised Errors & Editors You Can't `fill_in`

Two recurring test traps — asserting on Rails' default validation strings when the app has customised them, and trying to drive a rich-text/contenteditable field with `fill_in`.

```ruby
# Validation messages are often i18n-customised (e.g. presence reads
# "must not be blank." not Rails' default "can't be blank"). Don't hard-code
# the default literal — assert presence, or match the configured message.
test "title is required" do
  opportunity = Opportunity.new(title: nil)
  assert_not opportunity.valid?
  assert opportunity.errors[:title].present?              # robust
end

# A markdown/contenteditable editor syncs its hidden textarea ON SUBMIT,
# overwriting anything Capybara/Playwright `fill_in`/`fill` injected — so a
# browser submit re-renders with a blank-field error. Cover via a request test:
class OpportunitiesControllerTest < ActionDispatch::IntegrationTest
  test "create with a description" do
    assert_difference -> { Opportunity.count }, +1 do
      post opportunities_path, params: {
        opportunity: { title: "Stage Manager", description: "# Role\nDetails here" }
      }
    end
    assert_equal "# Role\nDetails here", Opportunity.last.description
  end
end
```

**Key Points:**
- Editors that sync on submit can't be driven by `fill_in`; the injected value is overwritten. Use request-level tests for the persistence path. This complements the `fill_in_lexxy` `execute_script` workaround (Pattern 3), which handles editors that read their value live.
- Other Stimulus interactions on the same form (nested-form Add/Remove, toggles) still verify fine in system tests.
- If an app translates admin index/search-form headers via simple_form labels, a new column used as a header or search field needs a `simple_form.labels.defaults.<key>` entry, or the page raises "Translation missing".

---

## 10. Background Jobs in Tests: `:test` Adapter, Not `:inline`

`config.active_job.queue_adapter = :inline` in the test environment (or `Resque.inline = true`) executes every enqueued job synchronously, everywhere. Every test implicitly runs background work it never asked for: state changes appear "by magic", and the suite burns time on side-effects no assertion needs. Keep the `:test` adapter (the Rails default) and drain jobs *explicitly*, only in tests that need the job's effects.

```ruby
# ❌ Bad: config/environments/test.rb
config.active_job.queue_adapter = :inline   # every test runs every job

# ✅ Good: keep the :test adapter, drain explicitly
class ExportTest < ActiveSupport::TestCase
  test "completed export attaches a file" do
    export = accounts("37s").exports.create!

    perform_enqueued_jobs do        # Act: run the job this test is about
      export.build_later
    end

    assert export.reload.file.attached?
  end

  test "creating an export enqueues the build" do
    assert_enqueued_with job: ExportAccountDataJob do
      accounts("37s").exports.create!.build_later
    end
  end
end
```

**Key Points:**
- Most tests should only assert the job was *enqueued* — that's the unit boundary; the job's behaviour gets its own test.
- `perform_enqueued_jobs(only: SomeJob)` scopes draining when setup enqueues unrelated jobs.
- Inheriting a suite built on `:inline`? Migrate gradually: switch the adapter, then fix tests that relied on implicit execution by adding explicit drains.

---

## 11. Mocking — Verify the Tools Exist Before Stubbing

Writing `.stubs`/`.stub` and getting `NoMethodError: undefined method 'stubs'` means the suite has no mocking library. **minitest 6 dropped the bundled `minitest/mock`**, and many suites never added mocha, so neither `Object#stub` nor `.stubs` can be assumed (the Pattern 1 example requires `mocha/minitest` — verify it's actually there). Prefer stubbing external services by toggling their configuration over introducing a mocking library:

```ruby
# Force a reCAPTCHA failure without any mocking library: drop "test" from the
# skip list and send no token — verification really runs and really fails.
test "rejects submission when reCAPTCHA fails" do
  Recaptcha.configuration.skip_verify_env.delete("test")

  post opportunities_path, params: { opportunity: { title: "Stage Manager" } }

  assert_response :unprocessable_entity
ensure
  Recaptcha.configuration.skip_verify_env << "test"
end
```

Config toggles exercise the real code path; mocks only assert you called what you stubbed. For HTTP, use VCR/WebMock (Pattern 4) rather than stubbing the client class.

---

## 12. Coverage — Check What You Changed Is Actually Tested

SimpleCov tells you which lines your tests touched. Wire it to emit JSON so a coverage check is scriptable, not just a browseable HTML report. Add `simplecov_json_formatter` to the test group and register both formatters:

```ruby
# test/test_helper.rb (top, before any app code is required)
require "simplecov"
SimpleCov.start "rails" do
  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::JSONFormatter
  ])
end
```

Run with coverage on, then read the JSON to judge the diff — not the whole app:

```bash
COVERAGE=1 bin/rails test
```

`coverage/coverage.json` is keyed by absolute file path; each entry's `lines` array holds one value per source line — `null` (not executable: blanks, comments, `end`), `0` (executable but **never hit**), or `1+` (hit count). For each file you changed: coverage % = (lines `>= 1`) / (non-`null` lines).

**Thresholds — judge the changed files, not the global number:**
- **≥ 90%** — good, move on.
- **70–89%** — review the uncovered lines; cover the meaningful ones.
- **< 70%** — insufficient; add tests until the changed file is well covered.

Prioritise uncovered **public methods**, **conditional branches** (only one side of an `if`/`case` exercised), **guard clauses / early returns**, and **`rescue` paths**. A high global percentage hides an untested method you just wrote — always filter to the files in your diff. See [[rails-audit]] for using SimpleCov to quantify suite-wide coverage on an inherited app.

---

## 13. Testing Principles

Defaults that keep a fixtures-based suite fast to read and quick to diagnose:

- **One behaviour per test; ≤ 4 assertions.** If a test needs more, it's testing more than one thing — split it so a failure name points at exactly what broke.
- **Descriptive names.** `test "returns the host from a standard URL"`, not `test "host works"`. The name is the failure message.
- **Test behaviour, not implementation.** Assert on outcomes (return values, persisted state, enqueued jobs), not on which private methods were called — unless the side effect *is* the contract (Pattern 10's `assert_enqueued_with`).
- **Never `skip` or comment out a test.** A skipped test is a blind spot that reads as green. Fix the code or the test.
- **Read 2–3 neighbouring tests first.** Match the conventions already in `test/models/`, `test/controllers/`, etc. before adding a new file.
- **Build, don't persist, when persistence isn't needed.** Use `Model.new`/`build` for pure logic and validation tests; only hit the database (fixtures or `create!`) when the behaviour needs a saved record. See [[rails-core]] Rule 1 — extend fixtures, never mutate existing ones.

---

## 14. Profiling & Speeding Up a Slow Suite

A slow suite is a measurement problem before it's an optimisation problem. Profile first; optimise the few things that dominate; stop when the return drops.

**Find the bottleneck (framework-agnostic).** [Stackprof](https://github.com/tmm1/stackprof) samples the call stack while the suite runs; [Speedscope](https://www.speedscope.app/) turns the dump into a flamegraph. This works on a fixtures-based Minitest suite, not just RSpec.

```ruby
# Minitest: wrap a representative run (one slow file, or the whole suite)
StackProf.run(mode: :wall, out: "tmp/stackprof.dump", raw: true) do
  # the test run — e.g. require + run the files, or profile inside a setup hook
end
```

```bash
# RSpec with test-prof's Stackprof integration:
TEST_STACK_PROF=1 SAMPLE=1000 bin/rspec
# then open tmp/stackprof-*.json (or the .dump) at https://www.speedscope.app/
```

Open the dump in Speedscope and use the **Sandwich** view — it ranks frames by total time, so the suite's real cost (a factory cascade, an over-eager callback, an unmemoised lookup) surfaces at the top.

**Mindset:**
- **Baseline first.** Capture the suite's time before and after every change — optimisation you didn't measure is a guess.
- **Optimise the highest-impact shared thing.** The fixture, factory, or `setup` block touched by the *most* tests gives the most return. A 50ms win on the `users` fixture beats a 2s win on one rarely-run file.
- **Stop when the return drops.** As the article puts it: if it's taking four hours to shave one second off the suite, reconsider your priorities.

**Disable expensive callbacks in tests by default (opt in per-test).** The single most reusable idea here: expensive Active Record callbacks — history/audit tracking, denormalised counters, external pushes — fire on almost every saved record but are asserted on by ~1% of tests. Give the behaviour a `Testing` module with explicit toggles, switch it **off** globally in `test_helper.rb`, and turn it **on** only in the handful of tests that test the callback itself.

```ruby
# app/models/concerns/history/testing.rb
module History::Testing
  def fake!  = Thread.current[:history_real] = false   # default in tests
  def real!  = Thread.current[:history_real] = true
  def faking? = !Thread.current[:history_real]
end

# the callback no-ops while faking
after_save :record_history, unless: -> { History.faking? }
```

```ruby
# test/test_helper.rb — off by default
setup { History.fake! }
teardown { History.real! }

# only where the side effect IS the contract:
test "saving a card records history" do
  History.real!
  cards(:logo).update!(title: "Renamed")
  assert_equal 1, cards(:logo).history_entries.count
end
```

This is the same instinct as Pattern 10 (drain jobs explicitly, never the `:inline` adapter) and Pattern 11 (config toggles over mocks): the default test path does the *least* work that still proves the unit, and you opt into the expensive path only where it's under test. See [[rails-models]] for the callback patterns themselves.

**Inherited a factory-based RSpec suite?** Our suites are fixtures-first, and **fixtures already load once and are shared across the whole suite** — which is exactly what FactoryBot helpers like `let_it_be`, `before_all`, and `create_default` reinvent. Don't add them to a fixtures suite (and don't reach for a database-cleaner gem — fixtures wrap each test in a transaction already). *But* when you inherit a factory-based suite you can't convert, [TestProf](https://test-prof.evilmartians.io/) is the toolbox: `RSpecDissect` shows time spent in `let`/`before`, `FactoryProf` (`FPROF=flamegraph bin/rspec`) finds factory cascades, and `let_it_be`/`AnyFixture` share data across a file. Migrate the slowest files first, measuring each one.

*Source: [Evil Martians — "Railing against time"](https://evilmartians.com/chronicles/railing-against-time-tools-and-techniques-that-got-us-5x-faster-results).*

---

## 15. Test-Gap Pre-flight — New Code Ships With Tests

Before writing or finishing a change, scope what moved and confirm each piece has a test:

```bash
git diff main...HEAD --name-only
```

Map each changed `app/**/*.rb` to its `test/**/*_test.rb` counterpart:

| Changed file | Expected test |
|---|---|
| `app/models/post.rb` | `test/models/post_test.rb` |
| `app/controllers/posts_controller.rb` | `test/controllers/posts_controller_test.rb` |
| `app/jobs/analyze_post_job.rb` | `test/jobs/analyze_post_job_test.rb` |
| `app/components/card_component.rb` | `test/components/card_component_test.rb` |

If a changed file has **no** corresponding test, write one — new code ships with tests, no exceptions. This pairs with [[rails-core]] Rule 8: after any fixture or factory change, run the **full** suite (`PARALLEL_WORKERS=1` for readable output), since fixtures cascade across the whole suite.

---

## Quick Reference

| Command | Description |
|---------|-------------|
| `bin/rails test` | Run all unit/integration tests |
| `bin/rails test test/file.rb:42` | Run test at specific line |
| `bin/rails test:system` | Run system tests |
| `bin/ci` | Run full CI pipeline |
| `PARALLEL_WORKERS=1 bin/rails test` | Disable parallel execution (debugging, system tests) |
| `SYSTEM_TESTS_BROWSER=true bin/rails test:system` | See browser during tests |
| `VCR_RECORD=true bin/rails test` | Record new VCR cassettes |
| `COVERAGE=1 bin/rails test` | Run with SimpleCov; read `coverage/coverage.json` for the diff |
| `git diff main...HEAD --name-only` | Scope changed files → map each to its `*_test.rb` |
| `StackProf.run(mode: :wall, out: …) { … }` | Profile a slow suite; open the dump in Speedscope (Sandwich view) |
| `TEST_STACK_PROF=1 SAMPLE=1000 bin/rspec` | Stackprof-profile an inherited RSpec suite (test-prof) |
| `FPROF=flamegraph bin/rspec` | Find factory cascades in an inherited factory-based suite (TestProf) |

| Pattern | When to Use |
|---------|-------------|
| `ActiveRecord::FixtureSet.identify("name", :uuid)` | Deterministic UUID fixture id |
| `account: 37s_uuid` | Reference a UUID fixture |
| `creator_id: 1` (not `creator: admin`) | Reference a fixture that sets an explicit `id:` |
| `sign_in_as :user` | Authenticate in integration tests |
| `Current.session = sessions(:david)` | Set user session context |
| `include VcrTestHelper` | Record external HTTP calls |
| `assert errors[:field].present?` | Assert validation failure without the literal i18n message |
| `post create_path, params: {...}` | Test forms whose editor can't be `fill_in`-ed |
| `perform_enqueued_jobs { ... }` | Explicitly run jobs (never `:inline` adapter) |
| `assert_enqueued_with job: SomeJob` | Assert enqueueing without running the job |
| Config toggle (not `.stubs`) | Stub external services when the suite has no mocking library |
