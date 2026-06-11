---
name: rails-style
description: Use when following Rails code style conventions for method ordering, conditionals, REST routing, and naming
---

# Rails Code Style

## 1. Method Ordering

Order methods in classes: class methods first, then public methods (`initialize` at the top), then private methods.

```ruby
class SomeClass
  # 1. Class methods first
  class << self
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

  # 3. Private methods
  private
    def deliverable?
      # ...
    end
end
```

---

## 2. Invocation Order

Within each visibility section, order methods vertically by invocation: callers before the methods they call.

```ruby
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
      # ...
    end
end
```

---

## 3. Conditional Returns

Prefer expanded conditionals over guard clauses.

```ruby
# Bad
def todos_for_new_group
  ids = params.require(:todolist)[:todo_ids]
  return [] unless ids
  @bucket.recordings.todos.find(ids.split(","))
end

# Good
def todos_for_new_group
  if ids = params.require(:todolist)[:todo_ids]
    @bucket.recordings.todos.find(ids.split(","))
  else
    []
  end
end
```

**Exception:** a guard clause is acceptable when the return is right at the beginning of the method *and* the main body is non-trivial:

```ruby
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

No newline under `private`; indent content under it. For modules with only private methods: `private` at the top, extra newline after, no indent.

```ruby
class SomeClass
  def some_method
    # ...
  end

  private
    def some_private_method
      # ...
    end
end
```

```ruby
module SomeModule
  private

  def some_private_method
    # ...
  end
end
```

---

## 5. CRUD Controllers

Model web endpoints as CRUD on resources; when an action doesn't map to a CRUD verb, introduce a new resource instead of a custom action:

```ruby
# Bad
resources :cards do
  post :close
  post :reopen
end

# Good — create = close, destroy = reopen
resources :cards do
  resource :closure
end
```

Full pattern (controllers, more resource examples): [[rails-controllers]] Pattern 3.

---

## 6. Controller-Model Interaction

Thin controllers directly invoke a rich domain model — plain ActiveRecord (`@card.comments.create!(comment_params)`) or intention-revealing model APIs (`@card.gild`). No services or other artifacts connecting the two; a form/service object like `Signup.new(email_address:).create_identity` is the rare justified exception. See [[rails-controllers]] Pattern 8 and [[rails-philosophy]].

---

## 7. Bang Method Conventions

Only use `!` for methods that have a corresponding counterpart without `!`. Don't use `!` to flag destructive actions.

```ruby
record.save!     # Good: save! has a counterpart save
@card.gild!      # Bad: no gild counterpart exists
@card.gild       # Correct
```

---

## 8. Async Operations

Shallow job classes delegating to domain models, with `_later` for the enqueueing method and `_now` for the synchronous version when both exist:

```ruby
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

Full job patterns (recurring, queues, error handling): [[rails-jobs]].

---

## 9. ERB Comments & Template Linting

`<% # comment %>` looks harmless but trips ERB parsers and template tooling (Herb reports it as a parsing error). Always use the dedicated ERB comment tag `<%#`:

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
