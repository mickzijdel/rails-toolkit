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

Make the component the **single source of truth** for its styling: keep the class map in a
constant and resolve it through one method — never scatter `btn btn-*` shims across views.

```ruby
class ButtonComponent < ViewComponent::Base
  VARIANT_CLASSES = {
    primary:   "bg-blue-600 text-white hover:bg-blue-700",
    secondary: "bg-gray-200 text-gray-900 hover:bg-gray-300",
    danger:    "bg-red-600 text-white hover:bg-red-700"
  }.freeze
  SIZE_CLASSES = { sm: "px-2 py-1 text-sm", md: "px-3 py-2", lg: "px-5 py-3 text-lg" }.freeze

  # Class method so OTHER components' templates (which don't get view helpers)
  # can reuse the styling without instantiating a ButtonComponent.
  def self.classes_for(variant: :primary, size: :md)
    [ "btn-base", VARIANT_CLASSES.fetch(variant), SIZE_CLASSES.fetch(size) ].join(" ")
  end

  def initialize(label:, variant: :primary, size: :md, disabled: false)
    @label = label
    @variant = variant
    @size = size
    @disabled = disabled
  end

  private

  def css_classes
    [ self.class.classes_for(variant: @variant, size: @size), ("opacity-50" if @disabled) ].compact.join(" ")
  end
end
```

```erb
<%# button_component.html.erb %>
<button class="<%= css_classes %>"<%= " disabled".html_safe if @disabled %>>
  <%= @label %>
</button>
```

To change a colour or add a variant, edit **only** `VARIANT_CLASSES` — that's the whole point
of the single-source-of-truth pattern.

**Rules:**
- Mark all instance methods `private` — they're still accessible in the template
- Never put logic inline in the template; push it into instance methods
- Avoid coupling to global state (request params, `Current`, URLs) — pass everything via the constructor
- Use `-Component` suffix in class name
- **If the app supports dark mode, style both modes.** Every new view or component needs light *and* dark styling (Tailwind `dark:` variants) — check an existing component for the app's convention before shipping a light-only one.
- **ViewComponents do not auto-include view helpers.** Inside a component template you can't call app helpers (`btn_classes`, `get_link`, etc.) — those exist only in regular views. When one component needs another's styling, expose it as a **class method** (`ButtonComponent.classes_for(...)`) and call that instead.

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

## Previews

**Every component needs a preview.** Generate a `*_component_preview.rb` alongside the
component — many projects have a lint cop that fails the build for a component without one,
and previews double as living documentation in the ViewComponent UI / Lookbook.

```ruby
# test/components/previews/button_component_preview.rb
class ButtonComponentPreview < ViewComponent::Preview
  def primary
    render ButtonComponent.new(label: "Save")
  end

  def danger
    render ButtonComponent.new(label: "Delete", variant: :danger)
  end

  def disabled
    render ButtonComponent.new(label: "Save", disabled: true)
  end
end
```

- One public method per state/variant you want to showcase.
- Keep previews in the configured preview path (commonly `test/components/previews/`).
- Add the preview in the same commit as the component so the cop stays green.

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
| Reuse styling across components | `def self.classes_for(variant:, size:) = ...` |
| Preview a component | `test/components/previews/x_component_preview.rb` |

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Passing HTML strings to slots | Use block syntax: `c.with_header { "<b>text</b>".html_safe }` |
| Inheriting to vary style | Compose — pass a wrapper or different arguments |
| Reading `params` / `Current` inside component | Inject via constructor |
| Asserting instance methods in tests | Assert rendered HTML output |
| Extracting on first use | Wait for the third instance before generalising |
| Logic inline in `.erb` | Move to a private instance method |
| Calling a view helper inside a component template | Helpers aren't auto-included — expose a class method like `classes_for` and call that |
| Scattering `btn btn-*` style classes across views | One component owns the class map in a constant; edit only that constant |
| Shipping a component without a preview | Add a `*_component_preview.rb` in the same commit (a lint cop often requires it) |
| Light-only styling in a dark-mode app | Add `dark:` variants alongside every light style |
