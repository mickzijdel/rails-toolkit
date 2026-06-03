---
name: rails-philosophy
description: Core philosophies, design choices, and tacit knowledge underpinning 37signals-style Rails development
---

# Rails Philosophy

The foundational principles and tacit knowledge behind this style of Rails development, distilled from 37signals/Basecamp's approach to building software.

## When to Use
- Starting a new Rails project
- Making architectural decisions
- Choosing between approaches
- Reviewing code for alignment with principles
- Onboarding to this style of development

---

## Core Philosophy

> "We aim to write code that is a pleasure to read, and we have a lot of opinions about how to do it well. Writing great code is an essential part of our programming culture, and we deliberately set a high bar for every code change anyone contributes. We care about how code reads, how code looks, and how code makes you feel when you read it."

**Source:** [STYLE.md](STYLE.md)

---

## The Principles

### 1. Vanilla Rails Is Plenty

**The Belief:** Rails provides everything you need. Resist the urge to add layers of abstraction.

**In Practice:**
- No service objects wrapping simple operations
- No repository pattern over ActiveRecord
- No command/query separation (CQRS) for typical apps
- No dependency injection containers
- Direct model invocation from controllers

**Anti-patterns to Avoid:**
```ruby
# Over-engineered
class CreateCardService
  def initialize(board, params, current_user)
    @board = board
    @params = params
    @current_user = current_user
  end

  def call
    Card.create!(@params.merge(board: @board, creator: @current_user))
  end
end

# Just use Rails
@card = @board.cards.create!(card_params.merge(creator: Current.user))
```

**The Test:** If you're adding an abstraction, ask: "Does Rails already solve this?" Usually, yes.

---

### 2. The Model Is the Domain

**The Belief:** ActiveRecord models aren't just database wrappers—they ARE your domain. Enrich them.

**In Practice:**
- Business logic lives in models, not services
- Models have intention-revealing public APIs (`card.gild`, `card.close`)
- Controllers invoke model methods, not orchestrate operations
- Concerns extract reusable behavior, not "separate responsibilities"

**Example:**
```ruby
# The model IS the domain
class Card < ApplicationRecord
  def close(user: Current.user)
    transaction do
      create_closure!(user: user)
      track_event(:closed, creator: user)
    end
  end

  def gild
    create_goldness!(user: Current.user) unless golden?
  end

  def postpone
    transaction do
      create_not_now!(user: Current.user)
      track_event(:postponed)
    end
  end
end

# Controller just invokes
class Cards::ClosuresController < ApplicationController
  def create
    @card.close
  end
end
```

---

### 3. REST Everything

**The Belief:** Every operation can be modeled as CRUD on a resource. This isn't limiting—it's clarifying.

**In Practice:**
- `POST /cards/:id/close` → `POST /cards/:id/closure`
- `POST /cards/:id/reopen` → `DELETE /cards/:id/closure`
- `POST /cards/:id/gild` → `POST /cards/:id/goldness`
- State changes become resources (Closure, Goldness, Pin, Watch)

**Why It Works:**
- Consistent mental model
- Standard HTTP semantics
- Easier caching (resources have URLs)
- Clear controller responsibilities

**The Pattern:**
```ruby
# A "state change" becomes a resource
resources :cards do
  resource :closure      # close = create, reopen = destroy
  resource :goldness     # gild = create, ungild = destroy
  resource :pin          # pin = create, unpin = destroy
  resource :watch        # watch = create, unwatch = destroy
  resource :not_now      # postpone = create
end
```

---

### 4. Concerns Over Services

**The Belief:** Composition through concerns is more natural in Rails than service objects.

**In Practice:**
- Concerns for shared model behavior (Eventable, Searchable, Notifiable)
- Concerns for controller mixins (CardScoped, BoardScoped, Authentication)
- Model namespacing for complex features (Card::Closeable, Card::Searchable)

**Why Concerns Win:**
- They extend the class, not wrap it
- No indirection—the behavior IS on the model
- Easier testing—test the model directly
- Rails conventions for inclusion

**Structure:**
```ruby
# Shared across models
module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable
  end

  def track_event(action, ...)
    # ...
  end
end

# Model-specific
module Card::Closeable
  extend ActiveSupport::Concern

  def close(user: Current.user)
    # ...
  end

  def reopen
    # ...
  end
end
```

---

### 5. Database-Backed Everything (Solid Stack)

**The Belief:** You probably don't need Redis. The database you already have is remarkably capable.

**In Practice:**
- **Solid Queue** for background jobs (not Sidekiq)
- **Solid Cache** for caching (not Redis)
- **Solid Cable** for WebSockets (not Redis)
- SQLite for small deployments, MySQL for scale

**Why It Works:**
- One less service to operate
- Simpler infrastructure
- Transactions across jobs and data
- ACID guarantees

**The Trade-off:** Slightly higher latency for pub/sub, but simpler operations. For most apps, this is the right trade.

---

### 6. Server-Rendered First (Hotwire)

**The Belief:** HTML over the wire beats JSON APIs for most web applications.

**In Practice:**
- Turbo Drive for page navigation
- Turbo Frames for partial updates
- Turbo Streams for real-time
- Stimulus for JavaScript sprinkles
- No React/Vue/Angular SPA

**Why It Works:**
- Less JavaScript to maintain
- Server controls the state
- Progressive enhancement built-in
- Faster initial render

**The Pattern:**
```ruby
# Controller responds with HTML or Turbo Stream
respond_to do |format|
  format.html { redirect_to @card }
  format.turbo_stream
end
```

```erb
<%# Turbo Stream template %>
<%= turbo_stream.replace @card %>
<%= turbo_stream.append "flash", partial: "shared/flash" %>
```

---

### 7. Convention Over Configuration (Really)

**The Belief:** Follow Rails conventions even when they feel "limiting." The consistency pays off.

**In Practice:**
- Standard directory structure
- RESTful routes
- Model/View/Controller separation
- ActiveRecord patterns
- Rails naming conventions

**When to Break Convention:** Almost never. If you're fighting Rails, you're probably wrong.

---

### 8. Shallow Jobs, Rich Models

**The Belief:** Background jobs are just async method calls. Keep them thin.

**In Practice:**
```ruby
# Job is just a shell
class NotifyRecipientsJob < ApplicationJob
  def perform(notifiable)
    notifiable.notify_recipients  # Model does the work
  end
end

# Model has the logic
module Notifiable
  def notify_recipients_later
    NotifyRecipientsJob.perform_later(self)
  end

  def notify_recipients
    Notifier.for(self)&.notify  # The actual work
  end
end
```

**Naming Convention:**
- `*_later` — enqueues the job
- `*_now` — synchronous version
- Job class just calls the `_now` method

---

### 9. Multi-Tenancy Without Complexity

**The Belief:** URL-based tenancy is simpler than subdomains and just as effective.

**In Practice:**
- Tenant ID in URL path: `/123456/boards/...`
- `Current.account` for request-scoped context
- `belongs_to :account, default: -> { Current.account }`
- Job context serialization automatically

**Why Not Subdomains:**
- Simpler local development
- No wildcard SSL certificates
- Easier testing
- Works behind load balancers

---

### 10. Readability Over Cleverness

**The Belief:** Code is read far more often than written. Optimize for the reader.

**In Practice:**
- Expanded conditionals over guard clauses
- Methods ordered by invocation flow
- Intention-revealing names
- No metaprogramming for its own sake

**Example:**
```ruby
# Clever but hard to read
def process
  return unless valid?
  return if processed?
  do_processing
end

# Clear and readable
def process
  if valid? && !processed?
    do_processing
  end
end
```

---

## Decision Framework

When facing a design choice, ask these questions in order:

### 1. Does Rails Already Solve This?
If yes, use Rails. Don't add abstractions.

### 2. Can This Be a Concern?
Shared behavior → concern. Not a service.

### 3. Can This Be a Resource?
Non-CRUD action → model it as a resource with CRUD.

### 4. Where Does This Logic Belong?
- Data manipulation → Model
- HTTP concerns → Controller
- Presentation → View/Helper
- Async execution → Job (that calls model)

### 5. Am I Adding Accidental Complexity?
If the abstraction doesn't pay for itself immediately, don't add it.

---

## Anti-Patterns to Avoid

| Anti-Pattern | What to Do Instead |
|--------------|---------------------|
| Service objects for simple operations | Direct model calls |
| Repository pattern | ActiveRecord directly |
| Presenters/Decorators everywhere | Helpers and partials |
| Form objects for simple forms | Strong parameters |
| Command pattern | Model methods |
| Event sourcing | Simple callbacks |
| Microservices | Monolith (really) |
| Redis for everything | Solid Stack |
| SPA frontend | Hotwire |
| GraphQL | REST/JSON/Turbo |

---

## When Exceptions Are OK

These principles aren't religious doctrine. Break them when:

1. **Form Objects** — For complex multi-model forms with custom validation
2. **Query Objects** — For genuinely complex reporting queries
3. **Service Objects** — For coordinating external services (payments, etc.)
4. **Presenters** — For complex view logic spanning multiple models

But these should be rare. Most apps don't need them.

---

## The Tacit Knowledge

### "Look for Similar Code"
> "When writing new code, unless you are very familiar with our approach, try to find similar code elsewhere to look for inspiration."

Before writing new code, grep the codebase for similar patterns. Consistency matters more than theoretical correctness.

### "We Love Discussing Code"
> "If you have questions about how to write something, or if you detect some smell you are not quite sure how to solve, please ask away."

When uncertain, ask. A PR is a great place for this discussion.

### "How Code Makes You Feel"
> "We care about how code reads, how code looks, and how code makes you feel when you read it."

If code feels wrong, it probably is. Trust your instincts, then articulate why.

### The High Bar
> "We deliberately set a high bar for every code change anyone contributes."

Every line of code is reviewed. Quality isn't optional.

---

## Summary

| Principle | Manifestation |
|-----------|---------------|
| Vanilla Rails | No unnecessary abstractions |
| Model is Domain | Rich models, thin controllers |
| REST Everything | Resources over custom actions |
| Concerns Over Services | Composition through modules |
| Solid Stack | Database over Redis |
| Hotwire First | Server-rendered HTML |
| Convention | Follow Rails patterns |
| Shallow Jobs | Delegate to models |
| Simple Multi-Tenancy | URL-based with Current |
| Readability | Clear over clever |

**Source:** Patterns extracted from the Fizzy codebase, [STYLE.md](STYLE.md), and [Vanilla Rails Is Plenty](https://dev.37signals.com/vanilla-rails-is-plenty/)
