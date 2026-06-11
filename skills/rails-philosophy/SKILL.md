---
name: rails-philosophy
description: Core philosophies, design choices, and tacit knowledge underpinning 37signals-style Rails development
---

# Rails Philosophy

The foundational principles behind this style of Rails development, distilled from 37signals/Basecamp's approach.

> "We aim to write code that is a pleasure to read, and we have a lot of opinions about how to do it well. We care about how code reads, how code looks, and how code makes you feel when you read it."

---

## The Principles

### 1. Vanilla Rails Is Plenty

**The Belief:** Rails provides everything you need. Resist the urge to add layers of abstraction: no service objects wrapping simple operations, no repository pattern over ActiveRecord, no CQRS for typical apps, no dependency injection containers.

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

### 2. The Model Is the Domain

**The Belief:** ActiveRecord models aren't just database wrappers — they ARE your domain. Business logic lives in models with intention-revealing public APIs (`card.gild`, `card.close`); controllers invoke model methods, they don't orchestrate operations. See [[rails-controllers]] Pattern 8.

### 3. REST Everything

**The Belief:** Every operation can be modeled as CRUD on a resource. This isn't limiting — it's clarifying. State changes become resources: `POST /cards/:id/close` → `POST /cards/:id/closure`; reopen → `DELETE /cards/:id/closure`.

**Why It Works:** consistent mental model, standard HTTP semantics, easier caching (resources have URLs), clear controller responsibilities. The routing pattern lives in [[rails-controllers]] Pattern 3.

### 4. Concerns Over Services

**The Belief:** Composition through concerns is more natural in Rails than service objects. Concerns extend the class rather than wrap it — no indirection, the behavior IS on the model, and testing means testing the model directly. Shared behavior goes in `app/models/concerns/` (Eventable, Searchable); model-specific behavior in namespaced concerns (`Card::Closeable`). Structure and template-method patterns: [[rails-models]].

### 5. Database-Backed Everything (Solid Stack)

**The Belief:** You probably don't need Redis. **Solid Queue** for jobs, **Solid Cache** for caching, **Solid Cable** for WebSockets; SQLite for small deployments, MySQL for scale.

**Why It Works:** one less service to operate, transactions across jobs and data, ACID guarantees. The trade-off — slightly higher pub/sub latency for simpler operations — is right for most apps. Setup: [[rails-project-setup]].

### 6. Server-Rendered First (Hotwire)

**The Belief:** HTML over the wire beats JSON APIs for most web applications. Turbo Drive for navigation, Frames for partial updates, Streams for real-time, Stimulus for sprinkles. No SPA.

**Why It Works:** less JavaScript to maintain, server controls the state, progressive enhancement built-in, faster initial render. See [[rails-turbo]] and [[rails-stimulus]].

### 7. Convention Over Configuration (Really)

**The Belief:** Follow Rails conventions even when they feel "limiting." When to break convention: almost never. If you're fighting Rails, you're probably wrong.

### 8. Shallow Jobs, Rich Models

**The Belief:** Background jobs are just async method calls. The job class is a shell that calls a model method; `*_later` enqueues, `*_now` is the synchronous version. See [[rails-jobs]] Patterns 1 and 3.

### 9. Multi-Tenancy Without Complexity

**The Belief:** URL-based tenancy (`/123456/boards/...` + `Current.account`) is simpler than subdomains and just as effective: simpler local development, no wildcard SSL, easier testing, works behind load balancers. Implementation: [[rails-multi-tenancy]].

### 10. Readability Over Cleverness

**The Belief:** Code is read far more often than written. Expanded conditionals over guard clauses, methods ordered by invocation flow, intention-revealing names, no metaprogramming for its own sake.

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

When facing a design choice, ask in order:

1. **Does Rails already solve this?** If yes, use Rails. Don't add abstractions.
2. **Can this be a concern?** Shared behavior → concern. Not a service.
3. **Can this be a resource?** Non-CRUD action → model it as a resource with CRUD.
4. **Where does this logic belong?** Data manipulation → Model. HTTP → Controller. Presentation → View/Helper. Async → Job (that calls a model).
5. **Am I adding accidental complexity?** If the abstraction doesn't pay for itself immediately, don't add it.

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

These principles aren't religious doctrine. Break them for:

1. **Form Objects** — complex multi-model forms with custom validation
2. **Query Objects** — genuinely complex reporting queries
3. **Service Objects** — coordinating external services (payments, etc.)
4. **Presenters** — complex view logic spanning multiple models

But these should be rare. Most apps don't need them.

---

## The Tacit Knowledge

- **"Look for similar code."** Before writing new code, grep the codebase for similar patterns. Consistency matters more than theoretical correctness.
- **"We love discussing code."** When uncertain, ask — a PR is a great place for the discussion.
- **"How code makes you feel."** If code feels wrong, it probably is. Trust your instincts, then articulate why.
- **The high bar.** Every line of code is reviewed. Quality isn't optional.
