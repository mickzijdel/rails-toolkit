---
name: rails-models
description: Use when writing ActiveRecord models with concerns, validations, callbacks, scopes, and associations
---

# Rails Model Patterns

## When to Use
- Creating new models
- Organizing model logic with concerns
- Setting up associations, validations, and callbacks
- Building composable query scopes
- Implementing domain behaviors

---

## 1. Concern Architecture

**Problem:** Model files become bloated with unrelated behaviors mixed together.

**Solution:** Extract cohesive behaviors into concerns using `ActiveSupport::Concern`. Structure concerns with `extend ActiveSupport::Concern` and use the `included` block for class-level declarations.

**Example:**

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
# app/models/card.rb
class Card < ApplicationRecord
  include Assignable, Attachments, Broadcastable, Closeable, Colored, Entropic, Eventable,
    Exportable, Golden, Mentions, Multistep, Pinnable, Postponable, Promptable,
    Readable, Searchable, Stallable, Statuses, Storage::Tracked, Taggable, Triageable, Watchable
end
```

**Source:** `app/models/concerns/eventable.rb`, `app/models/card.rb`

**Key Points:**
- Use `extend ActiveSupport::Concern` at the top
- Put `has_many`, `belongs_to`, callbacks, and scopes in the `included` block
- Instance methods go outside the `included` block
- Private methods maintain the same indentation style as the main model

---

## 2. Template Method Pattern in Concerns

**Problem:** A concern provides generic behavior, but specific models need to customize parts of it.

**Solution:** Define empty or default hook methods that including models can override.

**Example:**

```ruby
# app/models/concerns/eventable.rb
module Eventable
  extend ActiveSupport::Concern

  # Hook method - models can override to customize event tracking
  def event_was_created(event)
  end

  private
    # Template method - override to control when events are tracked
    def should_track_event?
      true
    end

    # Template method - override to change event action prefix
    def eventable_prefix
      self.class.name.demodulize.underscore
    end
end
```

```ruby
# app/models/card/eventable.rb
module Card::Eventable
  extend ActiveSupport::Concern

  include ::Eventable

  def event_was_created(event)
    transaction do
      create_system_comment_for(event)
      touch_last_active_at unless was_just_published?
    end
  end

  private
    # Override: only track events for published cards
    def should_track_event?
      published?
    end
end
```

```ruby
# app/models/comment/eventable.rb
module Comment::Eventable
  extend ActiveSupport::Concern

  include ::Eventable

  def event_was_created(event)
    card.touch_last_active_at
  end

  private
    # Override: system comments don't create events
    def should_track_event?
      !creator.system?
    end
end
```

**Source:** `app/models/concerns/eventable.rb`, `app/models/card/eventable.rb`, `app/models/comment/eventable.rb`

---

## 3. Default Associations for Multi-Tenancy

**Problem:** Multi-tenant apps need to consistently scope records to accounts, and the account often derives from associated records.

**Solution:** Use `default:` on `belongs_to` with a lambda to derive the value from other associations or `Current` attributes.

**Example:**

```ruby
# Derive account from parent association
class Card < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :board
  belongs_to :creator, class_name: "User", default: -> { Current.user }
end

class Comment < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card, touch: true
  belongs_to :creator, class_name: "User", default: -> { Current.user }
end

class Column < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :board, touch: true
end

# Derive from Current when at top of hierarchy
class Tag < ApplicationRecord
  belongs_to :account, default: -> { Current.account }
end

# Chain through multiple levels
class Board < ApplicationRecord
  belongs_to :creator, class_name: "User", default: -> { Current.user }
  belongs_to :account, default: -> { creator.account }
end
```

**Source:** `app/models/card.rb`, `app/models/comment.rb`, `app/models/column.rb`, `app/models/tag.rb`, `app/models/board.rb`

**Key Points:**
- Always include `account_id` on all tenant-scoped models
- Derive `account` from the closest parent association when possible
- Use `Current.user` for creator defaults
- Use `touch: true` to propagate timestamp changes up the association chain

---

## 4. Scope Composition

**Problem:** Complex queries become duplicated and hard to maintain.

**Solution:** Build small, focused scopes that can be composed together. Use `case` statements in scopes for index/filter patterns.

**Example:**

```ruby
# app/models/card.rb
class Card < ApplicationRecord
  # Basic ordering scopes
  scope :reverse_chronologically, -> { order created_at: :desc, id: :desc }
  scope :chronologically,         -> { order created_at: :asc,  id: :asc  }
  scope :latest,                  -> { order last_active_at: :desc, id: :desc }

  # Preloading scopes for performance
  scope :with_users, -> { preload(creator: [ :avatar_attachment, :account ], assignees: [ :avatar_attachment, :account ]) }
  scope :preloaded, -> { with_users.preload(:column, :tags, :steps, :closure, :goldness, :activity_spike, :image_attachment, board: [ :entropy, :columns ], not_now: [ :user ]).with_rich_text_description_and_embeds }

  # Parameterized index scope
  scope :indexed_by, ->(index) do
    case index
    when "stalled" then stalled
    when "postponing_soon" then postponing_soon
    when "closed" then closed
    when "not_now" then postponed.latest
    when "golden" then golden
    when "draft" then drafted
    else all
    end
  end

  # Parameterized sort scope
  scope :sorted_by, ->(sort) do
    case sort
    when "newest" then reverse_chronologically
    when "oldest" then chronologically
    when "latest" then latest
    else latest
    end
  end
end
```

```ruby
# app/models/card/closeable.rb - Composable scopes from concerns
module Card::Closeable
  extend ActiveSupport::Concern

  included do
    has_one :closure, dependent: :destroy

    scope :closed, -> { joins(:closure) }
    scope :open, -> { where.missing(:closure) }

    # Scopes that build on the base scopes
    scope :recently_closed_first, -> { closed.order(closures: { created_at: :desc }) }
    scope :closed_at_window, ->(window) { closed.where(closures: { created_at: window }) }
    scope :closed_by, ->(users) { closed.where(closures: { user_id: Array(users) }) }
  end
end
```

```ruby
# app/models/card/postponable.rb - Combining multiple scopes
module Card::Postponable
  extend ActiveSupport::Concern

  included do
    has_one :not_now, dependent: :destroy, class_name: "Card::NotNow"

    # Compose multiple conditions
    scope :postponed, -> { open.published.joins(:not_now) }
    scope :active, -> { open.published.where.missing(:not_now) }
  end
end
```

**Source:** `app/models/card.rb`, `app/models/card/closeable.rb`, `app/models/card/postponable.rb`

---

## 5. Normalizes Pattern

**Problem:** User input often needs consistent formatting (trimming whitespace, case normalization) before storage.

**Solution:** Use Rails 7.1+ `normalizes` to declaratively clean data before validation and save.

**Example:**

```ruby
# app/models/identity.rb
class Identity < ApplicationRecord
  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }
  normalizes :email_address, with: ->(value) { value.strip.downcase.presence }
end
```

```ruby
# app/models/tag.rb
class Tag < ApplicationRecord
  validates :title, format: { without: /\A#/ }
  normalizes :title, with: -> { it.downcase }
end
```

```ruby
# app/models/webhook.rb
class Webhook < ApplicationRecord
  PERMITTED_ACTIONS = %w[
    card_assigned
    card_closed
    card_postponed
    # ...
  ].freeze

  # Normalize arrays - filter and clean values
  normalizes :subscribed_actions, with: ->(value) { Array.wrap(value).map(&:to_s).uniq & PERMITTED_ACTIONS }
end
```

**Source:** `app/models/identity.rb`, `app/models/tag.rb`, `app/models/webhook.rb`

**Key Points:**
- Use `strip` to remove leading/trailing whitespace
- Use `downcase` for case-insensitive fields
- Use `presence` to convert blank strings to nil
- Normalizes runs before validation, so validated values are already clean
- Works on arrays and complex types too

---

## 6. Enum with Scopes

**Problem:** Status fields need validation, scopes, and predicate methods.

**Solution:** Use `enum` with the hash-from-array pattern for string storage.

**Example:**

```ruby
# app/models/card/statuses.rb
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

```ruby
# app/models/access.rb
class Access < ApplicationRecord
  enum :involvement, %i[ access_only watching ].index_by(&:itself), default: :access_only

  scope :ordered_by_recently_accessed, -> { order(accessed_at: :desc) }
end
```

**Source:** `app/models/card/statuses.rb`, `app/models/access.rb`

**Key Points:**
- Use `%w[...].index_by(&:itself)` or `%i[...].index_by(&:itself)` for string storage in the database
- This avoids magic integers and makes the database readable
- Provides scopes like `.drafted`, `.published` automatically
- Provides predicates like `.drafted?`, `.published?` automatically
- Provides bang methods like `.drafted!`, `.published!` automatically

---

## 7. Transaction Safety

**Problem:** Multi-step operations can leave data in an inconsistent state if one step fails.

**Solution:** Wrap related operations in `transaction` blocks to ensure atomicity.

**Example:**

```ruby
# app/models/card/closeable.rb
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

```ruby
# app/models/card.rb
class Card < ApplicationRecord
  def move_to(new_board)
    transaction do
      card.update!(board: new_board)
      card.events.update_all(board_id: new_board.id)
    end
  end

  private
    def handle_board_change
      old_board = account.boards.find_by(id: board_id_before_last_save)

      transaction do
        update! column: nil
        track_board_change_event(old_board.name)
        grant_access_to_assignees unless board.all_access?
      end

      remove_inaccessible_notifications_later
    end
end
```

```ruby
# app/models/card/postponable.rb
module Card::Postponable
  def postpone(user: Current.user, event_name: :postponed)
    transaction do
      send_back_to_triage(skip_event: true)
      reopen
      activity_spike&.destroy
      create_not_now!(user: user) unless postponed?
      track_event event_name, creator: user
    end
  end

  def resume
    transaction do
      reopen
      activity_spike&.destroy
      not_now&.destroy
    end
  end
end
```

```ruby
# app/models/user.rb
class User < ApplicationRecord
  def deactivate
    transaction do
      accesses.destroy_all
      update! active: false, identity: nil
      close_remote_connections
    end
  end
end
```

**Source:** `app/models/card/closeable.rb`, `app/models/card.rb`, `app/models/card/postponable.rb`, `app/models/user.rb`

---

## 8. Polymorphic Associations

**Problem:** Multiple models need to associate with the same type of record (e.g., events, notifications, mentions).

**Solution:** Use polymorphic associations with clear naming conventions.

**Example:**

```ruby
# app/models/event.rb
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

```ruby
# app/models/concerns/eventable.rb - The concern for the "source" side
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
end
```

```ruby
# app/models/notification.rb - Another polymorphic pattern
class Notification < ApplicationRecord
  belongs_to :account, default: -> { user.account }
  belongs_to :user
  belongs_to :creator, class_name: "User"
  belongs_to :source, polymorphic: true

  delegate :notifiable_target, to: :source
  delegate :card, to: :source
end
```

```ruby
# app/models/concerns/notifiable.rb
module Notifiable
  extend ActiveSupport::Concern

  included do
    has_many :notifications, as: :source, dependent: :destroy

    after_create_commit :notify_recipients_later
  end

  def notifiable_target
    self
  end

  private
    def notify_recipients_later
      NotifyRecipientsJob.perform_later self
    end
end
```

```ruby
# app/models/mention.rb pattern
class Mention < ApplicationRecord
  belongs_to :source, polymorphic: true  # Card or Comment
  belongs_to :mentionee, class_name: "User"
end

# app/models/concerns/mentions.rb
module Mentions
  extend ActiveSupport::Concern

  included do
    has_many :mentions, as: :source, dependent: :destroy
    has_many :mentionees, through: :mentions
    after_save_commit :create_mentions_later, if: :should_create_mentions?
  end
end
```

**Source:** `app/models/event.rb`, `app/models/concerns/eventable.rb`, `app/models/notification.rb`, `app/models/concerns/notifiable.rb`, `app/models/concerns/mentions.rb`

**Key Points:**
- Name the polymorphic association after what it represents (e.g., `eventable`, `source`, `notifiable_target`)
- Create matching concerns for models that can be the polymorphic source
- Use `delegate` to traverse the polymorphic chain
- The `-able` suffix is common: `eventable`, `searchable`, `notifiable`

---

## 9. Callbacks Best Practices

**Problem:** Callbacks can cause unexpected side effects and make code hard to follow.

**Solution:** Use specific callback types and conditions. Prefer `after_commit` for external operations.

**Example:**

```ruby
# app/models/event.rb - Use after_create_commit for background jobs
class Event < ApplicationRecord
  after_create -> { eventable.event_was_created(self) }
  after_create_commit :dispatch_webhooks

  private
    def dispatch_webhooks
      Event::WebhookDispatchJob.perform_later(self)
    end
end
```

```ruby
# app/models/concerns/searchable.rb - Different callbacks for different operations
module Searchable
  extend ActiveSupport::Concern

  included do
    after_create_commit :create_in_search_index
    after_update_commit :update_in_search_index
    after_destroy_commit :remove_from_search_index
  end
end
```

```ruby
# app/models/card.rb - Conditional callbacks
class Card < ApplicationRecord
  before_save :set_default_title, if: :published?
  before_create :assign_number

  after_save   -> { board.touch }, if: :published?
  after_touch  -> { board.touch }, if: :published?
  after_update :handle_board_change, if: :saved_change_to_board_id?
end
```

```ruby
# app/models/card/statuses.rb - Conditional callback on state change
module Card::Statuses
  extend ActiveSupport::Concern

  included do
    before_save :mark_if_just_published
    after_create -> { track_event :published }, if: :published?
  end

  private
    def mark_if_just_published
      self.was_just_published = true if published? && status_changed?
    end
end
```

```ruby
# app/models/column.rb - Cascading touch with after_save_commit
class Column < ApplicationRecord
  after_save_commit    -> { cards.touch_all }, if: -> { saved_change_to_name? || saved_change_to_color? }
  after_destroy_commit -> { board.cards.touch_all }
end
```

```ruby
# app/models/access.rb - after_destroy_commit for cleanup jobs
class Access < ApplicationRecord
  after_destroy_commit :clean_inaccessible_data_later

  private
    def clean_inaccessible_data_later
      Board::CleanInaccessibleDataJob.perform_later(user, board)
    end
end
```

**Source:** `app/models/event.rb`, `app/models/concerns/searchable.rb`, `app/models/card.rb`, `app/models/card/statuses.rb`, `app/models/column.rb`, `app/models/access.rb`

**Key Points:**
- Use `after_create_commit` / `after_update_commit` / `after_destroy_commit` for background jobs
- Use `after_commit` for any external side effects (jobs, webhooks, broadcasts)
- Use conditions with `if:` to narrow when callbacks run
- Use `saved_change_to_X?` in `after_save`/`after_update` to check specific attribute changes
- Use `X_changed?` in `before_save` callbacks
- Use `touch: true` on `belongs_to` to propagate changes automatically

---

## 10. Association Extensions

**Problem:** You need custom methods on an association that operate on the collection.

**Solution:** Pass a block to `has_many` to define methods directly on the association.

**Example:**

```ruby
# app/models/board/accessible.rb
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
```

**Usage:**

```ruby
board.accesses.grant_to(users)
board.accesses.revoke_from(users)
board.accesses.revise(granted: new_users, revoked: removed_users)
```

**Source:** `app/models/board/accessible.rb`

**Key Points:**
- Use `proxy_association.owner` to access the parent record
- Extension methods can call other extension methods
- Wrap multiple operations in transactions for atomicity
- Use `insert_all` for bulk inserts when appropriate

---

## 11. Model-Specific Concerns (Namespaced)

**Problem:** Generic concerns need model-specific customization, but you want to keep the base concern clean.

**Solution:** Create namespaced concerns under the model that include and extend the base concern.

**Example:**

```ruby
# app/models/concerns/searchable.rb - Base concern
module Searchable
  extend ActiveSupport::Concern

  included do
    after_create_commit :create_in_search_index
    after_update_commit :update_in_search_index
    after_destroy_commit :remove_from_search_index
  end

  # Models must implement: search_title, search_content, search_card_id, search_board_id
end
```

```ruby
# app/models/card/searchable.rb - Card-specific implementation
module Card::Searchable
  extend ActiveSupport::Concern

  included do
    include ::Searchable

    scope :mentioning, ->(query, user:) do
      search_record_class = Search::Record.for(user.account_id)
      joins(search_record_class.card_join).merge(search_record_class.for_query(query, user: user))
    end
  end

  def search_title
    title
  end

  def search_content
    description.to_plain_text
  end

  def search_card_id
    id
  end

  def search_board_id
    board_id
  end
end
```

```ruby
# app/models/comment/searchable.rb - Comment-specific implementation
module Comment::Searchable
  extend ActiveSupport::Concern

  included do
    include ::Searchable
  end

  def search_title
    nil
  end

  def search_content
    body.to_plain_text
  end

  def search_card_id
    card_id
  end

  def search_board_id
    card.board_id
  end
end
```

**Source:** `app/models/concerns/searchable.rb`, `app/models/card/searchable.rb`, `app/models/comment/searchable.rb`

**Key Points:**
- Base concern in `app/models/concerns/`
- Model-specific concerns in `app/models/model_name/`
- Include the base concern with `::` prefix to avoid namespace conflicts
- Override or implement required template methods

---

## 12. Inquiry on Enums

**Problem:** You want expressive conditionals when checking enum values from the database.

**Solution:** Use `.inquiry` to convert string values to `ActiveSupport::StringInquirer`.

**Example:**

```ruby
# app/models/event.rb
class Event < ApplicationRecord
  def action
    super.inquiry
  end
end

# Now you can do:
if event.action.card_closed?
  # ...
end

if event.action.comment_created?
  # ...
end
```

**Source:** `app/models/event.rb`

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
