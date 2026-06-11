---
name: rails-style
description: Use when following Rails code style conventions for method ordering, conditionals, REST routing, and naming
---

# Rails Code Style

## When to Use
- Writing new code
- Refactoring existing code
- Following team conventions
- Reviewing code for style consistency

---

## 1. Method Ordering

**Problem:** Random method ordering makes code hard to navigate and understand.

**Solution:** Order methods in classes in this sequence:
1. Class methods
2. Public methods (with `initialize` at the top)
3. Private methods

**Example:**
```ruby
# Source: STYLE.md

class SomeClass
  # 1. Class methods first
  class << self
    def deliver_all
      # ...
    end

    def deliver_all_later
      DeliverAllJob.perform_later
    end
  end

  # 2. Public methods (initialize first if present)
  def initialize(user)
    @user = user
  end

  def deliver
    # ...
  end

  def notifications
    # ...
  end

  # 3. Private methods
  private
    def window
      # ...
    end

    def deliverable?
      # ...
    end
end
```

**Real Example:** See `/app/models/notification/bundle.rb` for this pattern in practice.

---

## 2. Invocation Order

**Problem:** Methods scattered randomly make it difficult to follow the code flow.

**Solution:** Order methods vertically based on their invocation order. Methods that call other methods should appear before the methods they call.

**Example:**
```ruby
# Source: STYLE.md

class SomeClass
  def some_method
    method_1
    method_2
  end

  private
    def method_1
      method_1_1
      method_1_2
    end

    def method_1_1
      # ...
    end

    def method_1_2
      # ...
    end

    def method_2
      method_2_1
      method_2_2
    end

    def method_2_1
      # ...
    end

    def method_2_2
      # ...
    end
end
```

---

## 3. Conditional Returns

**Problem:** Guard clauses can be hard to read, especially when nested.

**Solution:** Prefer expanded conditionals over guard clauses.

**Bad:**
```ruby
def todos_for_new_group
  ids = params.require(:todolist)[:todo_ids]
  return [] unless ids
  @bucket.recordings.todos.find(ids.split(","))
end
```

**Good:**
```ruby
def todos_for_new_group
  if ids = params.require(:todolist)[:todo_ids]
    @bucket.recordings.todos.find(ids.split(","))
  else
    []
  end
end
```

**Exception:** Guard clauses are acceptable when:
- The return is right at the beginning of the method
- The main method body is not trivial and involves several lines of code

```ruby
# Source: STYLE.md - Acceptable guard clause

def after_recorded_as_commit(recording)
  return if recording.parent.was_created?

  if recording.was_created?
    broadcast_new_column(recording)
  else
    broadcast_column_change(recording)
  end
end
```

---

## 4. Visibility Modifiers

**Problem:** Inconsistent formatting around `private` makes code harder to scan.

**Solution:**
- No newline under `private`
- Indent content under `private`
- For modules with only private methods: mark `private` at top, add extra newline after, but don't indent

**Classes:**
```ruby
# Source: STYLE.md

class SomeClass
  def some_method
    # ...
  end

  private
    def some_private_method_1
      # ...
    end

    def some_private_method_2
      # ...
    end
end
```

**Modules with only private methods:**
```ruby
# Source: STYLE.md

module SomeModule
  private

  def some_private_method
    # ...
  end
end
```

**Real Example:** See `/app/models/card.rb` and `/app/models/card/readable.rb` for this pattern.

---

## 5. CRUD Controllers

**Problem:** Custom actions like `post :close` break RESTful conventions and become hard to maintain.

**Solution:** Model web endpoints as CRUD operations on resources. When an action doesn't map cleanly to a standard CRUD verb, introduce a new resource.

**Bad:**
```ruby
resources :cards do
  post :close
  post :reopen
end
```

**Good:**
```ruby
# Source: config/routes.rb

resources :cards do
  resource :closure
end
```

**Real Example:** See `/app/controllers/cards/closures_controller.rb`:
```ruby
class Cards::ClosuresController < ApplicationController
  include CardScoped

  def create
    capture_card_location
    @card.close
    refresh_stream_if_needed
    # ...
  end

  def destroy
    @card.reopen
    refresh_stream_after_reopen
    # ...
  end
end
```

**More Examples from `/config/routes.rb`:**
- `resource :goldness` - Card gilding/ungilding
- `resource :closure` - Card closing/reopening
- `resource :not_now` - Card postponement
- `resource :pin` - Card pinning
- `resource :watch` - Card watching
- `resource :publication` - Board publishing

---

## 6. Controller-Model Interaction

**Problem:** Over-engineered service layers add complexity without value.

**Solution:** Favor vanilla Rails with thin controllers directly invoking a rich domain model. Don't use services or other artifacts to connect the two.

**Plain Active Record Operations:**
```ruby
# Source: STYLE.md

class Cards::CommentsController < ApplicationController
  def create
    @comment = @card.comments.create!(comment_params)
  end
end
```

**Intention-Revealing Model APIs:**
```ruby
# Source: /app/controllers/cards/goldnesses_controller.rb

class Cards::GoldnessesController < ApplicationController
  include CardScoped

  def create
    @card.gild
    # ...
  end

  def destroy
    @card.ungild
    # ...
  end
end
```

**When Justified - Services/Form Objects:**
```ruby
# Source: STYLE.md

Signup.new(email_address: email_address).create_identity
```

---

## 7. Bang Method Conventions

**Problem:** Using `!` inconsistently for "dangerous" operations creates confusion.

**Solution:** Only use `!` for methods that have a corresponding counterpart without `!`. Don't use `!` to flag destructive actions.

**Example:**
```ruby
# Good: save! has a counterpart save
record.save!

# Good: update! has a counterpart update
record.update!(params)

# Bad: No gild counterpart, so don't use gild!
@card.gild!  # Wrong

# Good: Just use gild
@card.gild   # Correct
```

---

## 8. Async Operations

**Problem:** Complex logic in job classes makes them hard to test and maintain.

**Solution:**
- Write shallow job classes that delegate logic to domain models
- Use `_later` suffix for methods that enqueue a job
- Use `_now` suffix for the synchronous method when both async and sync versions exist

**Pattern:**
```ruby
# Source: STYLE.md

module Event::Relaying
  extend ActiveSupport::Concern

  included do
    after_create_commit :relay_later
  end

  def relay_later
    Event::RelayJob.perform_later(self)
  end

  def relay_now
    # actual logic here
  end
end

class Event::RelayJob < ApplicationJob
  def perform(event)
    event.relay_now
  end
end
```

**Real Examples:**

`/app/models/concerns/notifiable.rb`:
```ruby
module Notifiable
  extend ActiveSupport::Concern

  included do
    after_create_commit :notify_recipients_later
  end

  def notify_recipients
    Notifier.for(self)&.notify
  end

  private
    def notify_recipients_later
      NotifyRecipientsJob.perform_later self
    end
end
```

`/app/models/notification/bundle.rb`:
```ruby
def deliver
  # synchronous delivery logic
end

def deliver_later
  DeliverJob.perform_later(self)
end
```

`/app/models/card/readable.rb`:
```ruby
def remove_inaccessible_notifications
  # synchronous logic
end

private
  def remove_inaccessible_notifications_later
    Card::RemoveInaccessibleNotificationsJob.perform_later(self)
  end
```

---

## 9. ERB Comments & Template Linting

**Problem:** `<% # comment %>` looks harmless but trips ERB parsers and template tooling
(Herb reports it as a parsing error), and some linters can't see past it.

**Solution:** Always use the dedicated ERB comment tag `<%#`:

```erb
<%# Good: dedicated ERB comment tag %>
<% # Bad: Ruby comment inside an execution tag — causes parsing issues %>
```

If the project uses [Herb](https://herb-tools.dev) (ERB language server / linter):
- `bin/herb analyze app/views app/components` checks all templates for parsing errors — run it after template changes and before committing.
- Configuration lives in `.herb.yml` (accessibility rules, HTML validity, ERB best practices).
- The VS Code Herb extension adds live linting and ERB format-on-save.

---

## Summary Checklist

When writing or reviewing code, verify:

- [ ] Class methods come before public methods, which come before private methods
- [ ] Methods are ordered by invocation flow (caller before callee)
- [ ] Using expanded conditionals instead of guard clauses (unless at method start with complex body)
- [ ] No newline after `private`, content indented under it
- [ ] Non-CRUD actions are modeled as separate resources
- [ ] Controllers are thin, calling rich model APIs
- [ ] Bang methods only used when non-bang counterpart exists
- [ ] Async operations use `_later`/`_now` naming convention with shallow jobs
- [ ] ERB comments use `<%#`, never `<% #`
