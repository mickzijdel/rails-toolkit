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

## 10. Enforcing Style on AI-Generated Code

Everything above this point is *taste* — and a skill or `CLAUDE.md` only **asks** the agent to follow it. A [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) **guarantees** the check runs. Deterministic beats hopeful: don't rely on the model remembering the style guide, run RuboCop and make a clean result a condition of finishing. (Technique adapted from thoughtbot's [*Enforcing Your Ruby Style Guide on AI-Generated Code*](https://thoughtbot.com/blog/enforcing-your-ruby-style-guide-on-ai-generated-code).)

> **rails-toolkit ships a gentle version of this for free.** When the plugin is installed, a `PostToolUse` hook (`bin/rubocop-autocorrect-hook`) runs after each `.rb`/`.rake` edit, safe-autocorrects that one file, and reports any remaining offenses back as context — but only in a project that opted into RuboCop (a `.rubocop.yml`) with a resolvable runner; it no-ops everywhere else. It never blocks. The `Stop` hook below is the stronger, *blocking* variant you add per-project when you want the agent's completion gated on a clean lint.

### The hook

Drop this into **your own Rails project** (not into a plugin — a project-local hook only fires for that repo). A `Stop` hook runs RuboCop over the Ruby files in the diff once the agent thinks it is done, autocorrects what it can, and — if offenses remain — exits non-zero so Claude Code feeds the message back and the agent gets exactly **one** corrective pass before it is allowed to stop.

`.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": ".claude/hooks/rubocop.sh" } ] }
    ]
  }
}
```

`.claude/hooks/rubocop.sh`:

```sh
#!/usr/bin/env sh
# Stop hook: lint the Ruby files the agent touched, autocorrect, then re-check.
# Exit 2 + stderr -> Claude Code blocks the stop and feeds the message back,
# giving the agent one chance to fix what --autocorrect could not.
set -e

files=$(git diff --name-only --diff-filter=d HEAD -- '*.rb' '*.rake' | tr '\n' ' ')
[ -z "$files" ] && exit 0

bundle exec rubocop --autocorrect $files >/dev/null 2>&1 || true

if ! out=$(bundle exec rubocop --format simple $files 2>&1); then
  printf 'RuboCop offenses remain — fix them (do not disable cops):\n%s\n' "$out" >&2
  exit 2
fi
```

A lighter alternative is a `PostToolUse` hook on `Edit|Write` that just runs `bundle exec rubocop -a "$file"` per edit — cheaper, but it only autocorrects and never blocks on what it can't fix. The `Stop` version above is what catches the offenses that need the agent's judgment.

### What config to lint against — and what NOT to do

Use **`rubocop-rails-omakase`**: it is the Rails 8 default and the same 37signals house style the rest of this toolkit follows. **Do not hand-author a sprawling custom `.rubocop.yml`** — omakase's own README calls that bikeshedding, and a big bespoke cop set cuts against [[rails-philosophy]] §1 ("Vanilla Rails Is Plenty"). Two things to know about what omakase does and doesn't do:

- **It only covers mechanical consistency** — spacing, indentation, `case`/`end` alignment, double-quoted strings, trailing whitespace. It **cannot** express the taste rules in this skill (method ordering, caller-before-callee, expanded conditionals, CRUD-as-resources, bang / `_later` / `_now` conventions, thin controllers). So the hook and this skill are **complementary**, not redundant: RuboCop enforces the mechanical layer; the agent follows the taste layer because this skill is loaded.
- **It disables the whole `Rails` and `Security` departments**, so `Rails/OutputSafety` is **off by default**. To get the `html_safe`/`raw` XSS guard referenced below, re-enable a *small* targeted subset on top of omakase — not a full rule set:

```yml
# .rubocop.yml
inherit_gem:
  rubocop-rails-omakase: rubocop.yml

Rails/OutputSafety:   # html_safe / raw are XSS vectors — keep this on
  Enabled: true
Lint/Debugger:        # no stray binding.irb / debugger in committed code
  Enabled: true
```

### The discipline (`.claude/rules/rubocop.md`)

A hook stops the agent from *silently shipping* offenses; a rules file stops it from *cheating past* them. Add `.claude/rules/rubocop.md` telling the agent:

- **Fix offenses, don't hide them.** Never reach for inline `# rubocop:disable` or `# rubocop:todo` to make a violation go away.
- **If a cop genuinely doesn't fit** this codebase, surface it in the final response and let the human decide (adjust the config vs. write a real fix) — don't silence it unilaterally.
- **Never silence `Rails/OutputSafety`.** `html_safe` and `raw` are XSS vectors; if a specific use is truly safe, surface it for the user to approve rather than disabling the cop. See [[rails-security]] for CSP/XSS context.

### Beyond omakase: a custom cop for a rule it can't express

omakase covers mechanical consistency; it has no cop for a *semantic* rule like "never mutate `params`" (see [[rails-controllers]] Pattern 11). **No upstream cop covers this** either — `rubocop-rails` ships `Rails/StrongParameters` and `Rails/StrongParametersExpect`, but those are about *permitting*, not *mutating*. When you have a rule that specific and no cop exists, a ~40-line custom cop makes it enforceable. Drop this into your project:

`lib/rubocop/cop/custom/params_mutation.rb`:

```ruby
# frozen_string_literal: true

module RuboCop
  module Cop
    module Custom
      # Flags in-place mutation of the request `params` object. `params` is
      # shared request state, not a scratchpad — build a separate hash instead.
      # Heuristic: flags a mutating call whose *immediate* receiver is a bare
      # `params`. It cannot follow aliases (`p = params; p.delete`) — static
      # analysis does not track that.
      class ParamsMutation < Base
        MSG = "Do not mutate `params`; build a separate hash instead."

        MUTATING_METHODS = %i[
          []= delete delete_if merge! update store deep_merge!
          except! extract! slice! compact! reject! select! keep_if clear
          transform_keys! transform_values! deep_transform_keys! deep_transform_values!
        ].freeze

        def_node_matcher :bare_params?, "(send nil? :params)"

        def on_send(node)
          return unless MUTATING_METHODS.include?(node.method_name)
          return unless bare_params?(node.receiver)

          add_offense(node)
        end
        alias on_csend on_send   # also catch `params&.delete(...)`
      end
    end
  end
end
```

Wire it up in `.rubocop.yml` (a project-local `Custom/` department sidesteps any clash with the extracted `Rails/` namespace):

```yml
require:
  - ./lib/rubocop/cop/custom/params_mutation.rb

Custom/ParamsMutation:
  Enabled: true
  Include:
    - app/controllers/**/*.rb
```

It flags `params[:x] = …`, `params.delete`, `params.merge!`, `params.update`, `params&.delete`, and the other bang mutators — while leaving reads, non-bang copies (`params.except`, `params.permit(...).merge`), and mutations of a plain hash or a `.dup` alone. **Limitation:** it only sees a *bare* `params` receiver; it can't catch mutation through an alias (`p = params; p.delete`), which needs flow analysis. Treat it as a high-signal tripwire, not a proof.

**Upstreaming.** Rails-specific cops live in `rubocop-rails`, not `rubocop/rubocop` (RuboCop core is pure-Ruby only), added under its single `Rails` department via `bundle exec rake 'new_cop[Rails/ParamsMutation]'`. It's a plausible contribution — the mutation methods are already deprecated on `ActionController::Parameters` — but maintainers weigh false-positive rate and general applicability, and the alias blind spot is a real weakness. Ship it as a project-local cop first; propose upstream once it's proven low-noise on a real codebase.

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
- [ ] Style is enforced on AI output via a RuboCop hook; offenses are fixed, never `# rubocop:disable`-d (and `Rails/OutputSafety` is never silenced)
