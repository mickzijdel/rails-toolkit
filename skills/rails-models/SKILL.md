---
name: rails-models
description: Use when writing ActiveRecord models with concerns, validations, callbacks, scopes, and associations
---

# Rails Model Patterns

## 1. Concern Architecture

Extract cohesive behaviors into concerns. Class-level declarations (`has_many`, callbacks, scopes) go in the `included` block; instance methods outside it.

```ruby
# app/models/concerns/eventable.rb
module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable, dependent: :destroy
  end

  def track_event(action, creator: Current.user, board: self.board, **particulars)
    if should_track_event?
      board.events.create!(action: "#{eventable_prefix}_#{action}", creator:, board:, eventable: self, particulars:)
    end
  end

  def event_was_created(event)
  end

  private
    def should_track_event?
      true
    end

    def eventable_prefix
      self.class.name.demodulize.underscore
    end
end
```

```ruby
# app/models/card.rb — a model is mostly a composition of concerns
class Card < ApplicationRecord
  include Assignable, Broadcastable, Closeable, Eventable, Mentions,
    Pinnable, Postponable, Searchable, Statuses, Taggable, Watchable
end
```

---

## 2. Template Method Pattern in Concerns

The empty/default methods above (`event_was_created`, `should_track_event?`, `eventable_prefix`) are hooks. Models customize the generic concern by overriding them in a namespaced concern:

```ruby
# app/models/card/eventable.rb
module Card::Eventable
  extend ActiveSupport::Concern

  include ::Eventable   # :: prefix avoids namespace conflicts

  def event_was_created(event)
    transaction do
      create_system_comment_for(event)
      touch_last_active_at unless was_just_published?
    end
  end

  private
    def should_track_event?
      published?   # only track events for published cards
    end
end
```

Base concern lives in `app/models/concerns/`; model-specific concerns in `app/models/model_name/`.

---

## 3. Default Associations

Use `default:` on `belongs_to` with a lambda to derive the value from other associations or `Current` attributes:

```ruby
class Card < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :creator, class_name: "User", default: -> { Current.user }
end
```

Derive from the closest parent association when possible; use `Current` only at the top of the hierarchy. Full multi-tenant scoping rules (including framework models): [[rails-multi-tenancy]].

---

## 4. Scope Composition

Build small, focused scopes that compose. Use `case` statements in parameterized scopes for index/filter patterns.

```ruby
class Card < ApplicationRecord
  scope :reverse_chronologically, -> { order created_at: :desc, id: :desc }
  scope :chronologically,         -> { order created_at: :asc,  id: :asc  }
  scope :latest,                  -> { order last_active_at: :desc, id: :desc }

  scope :indexed_by, ->(index) do
    case index
    when "stalled" then stalled
    when "closed" then closed
    when "golden" then golden
    else all
    end
  end
end
```

```ruby
# Scopes from concerns compose with each other
module Card::Closeable
  extend ActiveSupport::Concern

  included do
    has_one :closure, dependent: :destroy

    scope :closed, -> { joins(:closure) }
    scope :open, -> { where.missing(:closure) }
    scope :closed_by, ->(users) { closed.where(closures: { user_id: Array(users) }) }
  end
end
```

For `preloaded` scopes (N+1 prevention), see [[rails-performance]].

---

## 5. Normalizes Pattern

Rails 7.1+ `normalizes` cleans data declaratively before validation and save:

```ruby
class Identity < ApplicationRecord
  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }
  normalizes :email_address, with: ->(value) { value.strip.downcase.presence }
end

# Works on arrays too — filter and clean values
class Webhook < ApplicationRecord
  normalizes :subscribed_actions, with: ->(value) { Array.wrap(value).map(&:to_s).uniq & PERMITTED_ACTIONS }
end
```

`presence` converts blank strings to nil; normalizes runs before validation, so validated values are already clean.

---

## 6. Enum with Scopes

Use the hash-from-array pattern for string storage — no magic integers, readable database values:

```ruby
module Card::Statuses
  extend ActiveSupport::Concern

  included do
    enum :status, %w[ drafted published ].index_by(&:itself)

    before_save :mark_if_just_published
    after_create -> { track_event :published }, if: :published?
  end

  def publish
    transaction do
      self.created_at = Time.current
      published!
      track_event :published
    end
  end
end
```

---

## 7. Transaction Safety

Wrap multi-step operations in `transaction` blocks:

```ruby
module Card::Closeable
  def close(user: Current.user)
    unless closed?
      transaction do
        create_closure! user: user
        track_event :closed, creator: user
      end
    end
  end

  def reopen(user: Current.user)
    if closed?
      transaction do
        closure&.destroy
        track_event :reopened, creator: user
      end
    end
  end
end
```

---

## 8. Polymorphic Associations

Name the polymorphic association after what it represents (`eventable`, `source`); the `-able` suffix is conventional. Create a matching concern for models on the "source" side (see Eventable in Pattern 1), and use `delegate` to traverse the polymorphic chain.

```ruby
class Event < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :board
  belongs_to :creator, class_name: "User"
  belongs_to :eventable, polymorphic: true

  after_create -> { eventable.event_was_created(self) }
  after_create_commit :dispatch_webhooks

  delegate :card, to: :eventable
end
```

---

## 9. Callbacks Best Practices

```ruby
# Use after_*_commit for anything external: jobs, webhooks, broadcasts
module Searchable
  extend ActiveSupport::Concern

  included do
    after_create_commit :create_in_search_index
    after_update_commit :update_in_search_index
    after_destroy_commit :remove_from_search_index
  end
end

# Conditional callbacks narrow when they run
class Card < ApplicationRecord
  before_save :set_default_title, if: :published?
  after_save   -> { board.touch }, if: :published?
  after_update :handle_board_change, if: :saved_change_to_board_id?
end
```

**Key Points:**
- External side effects (jobs, webhooks, broadcasts) belong in `after_*_commit` callbacks, never plain `after_save` — the transaction may still roll back.
- `saved_change_to_X?` in `after_save`/`after_update`; `X_changed?` in `before_save`.
- `touch: true` on `belongs_to` propagates timestamp changes up the association chain.

---

## 10. Association Extensions

Pass a block to `has_many` to define methods directly on the association; `proxy_association.owner` accesses the parent record.

```ruby
module Board::Accessible
  extend ActiveSupport::Concern

  included do
    has_many :accesses, dependent: :delete_all do
      def revise(granted: [], revoked: [])
        transaction do
          grant_to granted
          revoke_from revoked
        end
      end

      def grant_to(users)
        Access.insert_all Array(users).collect { |user|
          { id: ActiveRecord::Type::Uuid.generate, board_id: proxy_association.owner.id, user_id: user.id, account_id: proxy_association.owner.account.id }
        }
      end

      def revoke_from(users)
        destroy_by user: users unless proxy_association.owner.all_access?
      end
    end
  end
end

# board.accesses.revise(granted: new_users, revoked: removed_users)
```

---

## 11. Inquiry on Enums

`.inquiry` converts string values to `ActiveSupport::StringInquirer` for expressive conditionals:

```ruby
class Event < ApplicationRecord
  def action
    super.inquiry
  end
end

# event.action.card_closed? / event.action.comment_created?
```

---

## 12. Migrations & Foreign Keys (legacy integer PKs)

Older tables may have `id: :integer` rather than `bigint`. A foreign key pointing *to* such a table must declare the **matching** type, or the FK migration aborts. Check the parent's `id:` in `db/schema.rb` before writing the reference.

```ruby
# db/schema.rb shows: create_table "opportunities", id: :integer do |t| ...
class CreateOpportunityRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :opportunity_roles do |t|   # new table → bigint id, fine
      # FK to a legacy integer-PK parent MUST match its type:
      t.references :opportunity, type: :integer, foreign_key: true

      t.string :name, null: false
      t.timestamps
    end
  end
end
```

**Key Points:**
- Only the FK *referencing a legacy integer PK* needs `type: :integer`; FKs to new bigint tables need no `type:`.
- For populated tables, adding non-null/unique columns is still multi-step — see [[rails-core]] rule 5.
- In a multi-database app, roll back with the namespaced task: `bin/rails db:rollback:primary STEP=n` ([[rails-core]] rule 6).

---

## 13. Anti-Patterns to Avoid

A few ActiveRecord defaults bite later. Prefer the right column on the right:

- **`default_scope`** → use explicit named scopes (Pattern 4). A `default_scope` silently filters *every* query, leaks into `new`/`create` attribute defaults and through associations, and is awkward to escape (`unscoped` drops *all* conditions, not just the default).
- **`has_and_belongs_to_many`** → use `has_many :through` with a real join model. The join table is a record you'll inevitably want to give a column, validation, or callback; HABTM can't.
- **Boolean `presence` validation** → `validates :active, presence: true` rejects `false`, since `false.blank?` is true. Use `inclusion: { in: [ true, false ] }`, or rely on a `null: false` column with a default.
- **`delete`/`delete_all` when callbacks or `dependent:` matter** → use `destroy`/`destroy_all`. `delete` issues a raw SQL `DELETE`, skipping callbacks ([[rails-models]] §9), `dependent:` cleanup, and `after_*_commit` side effects. Only reach for `delete_all` on a scope you've confirmed has no dependents to cascade.

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| Concern with `included` block | Extracting reusable model behaviors |
| Template methods | Allowing models to customize concern behavior |
| `default:` on associations | Deriving values from parent records or `Current` |
| Composable scopes | Building complex queries from simple parts |
| `normalizes` | Cleaning user input before storage |
| `enum` with `index_by` | Status/type fields with readable database values |
| `transaction` blocks | Multi-step operations needing atomicity |
| Polymorphic associations | Multiple models relating to the same record type |
| `after_*_commit` callbacks | External side effects (jobs, broadcasts) |
| Association extensions | Custom collection methods |
| `t.references :x, type: :integer` | FK pointing to a legacy `id: :integer` parent table |
| `has_many :through` over `has_and_belongs_to_many` | Join needs (or may need) its own columns/validations |
| `inclusion: { in: [true, false] }` | Validating a boolean is set (`presence` rejects `false`) |
| `destroy` over `delete` | Removal must fire callbacks and `dependent:` cleanup |
