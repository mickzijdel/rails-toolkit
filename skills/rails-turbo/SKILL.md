---
name: rails-turbo
description: Use when implementing Turbo Frames, Streams, broadcasting, and view transitions in Rails
---

# Rails Turbo Patterns

## Pattern 1: Turbo Stream Flash Messages

The standard flash doesn't render in Turbo Stream responses (no full page render). A `TurboFlash` concern provides a helper that replaces the flash area as a stream action:

```ruby
# app/controllers/concerns/turbo_flash.rb
module TurboFlash
  extend ActiveSupport::Concern

  included do
    helper_method :turbo_stream_flash
  end

  private
    def turbo_stream_flash(**flash_options)
      turbo_stream.replace(:flash, partial: "layouts/shared/flash", locals: { flash: flash_options })
    end
end
```

```erb
<%# app/views/layouts/shared/_flash.html.erb %>
<%= turbo_frame_tag :flash do %>
  <% if notice = flash[:notice] || flash[:alert] %>
    <div class="flash" data-controller="element-removal" data-action="animationend->element-removal#remove">
      <div class="flash__inner shadow"><%= notice %></div>
    </div>
  <% end %>
<% end %>
```

```erb
<%# usage in a turbo_stream.erb template %>
<%= turbo_stream_flash(notice: "Card saved successfully") %>
<%= turbo_stream.replace(@card) %>
```

---

## Pattern 2: Multiple Format Responses

Turbo sends requests with the `text/vnd.turbo-stream.html` Accept header, so `format.turbo_stream` in a `respond_to` block picks up the matching `.turbo_stream.erb` template automatically. The full multi-format pattern (HTML/JSON/Turbo Stream conventions) lives in [[rails-controllers]] Pattern 7.

---

## Pattern 3: Broadcasting from Models

`broadcasts_refreshes` in a model concern broadcasts page refreshes to connected clients when records change; `broadcasts_refreshes_to` targets custom streams.

```ruby
# app/models/board/broadcastable.rb
module Board::Broadcastable
  extend ActiveSupport::Concern

  included do
    broadcasts_refreshes
    broadcasts_refreshes_to ->(board) { [ board.account, :all_boards ] }
  end
end
```

```erb
<%# subscribe in the view %>
<% turbo_exempts_page_from_cache %>
<%= turbo_stream_from @board %>

<%# custom stream target %>
<%= turbo_stream_from [ Current.account, :all_boards ] %>
```

---

## Pattern 4: View Transitions on Refresh

View transitions glitch when the page is refreshed (same-URL navigation) — the animation isn't needed there. Detect refreshes and let the layout skip the meta tag:

```ruby
# app/controllers/concerns/view_transitions.rb
# FIXME: Upstream this fix to turbo-rails
module ViewTransitions
  extend ActiveSupport::Concern

  included do
    before_action :disable_view_transitions, if: :page_refresh?
  end

  private
    def disable_view_transitions
      @disable_view_transition = true
    end

    def page_refresh?
      request.referrer.present? && request.referrer == request.url
    end
end
```

```erb
<%# layout head %>
<% unless @disable_view_transition %>
  <meta name="view-transition" content="same-origin">
<% end %>
```

---

## Pattern 5: Lazy-Loaded Frames & Dialog Integration

Defer dialog/menu content with `turbo_frame_tag ... src:, loading: :lazy`, and wire the dialog's Turbo events through a Stimulus controller:

```erb
<div class="position-relative" data-controller="dialog"
      data-action="keydown.esc->dialog#close click@document->dialog#closeOnClickOutside mouseenter->dialog#loadLazyFrames">
  <button data-action="click->dialog#open:stop">
    <%= icon_tag "tag" %>
  </button>

  <dialog class="popup panel" data-dialog-target="dialog"
      data-action="turbo:before-morph-attribute->dialog#preventCloseOnMorphing turbo:submit-end->dialog#close">
    <%= turbo_frame_tag card, :tagging, src: new_card_tagging_path(card), loading: :lazy, refresh: :morph %>
  </dialog>
</div>
```

**Key attributes and handlers:**
- `loading: :lazy` — defers loading until the frame is visible
- `refresh: :morph` — morphing updates preserve state inside the frame
- `target: "_top"` — links inside navigate the whole page, not just the frame
- `mouseenter->dialog#loadLazyFrames` — start loading on hover, before the click
- `turbo:submit-end->dialog#close` — close after successful form submission
- `turbo:before-morph-attribute->dialog#preventCloseOnMorphing` — keep open dialogs open through page morphs

---

## Pattern 6: Turbo Stream Templates

`.turbo_stream.erb` templates update multiple page regions after an action with `replace`, `append`, `prepend`, `before`, `after`, `update`, and `remove`. DOM IDs can be arrays — `[ @card, :new_comment ]` → `card_123_new_comment`.

```erb
<%# create.turbo_stream.erb — insert the comment, reset the form %>
<%= turbo_stream.before [ @card, :new_comment ], partial: "cards/comments/comment", locals: { comment: @comment } %>
<%= turbo_stream.update [ @card, :new_comment ], partial: "cards/comments/new", locals: { card: @card } %>

<%# destroy.turbo_stream.erb %>
<%= turbo_stream.remove [ @comment, :container ] %>

<%# pagination with append %>
<%= turbo_stream.append :notifications_list_read, partial: "notifications/notification", collection: @page.records %>
<%= turbo_stream.replace :next_page, notifications_next_page_link(@page) %>
```

---

## Pattern 7: Morphing Updates

`replace` destroys and recreates DOM elements, losing focus and scroll state. `method: :morph` diffs instead, updating only what changed:

```erb
<%# update.turbo_stream.erb %>
<%= turbo_stream.replace dom_id(@card, :card_container), partial: "cards/container", method: :morph, locals: { card: @card.reload } %>

<% if @source_column %>
  <%= turbo_stream.replace(dom_id(@source_column), partial: "boards/show/column", method: :morph, locals: { column: @source_column }) %>
<% end %>
```

```ruby
# Controller helper for inline morph replacement
def render_card_replacement
  render turbo_stream: turbo_stream.replace([ @card, :card_container ], partial: "cards/container", method: :morph, locals: { card: @card.reload })
end
```

---

## Pattern 8: Preventing Cache on Dynamic Pages

Turbo caches pages for back/forward navigation; pages that subscribe to broadcasts go stale in that cache. Exempt them:

```erb
<%# app/views/boards/show.html.erb %>
<% turbo_exempts_page_from_cache %>
<%= turbo_stream_from @board %>
```

---

## Pattern 9: Frame Content Preservation

Mark elements that must survive morphs and refreshes (focused form inputs, video players) with `data-turbo-permanent`:

```erb
<div data-turbo-permanent>
  <%= turbo_frame_tag card, :edit do %>
    <%= render "cards/container/content_display", card: card %>
  <% end %>
</div>
```
