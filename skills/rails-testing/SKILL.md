---
name: rails-testing
description: Use when writing tests with fixtures, system tests, VCR cassettes, and parallel execution
---

# Rails Testing Patterns

## When to Use
- Writing unit tests for models
- Creating integration tests for controllers
- Setting up system tests with Capybara
- Working with test fixtures
- Recording external API calls with VCR
- Managing test context (Current.account, Current.user)

---

## 1. Test Helper Setup

**Problem:** Tests need consistent configuration, fixtures, and helper modules loaded before running.

**Solution:** Configure the test suite in `test/test_helper.rb` with parallel workers, fixtures, and common setup/teardown hooks.

**Example:**

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

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include ActiveJob::TestHelper
    include ActionTextTestHelper, CachingTestHelper, CardTestHelper, ChangeTestHelper, SessionTestHelper
    include Turbo::Broadcastable::TestHelper

    setup do
      Current.account = accounts("37s")
    end

    teardown do
      Current.clear_all
    end
  end
end
```

**Source:** `test/test_helper.rb`

**Key Points:**
- `parallelize` enables parallel test execution for speed
- `fixtures :all` loads all fixture files automatically
- The `setup` block sets `Current.account` for every test
- The `teardown` block clears `Current` to prevent leakage between tests
- Include helper modules for common test utilities

---

## 2. Fixture Patterns with Deterministic UUIDs

**Problem:** Fizzy uses UUID primary keys, but fixtures need deterministic IDs for cross-references and test ordering.

**Solution:** Use `ActiveRecord::FixtureSet.identify` with `:uuid` type to generate deterministic UUIDs. Reference other fixtures using the `_uuid` suffix.

**Example:**

```yaml
# test/fixtures/accounts.yml
37s:
  id: <%= ActiveRecord::FixtureSet.identify("37s", :uuid) %>
  name: 37signals
  external_account_id: <%= ActiveRecord::FixtureSet.identify("37signals") %>
  cards_count: 5

initech:
  id: <%= ActiveRecord::FixtureSet.identify("initech", :uuid) %>
  name: Initech LLC
  external_account_id: <%= ActiveRecord::FixtureSet.identify("initech") %>
  cards_count: 0
```

```yaml
# test/fixtures/users.yml
david:
  id: <%= ActiveRecord::FixtureSet.identify("david", :uuid) %>
  name: David
  role: member
  identity: david
  account: 37s_uuid  # Reference with _uuid suffix
  verified_at: <%= Time.current.to_fs(:db) %>

kevin:
  id: <%= ActiveRecord::FixtureSet.identify("kevin", :uuid) %>
  name: Kevin
  role: admin
  identity: kevin
  account: 37s_uuid
  verified_at: <%= Time.current.to_fs(:db) %>
```

```yaml
# test/fixtures/cards.yml
logo:
  id: <%= ActiveRecord::FixtureSet.identify("logo", :uuid) %>
  number: 1
  board: writebook_uuid
  creator: david_uuid
  column: writebook_triage_uuid
  title: The logo isn't big enough
  due_on: <%= 3.days.from_now %>
  created_at: <%= 1.week.ago %>
  status: published
  last_active_at: <%= 1.week.ago %>
  account: 37s_uuid
```

**Source:** `test/fixtures/accounts.yml`, `test/fixtures/users.yml`, `test/fixtures/cards.yml`

**Key Points:**
- Always use `<%= ActiveRecord::FixtureSet.identify("name", :uuid) %>` for UUID ID columns
- Reference other fixtures with the `_uuid` suffix: `account: 37s_uuid`, `board: writebook_uuid`
- For non-UUID foreign keys, use plain fixture names: `identity: david`
- UUIDs are generated deterministically so `.first`/`.last` work correctly in tests
- Fixture UUIDs sort "before" runtime-created records, so new records are always "newer"

---

## 3. Fixture UUID Generation (How It Works)

**Problem:** Fixtures need UUIDs that are both deterministic (for cross-references) and sorted correctly (for `.first`/`.last` queries).

**Solution:** Custom UUID generation using UUIDv7 with deterministic timestamps derived from fixture labels.

**Example:**

```ruby
# test/test_helper.rb
module FixturesTestHelper
  extend ActiveSupport::Concern

  class_methods do
    def identify(label, column_type = :integer)
      if label.to_s.end_with?("_uuid")
        column_type = :uuid
        label = label.to_s.delete_suffix("_uuid")
      end

      return super(label, column_type) unless column_type.in?([ :uuid, :string ])
      generate_fixture_uuid(label)
    end

    private

    def generate_fixture_uuid(label)
      # Generate deterministic UUIDv7 for fixtures that sorts by fixture ID
      # Use CRC32 for deterministic ordering
      fixture_int = Zlib.crc32("fixtures/#{label}") % (2**30 - 1)

      # Translate to times in the past so runtime records are always newer
      base_time = Time.utc(2024, 1, 1, 0, 0, 0)
      timestamp = base_time + (fixture_int / 1000.0)

      uuid_v7_with_timestamp(timestamp, label)
    end
  end
end

ActiveSupport.on_load(:active_record_fixture_set) do
  prepend(FixturesTestHelper)
end
```

**Source:** `test/test_helper.rb`

**Key Points:**
- The `_uuid` suffix triggers UUID generation automatically
- Fixtures use timestamps in the past (2024) so runtime records sort after them
- CRC32 ensures deterministic but well-distributed ordering
- This allows `Model.first` and `Model.last` to work predictably in tests

---

## 4. System Tests with Capybara and Selenium

**Problem:** UI interactions need automated browser testing with proper driver configuration.

**Solution:** Use `ApplicationSystemTestCase` with Chrome/Selenium, supporting both headless and visible browser modes.

**Example:**

```ruby
# test/application_system_test_case.rb
require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  browser_options = Selenium::WebDriver::Chrome::Options.new.tap do |opts|
    opts.add_argument("--window-size=1200,800")
    opts.add_argument("--disable-extensions")
    opts.add_argument("--disable-renderer-backgrounding")
    opts.add_argument("--disable-backgrounding-occluded-windows")
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

  # Use SYSTEM_TESTS_BROWSER=true to see the browser
  if ENV["SYSTEM_TESTS_BROWSER"]
    driven_by :chrome, screen_size: [ 1200, 1000 ]
  else
    driven_by :chrome_headless, screen_size: [ 1200, 1000 ]
  end
end
```

```ruby
# test/system/smoke_test.rb
require "application_system_test_case"

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

  test "dragging card to a new column" do
    sign_in_as(users(:david))

    card = Card.find("03axhd1h3qgnsffqplkyf28fv")
    assert_nil(card.column)

    visit board_url(boards(:writebook))

    card_el = page.find("#article_card_03axhd1h3qgnsffqplkyf28fv")
    column_el = page.find("#column_03axmcferfmbnv4qg816nw6bg")
    cards_count = column_el.find(".cards__expander-count").text.to_i

    card_el.drag_to(column_el)

    column_el.find(".cards__expander-count", text: cards_count + 1)
    assert_equal("Triage", card.reload.column.name)
  end

  private
    def sign_in_as(user)
      visit session_transfer_url(user.identity.transfer_id, script_name: nil)
      assert_selector "h1", text: "Latest Activity"
    end

    def fill_in_lexxy(selector = "lexxy-editor", with:)
      editor_element = find(selector)
      editor_element.set with
      page.execute_script("arguments[0].value = '#{with}'", editor_element)
    end
end
```

**Source:** `test/application_system_test_case.rb`, `test/system/smoke_test.rb`

**Key Points:**
- Set `SYSTEM_TESTS_BROWSER=true` to see the browser during tests
- Use `sign_in_as` helper for authentication in system tests
- Use `drag_to` for drag-and-drop testing
- Use `assert_selector` for DOM assertions
- Custom helpers like `fill_in_lexxy` handle complex UI components

---

## 5. VCR Cassettes for HTTP Stubbing

**Problem:** Tests that make external API calls (e.g., OpenAI) are slow and flaky.

**Solution:** Use VCR to record HTTP interactions and replay them in future test runs.

**Example:**

```ruby
# test/test_helper.rb
VCR.configure do |config|
  config.allow_http_connections_when_no_cassette = true
  config.cassette_library_dir = "test/vcr_cassettes"
  config.hook_into :webmock

  # Filter sensitive data from recordings
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
    # Use to force record mode at development time
    def vcr_record!
      raise "#vcr_record! is meant for dev time. You are not supposed to run it in CI." if ENV["CI"]
      self.vcr_record = true
    end
  end

  def without_vcr_body_matching(&block)
    VCR.use_cassette("#{@casette_name}_without_body", match_requests_on: [ :method, :uri ], &block)
  end
end
```

**Usage in tests:**

```ruby
class SomeExternalApiTest < ActiveSupport::TestCase
  include VcrTestHelper

  # Uncomment during development to record new cassettes:
  # vcr_record!

  test "makes API call" do
    # First run with VCR_RECORD=true records the cassette
    # Subsequent runs replay from the cassette
    result = ExternalService.call
    assert result.success?
  end
end
```

**Source:** `test/test_helper.rb`, `test/test_helpers/vcr_test_helper.rb`

**Key Points:**
- Set `VCR_RECORD=true` environment variable to record new cassettes
- Use `filter_sensitive_data` to redact API keys from cassettes
- Custom request matchers ignore dynamic data like timestamps
- Cassettes are stored in `test/vcr_cassettes/`
- Include `VcrTestHelper` in tests that need HTTP recording

---

## 6. Parallel Test Execution

**Problem:** Large test suites are slow when run serially. System tests can conflict when run in parallel.

**Solution:** Enable parallel workers for unit/integration tests but disable for system tests.

**Example:**

```ruby
# test/test_helper.rb
module ActiveSupport
  class TestCase
    parallelize workers: :number_of_processors, work_stealing: ENV["WORK_STEALING"] != "false"
  end
end
```

```ruby
# config/ci.rb
SYSTEM_TEST_ENV = "PARALLEL_WORKERS=1" # system tests can't run reliably in parallel

CI.run do
  step "Tests: OSS",           "#{OSS_ENV} bin/rails test"
  step "Tests: OSS System",    "#{OSS_ENV} #{SYSTEM_TEST_ENV} bin/rails test:system"
end
```

**Running tests with parallel control:**

```bash
# Run tests with default parallel workers
bin/rails test

# Disable parallelization for debugging
PARALLEL_WORKERS=1 bin/rails test

# Run system tests (always single worker)
PARALLEL_WORKERS=1 bin/rails test:system
```

**Source:** `test/test_helper.rb`, `config/ci.rb`, `AGENTS.md`

**Key Points:**
- Unit tests run in parallel by default using all CPUs
- System tests must run with `PARALLEL_WORKERS=1` to avoid conflicts
- Use `PARALLEL_WORKERS=1` when debugging flaky tests
- Work stealing (`work_stealing: true`) improves load balancing

---

## 7. Current Context in Tests

**Problem:** Tests need to set up `Current.account`, `Current.user`, and `Current.session` for proper context.

**Solution:** Use `setup` blocks to set context and `teardown` to clear it. Use helper methods for temporary context changes.

**Example:**

```ruby
# test/test_helper.rb - Global setup for all tests
module ActiveSupport
  class TestCase
    setup do
      Current.account = accounts("37s")
    end

    teardown do
      Current.clear_all
    end
  end
end
```

```ruby
# test/test_helpers/session_test_helper.rb
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
# test/models/card_test.rb - Setting session for a specific test
class CardTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:david)
  end

  test "create assigns a number to the card" do
    user = users(:david)
    board = boards(:writebook)
    # Current.account and Current.session are now set
    card = Card.create!(title: "Test", board: board, creator: user)
    assert_equal account.reload.cards_count, card.number
  end
end
```

```ruby
# Integration test with account slug setup
class ActionDispatch::IntegrationTest
  setup do
    integration_session.default_url_options[:script_name] = "/#{ActiveRecord::FixtureSet.identify("37signals")}"
  end
end

class ActionDispatch::SystemTestCase
  setup do
    self.default_url_options[:script_name] = "/#{ActiveRecord::FixtureSet.identify("37signals")}"
  end
end
```

**Source:** `test/test_helper.rb`, `test/test_helpers/session_test_helper.rb`, `test/models/card_test.rb`

**Key Points:**
- `Current.account` is set globally in test setup to the "37s" account
- Use `Current.session = sessions(:name)` when tests need a logged-in user
- Integration tests set `script_name` to simulate the account URL prefix
- Always call `Current.clear_all` in teardown to prevent test pollution
- Use `with_current_user` helper for temporary user context changes

---

## 8. Running Tests

**Problem:** Need to know the correct commands for running different types of tests.

**Solution:** Use the standard Rails test commands with optional configuration.

**Example:**

```bash
# Run all unit tests (fast)
bin/rails test

# Run a single test file
bin/rails test test/models/card_test.rb

# Run a specific test by line number
bin/rails test test/models/card_test.rb:25

# Run system tests (uses browser)
bin/rails test:system

# Run full CI suite (style, security, tests)
bin/ci

# Disable parallel for debugging flaky tests
PARALLEL_WORKERS=1 bin/rails test

# See browser during system tests
SYSTEM_TESTS_BROWSER=true bin/rails test:system
```

**Source:** `AGENTS.md`

**Key Points:**
- `bin/rails test` runs unit and integration tests
- `bin/rails test:system` runs Capybara system tests
- `bin/ci` runs the full CI pipeline (linting, security, tests)
- Use line numbers to run specific tests: `test/file.rb:42`
- Set `PARALLEL_WORKERS=1` to debug test isolation issues

---

## 9. Integration Test Authentication

**Problem:** Integration tests need to authenticate users to test protected endpoints.

**Solution:** Use the `sign_in_as` helper which handles magic link authentication.

**Example:**

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
    cookie = cookies.get_cookie "session_token"
    assert_not_nil cookie, "Expected session_token cookie"
  end

  def logout_and_sign_in_as(identity)
    Session.delete_all
    sign_in_as identity
  end

  def sign_out
    untenanted do
      delete session_path
    end
    assert_not cookies[:session_token].present?
  end

  def untenanted(&block)
    original_script_name = integration_session.default_url_options[:script_name]
    integration_session.default_url_options[:script_name] = ""
    yield
  ensure
    integration_session.default_url_options[:script_name] = original_script_name
  end
end
```

```ruby
# test/controllers/cards_controller_test.rb
class CardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "index" do
    get cards_path
    assert_response :success
  end

  test "admins can delete any card" do
    assert_difference -> { Card.count }, -1 do
      delete card_path(cards(:logo))
    end
    assert_redirected_to boards(:writebook)
  end

  test "non-admins cannot delete cards they did not create" do
    logout_and_sign_in_as :jz

    assert_no_difference -> { Card.count } do
      delete card_path(cards(:logo))
    end
    assert_response :forbidden
  end
end
```

**Source:** `test/test_helpers/session_test_helper.rb`, `test/controllers/cards_controller_test.rb`

**Key Points:**
- `sign_in_as :name` accepts fixture symbols, User objects, or Identity objects
- Use `logout_and_sign_in_as` to switch users mid-test
- The `untenanted` helper temporarily removes the account URL prefix
- Authentication uses the passwordless magic link flow

---

## 10. Test Assertions and Helpers

**Problem:** Common test patterns need reusable assertion helpers.

**Solution:** Create test helpers for domain-specific assertions.

**Example:**

```ruby
# test/test_helpers/card_test_helper.rb
module CardTestHelper
  def assert_card_container_rerendered(card)
    assert_turbo_stream action: :replace, target: dom_id(card, :card_container)
  end
end
```

```ruby
# test/test_helpers/change_test_helper.rb
module ChangeTestHelper
  def capture_change(target)
    before = target.call
    yield
    after = target.call
    after - before
  end
end
```

```ruby
# Usage in tests
class CardTest < ActiveSupport::TestCase
  test "assignment toggling" do
    assert cards(:logo).assigned_to?(users(:kevin))

    # Using Rails' built-in assert_difference with multiple counts
    assert_difference({
      -> { cards(:logo).assignees.count } => -1,
      -> { Event.count } => +1
    }) do
      cards(:logo).toggle_assignment users(:kevin)
    end

    assert_not cards(:logo).reload.assigned_to?(users(:kevin))
  end

  test "tag toggling" do
    assert_difference "cards(:logo).taggings.count", -1 do
      cards(:logo).toggle_tag_with tags(:web).title
    end

    assert_difference %w[ cards(:logo).taggings.count Tag.count ], +1 do
      cards(:logo).toggle_tag_with "prioritized"
    end
  end
end
```

**Source:** `test/test_helpers/card_test_helper.rb`, `test/test_helpers/change_test_helper.rb`, `test/models/card_test.rb`

**Key Points:**
- Create domain-specific helpers in `test/test_helpers/`
- Include helpers in `test_helper.rb` to make them available globally
- Use `assert_difference` with lambdas for counting changes
- Use `assert_turbo_stream` for Turbo Stream response assertions

---

## 11. i18n-Customised Errors & Editors You Can't `fill_in`

**Problem:** Two recurring test traps — asserting on Rails' default validation strings when the
app has customised them, and trying to drive a rich-text/contenteditable field with `fill_in`.

**Solution:** Assert on `errors[:field].present?` (or the *configured* message), and cover
forms whose editor overwrites its value on submit with **request-level** tests instead of a
browser submit.

**Example:**

```ruby
# Validation messages are often i18n-customised (e.g. presence reads
# "must not be blank." not Rails' default "can't be blank"). Don't hard-code
# the default literal — assert presence, or match the configured message.
test "title is required" do
  opportunity = Opportunity.new(title: nil)
  assert_not opportunity.valid?
  assert opportunity.errors[:title].present?              # robust
  # assert_includes opportunity.errors[:title], "must not be blank."  # if asserting text
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
- Assert `errors[:field].present?` rather than Rails' default message string — apps override messages via i18n.
- Editors that sync a contenteditable into a hidden field **on submit** can't be driven by `fill_in` / Playwright `fill`; the injected value is overwritten. Use request-level (`post :create`) tests for the persistence path.
- This complements the browser-side `fill_in_lexxy` `execute_script` workaround (Section 4) — that handles editors that read their value live; request tests are the fallback when the value is overwritten only at submit time.
- Other Stimulus interactions on the same form (nested-form Add/Remove, toggles) still verify fine in system tests.
- If an app translates admin index/search-form headers via simple_form labels, a new column used as a header or search field needs a `simple_form.labels.defaults.<key>` entry, or the page raises "Translation missing".

---

## Quick Reference

| Command | Description |
|---------|-------------|
| `bin/rails test` | Run all unit/integration tests |
| `bin/rails test test/file.rb` | Run single test file |
| `bin/rails test test/file.rb:42` | Run test at specific line |
| `bin/rails test:system` | Run system tests |
| `bin/ci` | Run full CI pipeline |
| `PARALLEL_WORKERS=1 bin/rails test` | Disable parallel execution |
| `SYSTEM_TESTS_BROWSER=true bin/rails test:system` | See browser during tests |
| `VCR_RECORD=true bin/rails test` | Record new VCR cassettes |

| Pattern | When to Use |
|---------|-------------|
| `fixtures :all` | Load all fixtures automatically |
| `ActiveRecord::FixtureSet.identify("name", :uuid)` | Generate deterministic UUID |
| `account: 37s_uuid` | Reference fixture with UUID |
| `sign_in_as :user` | Authenticate in integration tests |
| `Current.account = accounts("37s")` | Set tenant context |
| `Current.session = sessions(:david)` | Set user session context |
| `include VcrTestHelper` | Record external HTTP calls |
| `assert_difference` | Verify count changes |
| `assert_turbo_stream` | Verify Turbo responses |
| `assert errors[:field].present?` | Assert validation failure without the literal i18n message |
| `post create_path, params: {...}` | Test forms whose editor can't be `fill_in`-ed |
