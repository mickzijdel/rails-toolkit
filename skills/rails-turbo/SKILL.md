---
name: rails-turbo
description: Use when implementing Turbo Frames, Streams, broadcasting, and view transitions in Rails
---

# Rails Turbo Patterns

## When to Use
- Adding real-time updates to pages
- Using Turbo Frames for partial page updates
- Broadcasting changes to multiple clients
- Implementing flash messages in Turbo Stream responses
- Building lazy-loading dialogs and menus
- Morphing DOM updates for smoother UX

---

## Pattern 1: Turbo Stream Flash Messages

### Problem
When responding with Turbo Streams, the standard Rails flash mechanism does not work because there is no full page render.

### Solution
Create a `TurboFlash` concern that provides a helper method to render flash messages as a Turbo Stream replacement.

### Example

**Concern** - `app/controllers/concerns/turbo_flash.rb`:
```ruby
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

**Flash partial** - `app/views/layouts/shared/_flash.html.erb`:
```erb
<%= turbo_frame_tag :flash do %>
  <% if notice = flash[:notice] || flash[:alert] %>
    <div class="flash" data-controller="element-removal" data-action="animationend->element-removal#remove">
      <div class="flash__inner shadow">
        <%= notice %>
      </div>
    </div>
  <% end %>
<% end %>
```

**Include in ApplicationController** - `app/controllers/application_controller.rb`:
```ruby
class ApplicationController < ActionController::Base
  include TurboFlash, ViewTransitions
  # ...
end
```

**Usage in a turbo_stream.erb template**:
```erb
<%= turbo_stream_flash(notice: "Card saved successfully") %>
<%= turbo_stream.replace(@card) %>
```

---

## Pattern 2: Multiple Format Responses

### Problem
Controllers need to handle both Turbo Stream responses for AJAX updates and HTML/JSON for traditional requests and API clients.

### Solution
Use `respond_to` blocks with `format.turbo_stream`, `format.html`, and `format.json` to handle all cases. Turbo automatically sends requests with the `text/vnd.turbo-stream.html` Accept header.

### Example

**Controller** - `app/controllers/cards_controller.rb`:
```ruby
class CardsController < ApplicationController
  def update
    @card.update! card_params

    respond_to do |format|
      format.turbo_stream
      format.json { render :show }
    end
  end

  def destroy
    @card.destroy!

    respond_to do |format|
      format.html { redirect_to @card.board, notice: "Card deleted" }
      format.json { head :no_content }
    end
  end
end
```

**Comments controller** - `app/controllers/cards/comments_controller.rb`:
```ruby
class Cards::CommentsController < ApplicationController
  def create
    @comment = @card.comments.create!(comment_params)

    respond_to do |format|
      format.turbo_stream
      format.json { head :created, location: card_comment_path(@card, @comment, format: :json) }
    end
  end

  def update
    @comment.update! comment_params

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  def destroy
    @comment.destroy

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
```

**Closures controller** - `app/controllers/cards/closures_controller.rb`:
```ruby
class Cards::ClosuresController < ApplicationController
  def create
    capture_card_location
    @card.close
    refresh_stream_if_needed

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
```

---

## Pattern 3: Broadcasting from Models

### Problem
When a model changes, all connected clients viewing that model should receive real-time updates.

### Solution
Use `broadcasts_refreshes` in model concerns to automatically broadcast page refreshes when records change. Use `broadcasts_refreshes_to` for custom stream targets.

### Example

**Card broadcasting** - `app/models/card/broadcastable.rb`:
```ruby
module Card::Broadcastable
  extend ActiveSupport::Concern

  included do
    broadcasts_refreshes

    before_update :remember_if_preview_changed
  end

  private
    def remember_if_preview_changed
      @preview_changed ||= title_changed? || column_id_changed? || board_id_changed?
    end

    def preview_changed?
      @preview_changed
    end
end
```

**Board broadcasting with multiple streams** - `app/models/board/broadcastable.rb`:
```ruby
module Board::Broadcastable
  extend ActiveSupport::Concern

  included do
    broadcasts_refreshes
    broadcasts_refreshes_to ->(board) { [ board.account, :all_boards ] }
  end
end
```

**Subscribing to broadcasts in views** - `app/views/boards/show.html.erb`:
```erb
<% turbo_exempts_page_from_cache %>
<%= turbo_stream_from @board %>
```

**Multiple board subscriptions** - `app/views/cards/_broadcasts.html.erb`:
```erb
<% if filter.boards.any? %>
  <% filter.boards.each do |board| %>
    <%= turbo_stream_from board %>
  <% end %>
<% else %>
  <%= turbo_stream_from [ Current.account, :all_boards ] %>
<% end %>
```

---

## Pattern 4: View Transitions on Refresh

### Problem
View transitions can cause visual glitches when the page is being refreshed (same URL navigation). The transition animation is not needed in this case.

### Solution
Create a `ViewTransitions` concern that detects page refreshes and disables view transitions by setting an instance variable that the layout checks.

### Example

**Concern** - `app/controllers/concerns/view_transitions.rb`:
```ruby
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

**Layout head partial** - `app/views/layouts/shared/_head.html.erb`:
```erb
<head>
  <%= page_title_tag %>

  <meta name="viewport" content="width=device-width, initial-scale=1">
  <% unless @disable_view_transition %>
    <meta name="view-transition" content="same-origin">
  <% end %>
  <!-- rest of head -->
</head>
```

**Include in ApplicationController** - `app/controllers/application_controller.rb`:
```ruby
class ApplicationController < ActionController::Base
  include TurboFlash, ViewTransitions
end
```

---

## Pattern 5: Turbo Frame Lazy Loading

### Problem
Loading content for dialogs and menus upfront wastes bandwidth. Content should only load when the user interacts with the element.

### Solution
Use `turbo_frame_tag` with `loading: :lazy` and `src:` to defer loading until the frame becomes visible. Trigger loading on hover using a Stimulus controller action.

### Example

**Lazy-loaded dialog for tags** - `app/views/cards/display/perma/_tags.html.erb`:
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

**Lazy-loaded assignee picker** - `app/views/cards/display/perma/_assignees.html.erb`:
```erb
<%= render "cards/display/common/assignees", card: card do %>
  <%= turbo_frame_tag card, :assignment, src: new_card_assignment_path(card), loading: :lazy, refresh: "morph" %>
<% end %>
```

**Lazy-loaded board picker** - `app/views/cards/display/perma/_board.html.erb`:
```erb
<dialog class="popup panel" data-dialog-target="dialog"
    data-action="turbo:before-morph-attribute->dialog#preventCloseOnMorphing turbo:submit-end->dialog#close">
  <%= turbo_frame_tag "board_picker", src: edit_card_board_path(card), target: "_top", loading: :lazy, refresh: "morph" %>
</dialog>
```

**Lazy-loaded menu** - `app/views/my/_menu.html.erb`:
```erb
<%= turbo_frame_tag "my_menu", src: my_menu_path, loading: :lazy, target: "_top" do %>
  <% # Passing empty block to avoid double-render %>
  <%= render("my/menus/jump") { } %>
<% end %>
```

Key attributes:
- `loading: :lazy` - Defers loading until visible
- `refresh: :morph` - Uses morphing for updates (preserves state)
- `target: "_top"` - Links inside navigate the whole page, not just the frame

---

## Pattern 6: Turbo Stream Templates

### Problem
After form submissions or AJAX actions, you need to update multiple parts of the page without a full reload.

### Solution
Create `.turbo_stream.erb` view templates that use `turbo_stream` helpers to perform DOM operations like `replace`, `append`, `prepend`, `before`, `after`, `update`, and `remove`.

### Example

**Create comment** - `app/views/cards/comments/create.turbo_stream.erb`:
```erb
<%= turbo_stream.before [ @card, :new_comment ], partial: "cards/comments/comment", locals: { comment: @comment } %>

<%= turbo_stream.update [ @card, :new_comment ], partial: "cards/comments/new", locals: { card: @card } %>
```

**Update comment** - `app/views/cards/comments/update.turbo_stream.erb`:
```erb
<%= turbo_stream.replace [ @comment, :container ], partial: "cards/comments/comment", locals: { comment: @comment } %>
```

**Delete comment** - `app/views/cards/comments/destroy.turbo_stream.erb`:
```erb
<%= turbo_stream.remove [ @comment, :container ] %>
```

**Notification read** - `app/views/notifications/readings/create.turbo_stream.erb`:
```erb
<%= turbo_stream.remove @notification %>
<%= turbo_stream.prepend :notifications_list_read, partial: "notifications/notification", locals: { notification: @notification } %>
```

**Pagination with append** - `app/views/notifications/index.turbo_stream.erb`:
```erb
<%= turbo_stream.append :notifications_list_read, partial: "notifications/notification", collection: @page.records %>
<%= turbo_stream.replace :next_page, notifications_next_page_link(@page) %>
```

**Create step** - `app/views/cards/steps/create.turbo_stream.erb`:
```erb
<%= turbo_stream.before dom_id(@card, :new_step) do %>
  <%= render "cards/steps/step", step: @step %>
<% end %>
```

DOM IDs can use arrays like `[ @card, :new_comment ]` which generates IDs like `card_123_new_comment`.

---

## Pattern 7: Morphing Updates

### Problem
Regular `replace` operations destroy and recreate DOM elements, losing focus, scroll position, and other state. This creates a jarring user experience.

### Solution
Use `method: :morph` with `turbo_stream.replace` to perform intelligent DOM diffing that updates only changed attributes and content while preserving element identity.

### Example

**Card update with morph** - `app/views/cards/update.turbo_stream.erb`:
```erb
<%= turbo_stream.replace dom_id(@card, :card_container), partial: "cards/container", method: :morph, locals: { card: @card.reload } %>

<%= turbo_stream.update dom_id(@card, :edit) do %>
  <%= render "cards/container/content_display", card: @card %>
<% end %>

<%= turbo_stream.replace dom_id(@card, :card_closure_toggle) do %>
  <%= render "cards/container/closure", card: @card %>
<% end %>
```

**Close card with morph** - `app/views/cards/closures/create.turbo_stream.erb`:
```erb
<%= turbo_stream.replace("closed-cards", partial: "boards/show/closed", method: :morph, locals: { board: @card.board }) %>

<% if @source_column %>
  <%= turbo_stream.replace(dom_id(@source_column), partial: "boards/show/column", method: :morph, locals: { column: @source_column }) %>
<% elsif @was_in_stream %>
  <%= turbo_stream.replace("the-stream", partial: "boards/show/stream", method: :morph, locals: { board: @card.board, page: @page }) %>
<% end %>

<%= turbo_stream.replace([ @card, :card_container ], partial: "cards/container", method: :morph, locals: { card: @card.reload }) %>
```

**Reopen card with morph** - `app/views/cards/closures/destroy.turbo_stream.erb`:
```erb
<%= turbo_stream.replace("closed-cards", partial: "boards/show/closed", method: :morph, locals: { board: @card.board }) %>

<% if @card.column %>
  <%= turbo_stream.replace(dom_id(@card.column), partial: "boards/show/column", method: :morph, locals: { column: @card.column }) %>
<% elsif @card.awaiting_triage? %>
  <%= turbo_stream.replace("the-stream", partial: "boards/show/stream", method: :morph, locals: { board: @card.board, page: @page }) %>
<% end %>

<%= turbo_stream.replace([ @card, :card_container ], partial: "cards/container", method: :morph, locals: { card: @card.reload }) %>
```

**Refresh adjacent columns** - `app/views/columns/_refresh_adjacent_columns.turbo_stream.erb`:
```erb
<% column.adjacent_columns.each do |adjacent_column| %>
  <%= turbo_stream.replace(dom_id(adjacent_column), partial: "boards/show/column", method: :morph, locals: { column: adjacent_column }) %>
<% end %>
```

**Controller helper for inline morph** - `app/controllers/concerns/card_scoped.rb`:
```ruby
module CardScoped
  private
    def render_card_replacement
      render turbo_stream: turbo_stream.replace([ @card, :card_container ], partial: "cards/container", method: :morph, locals: { card: @card.reload })
    end
end
```

---

## Pattern 8: Preventing Cache on Dynamic Pages

### Problem
Turbo caches pages for faster back/forward navigation, but pages with real-time updates can become stale.

### Solution
Use `turbo_exempts_page_from_cache` at the top of views that subscribe to broadcasts or have frequently changing content.

### Example

**Board show page** - `app/views/boards/show.html.erb`:
```erb
<% @page_title = @board.name %>
<% turbo_exempts_page_from_cache %>

<%= turbo_stream_from @board %>

<%= turbo_frame_tag :cards_container do %>
  <!-- board content -->
<% end %>
```

**Cards index** - `app/views/cards/index.html.erb`:
```erb
<% @page_title = @user_filtering.selected_boards_label %>
<% turbo_exempts_page_from_cache %>

<%= render "cards/broadcasts", filter: @filter %>
```

---

## Pattern 9: Frame Content Preservation

### Problem
When morphing or refreshing pages, certain elements should not be replaced (e.g., form inputs with focus, video players).

### Solution
Use `data-turbo-permanent` attribute on elements that should be preserved across page updates.

### Example

**Permanent content wrapper** - `app/views/cards/container/_content.html.erb`:
```erb
<% if card.published? %>
  <div data-turbo-permanent>
  <%= turbo_frame_tag card, :edit do %>
    <%# When canceling an edit, restore the button area %>
    <%= turbo_stream.replace dom_id(card, :card_closure_toggle) do %>
      <%= render "cards/container/closure", card: card %>
    <% end %>

    <%= render "cards/container/content_display", card: card %>
  <% end %>
  </div>
<% end %>
```

---

## Pattern 10: Dialog Integration with Turbo

### Problem
Dialogs need to handle Turbo events properly: close on form submission, load lazy content on hover, prevent morphing from disrupting open dialogs.

### Solution
Use Stimulus controller actions to handle Turbo events on dialog elements.

### Example

**Dialog with Turbo event handlers** - `app/views/cards/display/perma/_tags.html.erb`:
```erb
<div data-controller="dialog"
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

Key event handlers:
- `turbo:submit-end->dialog#close` - Close dialog after successful form submission
- `turbo:before-morph-attribute->dialog#preventCloseOnMorphing` - Prevent morph from closing dialog
- `mouseenter->dialog#loadLazyFrames` - Trigger lazy frame loading on hover
