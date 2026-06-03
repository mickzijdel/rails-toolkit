---
name: rails-viewcomponents
description: Use when creating, extracting, or refactoring ViewComponents in a Rails app — including slot design, component API, testing, and when to extract vs keep as partials
---

# Rails ViewComponents

## Overview

ViewComponents are Ruby objects that render HTML. Think of them as "ActiveRecord for UI" — they bring testability, explicit interfaces, and reuse to view code that would otherwise be scattered across partials.

## When to Use

- Replacing a partial that has grown logic or conditional rendering
- A UI pattern appears in 3+ places (three-instance rule before extracting)
- The view needs unit-testable behaviour
- You want an explicit, typed interface instead of implicit local assigns

**Keep as a partial when:** it's simple, single-use, and has no logic.

## Component Types

| Type | Purpose | Example |
|------|---------|---------|
| **General-purpose** | Reusable UI pattern | `ButtonComponent`, `CardComponent` |
| **Domain-specific** | Wraps a model into a general component | `User::AvatarComponent` → `DesignSystem::AvatarComponent` |

Extract general-purpose components only after they're proven useful in multiple contexts — "good frameworks are extracted, not invented."

## File Structure

```
app/components/
  button_component.rb
  button_component.html.erb
  user/
    avatar_component.rb
    avatar_component.html.erb
```

## Defining a Component

```ruby
class ButtonComponent < ViewComponent::Base
  def initialize(label:, variant: :primary, disabled: false)
    @label = label
    @variant = variant
    @disabled = disabled
  end

  private

  def css_classes
    ["btn", "btn-#{@variant}", ("disabled" if @disabled)].compact.join(" ")
  end
end
```

```erb
<%# button_component.html.erb %>
<button class="<%= css_classes %>">
  <%= @label %>
</button>
```

**Rules:**
- Mark all instance methods `private` — they're still accessible in the template
- Never put logic inline in the template; push it into instance methods
- Avoid coupling to global state (request params, `Current`, URLs) — pass everything via the constructor
- Use `-Component` suffix in class name

## Slots

Slots let callers inject structured content. Prefer slots over passing HTML strings (which bypass Rails sanitisation).

```ruby
class CardComponent < ViewComponent::Base
  renders_one :header
  renders_one :footer
  renders_many :actions, ActionComponent
end
```

```erb
<%# card_component.html.erb %>
<div class="card">
  <% if header? %>
    <div class="card-header"><%= header %></div>
  <% end %>
  <div class="card-body"><%= content %></div>
  <% if actions? %>
    <div class="card-actions">
      <% actions.each { |a| concat(a) } %>
    </div>
  <% end %>
</div>
```

Caller:

```erb
<%= render CardComponent.new do |c| %>
  <% c.with_header { "My Title" } %>
  <% c.with_action(label: "Save") %>
<% end %>
```

**Slot rules:**
- `renders_one` — at most one instance
- `renders_many` — zero or more; iterate in the template
- Always guard with `header?` / `actions?` predicate before rendering
- Use block (`with_*`) syntax, not string arguments, for HTML content
- Lambda slots are fine for trivial wrapping; extract to a component when they grow

## Composition over Inheritance

Never subclass a component to vary behaviour. Wrap it instead:

```ruby
# Bad
class DangerButtonComponent < ButtonComponent; end

# Good
class DangerButtonComponent < ViewComponent::Base
  def initialize(label:)
    @button = ButtonComponent.new(label:, variant: :danger)
  end
end
```

## Testing

```ruby
class ButtonComponentTest < ViewComponent::TestCase
  def test_renders_label
    render_inline(ButtonComponent.new(label: "Save"))
    assert_text "Save"
  end

  def test_disabled_state
    render_inline(ButtonComponent.new(label: "Save", disabled: true))
    assert_selector "button.disabled"
  end
end
```

Testing slots:

```ruby
def test_card_with_header
  render_inline(CardComponent.new).tap do |c|
    c.with_header { "Hello" }
  end
  assert_selector ".card-header", text: "Hello"
end
```

**Rules:**
- Test rendered output, not instance methods
- Use `assert_selector` / `assert_text` (Capybara matchers)
- `assert_selector` hides invisible elements by default — pass `visible: false` for hidden content
- Don't assert on private method return values

## Quick Reference

| Task | Pattern |
|------|---------|
| Define argument | `def initialize(foo:, bar: nil)` |
| Single slot | `renders_one :header` |
| Repeating slot | `renders_many :items, ItemComponent` |
| Slot with component | `renders_one :icon, IconComponent` |
| Check slot presence | `header?`, `items?` |
| Render slot | `<%= header %>` / `<% items.each { \|i\| concat(i) } %>` |
| Caller sets slot | `c.with_header { "text" }` |
| Private helper | `private def css_classes = ...` |

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Passing HTML strings to slots | Use block syntax: `c.with_header { "<b>text</b>".html_safe }` |
| Inheriting to vary style | Compose — pass a wrapper or different arguments |
| Reading `params` / `Current` inside component | Inject via constructor |
| Asserting instance methods in tests | Assert rendered HTML output |
| Extracting on first use | Wait for the third instance before generalising |
| Logic inline in `.erb` | Move to a private instance method |
