---
name: rails-stimulus
description: Use when writing Stimulus controllers with modern JavaScript patterns (ES2022 private fields, values, targets)
---

# Rails Stimulus Patterns

## When to Use
- Creating interactive UI components
- Managing client-side state
- Handling user interactions
- Building reusable JavaScript behaviors

---

## 0. Design Philosophy

**Stimulus is "just sprinkles"** — Turbo handles the reactive application layer. Stimulus covers the last 10–20%. Always ask: can CSS alone solve this? Can Turbo handle it? Reach for Stimulus last.

**Build behavior-based controllers, not resource-based ones.** A `ClipboardController` that copies text works everywhere. A `PinsController` with a `copyPIN()` method is dead weight. Think: showing/hiding, focusing inputs, sorting tables, tooltips — not page-specific resources.

**Minimize dependencies.** Modern JS has excellent browser support. Check [youmightnotneedjquery.com](https://youmightnotneedjquery.com) before adding a library. Fewer dependencies = simpler upgrades.

---

## 1. Private Fields (ES2022)

### Problem
You need internal state that should not be accessible from outside the controller or from templates.

### Solution
Use ES2022 private field syntax (`#fieldName`) for internal state, timers, and cached values.

### Example
```javascript
// Source: app/javascript/controllers/auto_save_controller.js
import { Controller } from "@hotwired/stimulus"
import { submitForm } from "helpers/form_helpers"

const AUTOSAVE_INTERVAL = 3000

export default class extends Controller {
  #timer  // Private field for timer reference

  disconnect() {
    this.submit()
  }

  async submit() {
    if (this.#dirty) {
      await this.#save()
    }
  }

  change(event) {
    if (event.target.form === this.element && !this.#dirty) {
      this.#scheduleSave()
    }
  }

  // Private methods using # syntax
  #scheduleSave() {
    this.#timer = setTimeout(() => this.#save(), AUTOSAVE_INTERVAL)
  }

  async #save() {
    this.#resetTimer()
    await submitForm(this.element)
  }

  #resetTimer() {
    clearTimeout(this.#timer)
    this.#timer = null
  }

  // Private getters
  get #dirty() {
    return !!this.#timer
  }
}
```

### Key Points
- Use `#fieldName` for private instance variables
- Use `#methodName()` for private methods
- Use `get #propertyName()` for private getters
- Private fields are truly private (not just convention)

---

## 2. Static Targets and Values

### Problem
You need to reference DOM elements and pass configuration from HTML to your controller.

### Solution
Use static `targets`, `values`, and `classes` declarations with type definitions and defaults.

### Example
```javascript
// Source: app/javascript/controllers/dialog_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "dialog" ]
  static values = {
    modal: { type: Boolean, default: false },
    sizing: { type: Boolean, default: true },
    autoOpen: { type: Boolean, default: false }
  }

  connect() {
    this.dialogTarget.setAttribute("aria-hidden", "true")
    if (this.autoOpenValue) this.open()
  }

  open() {
    if (this.modalValue) {
      this.dialogTarget.showModal()
    } else {
      this.dialogTarget.show()
    }
  }
}
```

```javascript
// Source: app/javascript/controllers/combobox_controller.js
export default class extends Controller {
  static targets = [ "label", "item", "hiddenFieldTemplate" ]
  static values = {
    selectPropertyName: { type: String, default: "aria-checked" },
    defaultValue: String,
    defaultLabel: String
  }
  static classes = ["withDefault"]

  // Use hasDefaultLabelValue to check if value was provided
  get #selectedLabel() {
    if (this.hasDefaultLabelValue && !this.#selectedItemValue()) {
      return this.defaultLabelValue
    }
    return this.#selectedItem?.dataset?.comboboxLabel || ""
  }
}
```

### Key Points
- Always use object syntax for values with defaults: `{ type: Boolean, default: false }`
- Use `hasXxxValue` to check if a value was explicitly provided
- Access values with `this.xxxValue`, targets with `this.xxxTarget`
- For multiple targets, use `this.xxxTargets` (array)

---

## 3. Lifecycle Hooks

### Problem
You need to initialize state when controller connects and clean up when it disconnects.

### Solution
Use `connect()`, `disconnect()`, and `initialize()` lifecycle methods.

**Prefer `data-action` over manual `addEventListener`** — Stimulus handles cleanup automatically and the HTML communicates intent. Manual listeners require remembering to remove them in `disconnect()`.

```html
<!-- ✅ Prefer: Stimulus manages listener lifecycle -->
<details data-controller="menu" data-action="toggle->menu#trapFocus"></details>

<!-- ❌ Avoid: manual addEventListener in connect/disconnect -->
```

### Example
```javascript
// Source: app/javascript/controllers/filter_controller.js
import { Controller } from "@hotwired/stimulus"
import { debounce } from "helpers/timing_helpers"

export default class extends Controller {
  static targets = [ "input", "item" ]

  initialize() {
    // Called once when controller is first instantiated
    this.filter = debounce(this.filter.bind(this), 100)
  }

  filter() {
    this.itemTargets.forEach(item => {
      // Filter logic
    })
    this.dispatch("changed")
  }
}
```

### Key Points
- `initialize()`: Called once when controller is first created (use for method binding/debouncing)
- `connect()`: Called each time controller element is attached to DOM
- `disconnect()`: Called when controller element is removed from DOM (cleanup timers, listeners)
- Always clean up event listeners in `disconnect()` to prevent memory leaks

---

## 4. Action Methods

### Problem
You need to respond to user interactions from HTML `data-action` bindings.

### Solution
Define public methods that receive event objects and handle interactions.

### Example
```javascript
// Source: app/javascript/controllers/toggle_class_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static classes = [ "toggle" ]
  static targets = [ "checkbox" ]

  toggle() {
    this.element.classList.toggle(this.toggleClass)
  }

  add() {
    this.element.classList.add(this.toggleClass)
  }

  remove() {
    this.element.classList.remove(this.toggleClass)
  }

  checkAll() {
    this.checkboxTargets.forEach(checkbox => {
      checkbox.checked = true
    })
  }
}
```

```javascript
// Source: app/javascript/controllers/hotkey_controller.js
export default class extends Controller {
  click(event) {
    if (this.#isClickable && !this.#shouldIgnore(event)) {
      event.preventDefault()
      this.element.click()
    }
  }

  #shouldIgnore(event) {
    return event.defaultPrevented || event.target.closest("input, textarea, lexxy-editor")
  }

  get #isClickable() {
    return getComputedStyle(this.element).pointerEvents !== "none"
  }
}
```

### Key Points
- Public methods are callable via `data-action="controller#method"`
- Use `event.preventDefault()` to stop default browser behavior
- Use `event.stopPropagation()` to prevent event bubbling
- Check `event.defaultPrevented` to avoid handling already-handled events

---

## 5. Custom Events with dispatch()

### Problem
You need to communicate state changes to other controllers or parent elements.

### Solution
Use `this.dispatch()` to emit custom events that bubble up the DOM.

### Example
```javascript
// Source: app/javascript/controllers/dialog_controller.js
export default class extends Controller {
  open() {
    this.dialogTarget.show()
    this.dispatch("show")  // Emits "dialog:show" event
  }

  close() {
    this.dialogTarget.close()
    this.dispatch("close")  // Emits "dialog:close" event
  }
}
```

```javascript
// Source: app/javascript/controllers/filter_controller.js
export default class extends Controller {
  filter() {
    this.itemTargets.forEach(item => {
      // Filter logic
    })
    this.dispatch("changed")  // Emits "filter:changed" event
  }
}
```

### HTML Usage — composing controllers without writing new code
```html
<!-- ClipboardController dispatches "clipboard:copy"; FlashController listens for it -->
<div data-controller="clipboard flash"
     data-action="clipboard:copy->flash#show">
  <input data-clipboard-target="source" value="some text">
  <button data-action="clipboard#copy">Copy</button>
</div>
```

```html
<div data-controller="dialog"
     data-action="dialog:show->other#handleDialogShow dialog:close->other#handleDialogClose">
  <!-- content -->
</div>
```

### Key Points
- `this.dispatch("name")` emits `controllerName:name` event
- Events bubble up the DOM by default
- Can pass data: `this.dispatch("changed", { detail: { count: 5 } })`
- **Compose behaviors in HTML** — wire up existing controllers before building new ones

---

## 6. Wrapping External Libraries

### Problem
You need a third-party library (tippy.js, chart.js, etc.) but don't want it scattered through your HTML.

### Solution
Wrap the library in a Stimulus controller. Swap the library by changing one file.

```javascript
// app/javascript/controllers/tooltip_controller.js
import { Controller } from "@hotwired/stimulus"
import tippy from "tippy.js"

export default class extends Controller {
  static values = { message: String }

  connect() {
    this.#instance = tippy(this.element, { content: this.messageValue })
  }

  disconnect() {
    this.#instance.destroy()
  }

  #instance = null
}
```

```html
<button data-controller="tooltip" data-tooltip-message-value="Saved!">
  Save
</button>
```

### Key Points
- Always `destroy()` / teardown in `disconnect()` to prevent leaks
- Expose library config via `static values` so HTML controls behavior
- Swapping libraries only requires changes in the controller file

---

## 7. Helper Utilities

### Problem
You need reusable utility functions across multiple controllers.

### Solution
Extract shared logic to helper modules in `app/javascript/helpers/`.

### Timing Helpers
```javascript
// Source: app/javascript/helpers/timing_helpers.js
export function throttle(fn, delay = 1000) {
  let timeoutId = null

  return (...args) => {
    if (!timeoutId) {
      fn(...args)
      timeoutId = setTimeout(() => timeoutId = null, delay)
    }
  }
}

export function debounce(fn, delay = 1000) {
  let timeoutId = null

  return (...args) => {
    clearTimeout(timeoutId)
    timeoutId = setTimeout(() => fn.apply(this, args), delay)
  }
}

export function nextFrame() {
  return new Promise(requestAnimationFrame)
}

export function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

export function nextEvent(element, eventName) {
  return new Promise(resolve => element.addEventListener(eventName, resolve, { once: true }))
}
```

### Form Helpers
```javascript
// Source: app/javascript/helpers/form_helpers.js
import { FetchRequest } from "@rails/request.js"

export async function submitForm(form) {
  const request = new FetchRequest(form.method, form.action, {
    body: new FormData(form)
  })

  return await request.perform()
}
```

### Text Helpers
```javascript
// Source: app/javascript/helpers/text_helpers.js
export function normalizeFilteredText(string) {
  return string
    .toLowerCase()
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "") // Remove diacritics
}

export function filterMatches(text, potentialMatch) {
  return normalizeFilteredText(text).includes(normalizeFilteredText(potentialMatch))
}
```

### Usage in Controller
```javascript
import { Controller } from "@hotwired/stimulus"
import { debounce } from "helpers/timing_helpers"
import { filterMatches } from "helpers/text_helpers"

export default class extends Controller {
  initialize() {
    this.filter = debounce(this.filter.bind(this), 100)
  }

  filter() {
    this.itemTargets.forEach(item => {
      if (filterMatches(item.textContent, this.inputTarget.value)) {
        item.removeAttribute("hidden")
      } else {
        item.toggleAttribute("hidden", true)
      }
    })
  }
}
```

---

## 8. Async/Await Patterns

### Problem
You need to handle asynchronous operations like API calls or animations.

### Solution
Use `async` action methods with `await` for clean asynchronous code.

### Example
```javascript
// Source: app/javascript/controllers/copy_to_clipboard_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { content: String }
  static classes = [ "success" ]

  async copy(event) {
    event.preventDefault()
    this.reset()

    try {
      await navigator.clipboard.writeText(this.contentValue)
      this.element.classList.add(this.successClass)
    } catch {}
  }

  reset() {
    this.element.classList.remove(this.successClass)
    this.#forceReflow()
  }

  #forceReflow() {
    this.element.offsetWidth  // Force browser reflow for CSS animation reset
  }
}
```

```javascript
// Source: app/javascript/controllers/notifications_controller.js
export default class extends Controller {
  async connect() {
    if (!this.#allowed) return

    switch(Notification.permission) {
      case "granted":
        const registration = await this.#getServiceWorkerRegistration()
        const subscription = await registration?.pushManager?.getSubscription()

        if (registration && subscription) {
          this.element.classList.add(this.enabledClass)
        }
        break
    }
  }

  async attemptToSubscribe() {
    const registration = await this.#getServiceWorkerRegistration()
      || await this.#registerServiceWorker()

    switch(Notification.permission) {
      case "granted": { this.#subscribe(registration); break }
      case "default": { this.#requestPermissionAndSubscribe(registration) }
    }
  }

  async #getServiceWorkerRegistration() {
    return navigator.serviceWorker.getRegistration("/service-worker.js")
  }
}
```

### Using nextFrame for DOM Updates
```javascript
// Source: app/javascript/controllers/navigable_list_controller.js
import { nextFrame } from "helpers/timing_helpers"

export default class extends Controller {
  async selectItem(item, skipFocus = false) {
    this.#clearSelection()
    item.setAttribute(this.selectionAttributeValue, "true")
    this.currentItem = item

    await nextFrame()  // Wait for DOM to update

    if (this.autoScrollValue) {
      this.currentItem.scrollIntoView({ block: "nearest" })
    }
  }
}
```

---

## 9. Drag and Drop

### Problem
You need to implement drag and drop functionality for cards or items.

### Solution
Use the HTML5 Drag and Drop API with Stimulus actions for dragstart, dragover, drop, and dragend.

### Example
```javascript
// Source: app/javascript/controllers/drag_and_drop_controller.js
import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"
import { nextFrame } from "helpers/timing_helpers"

export default class extends Controller {
  static targets = [ "item", "container" ]
  static classes = [ "draggedItem", "hoverContainer" ]

  async dragStart(event) {
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.dropEffect = "move"
    event.dataTransfer.setData("37ui/move", event.target)

    await nextFrame()  // Wait before applying styles
    this.dragItem = this.#itemContaining(event.target)
    this.sourceContainer = this.#containerContaining(this.dragItem)
    this.dragItem.classList.add(this.draggedItemClass)
  }

  dragOver(event) {
    event.preventDefault()  // Required to allow dropping
    if (!this.dragItem) { return }

    const container = this.#containerContaining(event.target)
    this.#clearContainerHoverClasses()

    if (container && container !== this.sourceContainer) {
      container.classList.add(this.hoverContainerClass)
    }
  }

  async drop(event) {
    const targetContainer = this.#containerContaining(event.target)

    if (!targetContainer || targetContainer === this.sourceContainer) { return }

    this.wasDropped = true
    this.#insertDraggedItem(targetContainer, this.dragItem)
    await this.#submitDropRequest(this.dragItem, targetContainer)
  }

  dragEnd() {
    this.dragItem.classList.remove(this.draggedItemClass)
    this.#clearContainerHoverClasses()

    // Reset state
    this.sourceContainer = null
    this.dragItem = null
    this.wasDropped = false
  }

  #itemContaining(element) {
    return this.itemTargets.find(item => item.contains(element) || item === element)
  }

  #containerContaining(element) {
    return this.containerTargets.find(container =>
      container.contains(element) || container === element
    )
  }

  #clearContainerHoverClasses() {
    this.containerTargets.forEach(container =>
      container.classList.remove(this.hoverContainerClass)
    )
  }

  async #submitDropRequest(item, container) {
    const body = new FormData()
    const id = item.dataset.id
    const url = container.dataset.dragAndDropUrl.replaceAll("__id__", id)

    return post(url, { body, headers: { Accept: "text/vnd.turbo-stream.html" } })
  }
}
```

### HTML Usage
```html
<div data-controller="drag-and-drop"
     data-drag-and-drop-dragged-item-class="dragging"
     data-drag-and-drop-hover-container-class="drop-target">

  <div data-drag-and-drop-target="container"
       data-drag-and-drop-url="/cards/__id__/move">

    <div data-drag-and-drop-target="item"
         data-id="123"
         draggable="true"
         data-action="dragstart->drag-and-drop#dragStart
                      dragend->drag-and-drop#dragEnd">
      Card content
    </div>
  </div>

  <div data-drag-and-drop-target="container"
       data-drag-and-drop-url="/cards/__id__/move"
       data-action="dragover->drag-and-drop#dragOver
                    drop->drag-and-drop#drop">
    <!-- Drop target column -->
  </div>
</div>
```

### Key Points
- Set `draggable="true"` on draggable elements
- Call `event.preventDefault()` in `dragOver` to allow drops
- Use `event.dataTransfer` to store drag data
- Clean up all state in `dragEnd` (called whether drop succeeds or not)
- Use `nextFrame()` before applying visual changes in dragStart

---

## 10. Outlets (Cross-Controller Communication)

### Problem
You need one controller to communicate with or trigger actions on another controller.

### Solution
Use Stimulus outlets to get references to other controllers.

### Example
```javascript
// Source: app/javascript/controllers/outlet_auto_save_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static outlets = [ "auto-save" ]

  change(event) {
    this.autoSaveOutlet.change(event)  // Call method on outlet controller
  }

  submit() {
    this.autoSaveOutlet.submit()
  }
}
```

### Alternative: Finding Controllers Programmatically
```javascript
// Source: app/javascript/controllers/navigable_list_controller.js
get #parentNavigableListController() {
  const parentNavigableList = this.element.parentElement?.closest("[data-controller~='navigable-list']")
  if (parentNavigableList) {
    return this.application.getControllerForElementAndIdentifier(parentNavigableList, "navigable-list")
  }
  return null
}
```

### HTML Usage for Outlets
```html
<div data-controller="outlet-auto-save"
     data-outlet-auto-save-auto-save-outlet="#auto-save-form">
  <button data-action="click->outlet-auto-save#submit">Save</button>
</div>

<form id="auto-save-form" data-controller="auto-save">
  <!-- form content -->
</form>
```

---

## 11. IntersectionObserver Pattern

### Problem
You need to detect when an element becomes visible and trigger an action.

### Solution
Use IntersectionObserver in `connect()` for lazy loading or visibility-triggered actions.

### Example
```javascript
// Source: app/javascript/controllers/fetch_on_visible_controller.js
import { Controller } from "@hotwired/stimulus"
import { get } from "@rails/request.js"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.#observe()
  }

  #observe() {
    const observer = new IntersectionObserver((entries) => {
      const visible = !!entries.find(entry => entry.isIntersecting)
      if (visible) {
        this.#fetch()
      }
    })

    observer.observe(this.element)
  }

  #fetch() {
    get(this.urlValue, { responseKind: "turbo-stream" })
  }
}
```

---

## Common Patterns Summary

| Pattern | Use Case |
|---------|----------|
| `#privateField` | Internal state, timers, cached values |
| `static values = {...}` | Configuration from HTML attributes |
| `static targets = [...]` | DOM element references |
| `static classes = [...]` | Dynamic CSS class names (use plural `this.hiddenClasses` for Tailwind multi-class) |
| `static outlets = [...]` | Direct cross-controller method calls |
| `this.dispatch()` + `data-action` | Loose cross-controller event composition |
| `connect()` | Initialize, setup observers |
| `disconnect()` | Cleanup timers, destroy library instances |
| `initialize()` | One-time setup (debounce binding) |
| `async/await` | Asynchronous operations |
| `nextFrame()` | Wait for DOM updates |
| Helper modules | Shared utility functions |
| Wrap library in controller | Decouple HTML from third-party libs |

## Design Checklist

Before building a new controller, ask:
- Can CSS alone solve this? → Don't use Stimulus
- Can Turbo handle it? → Use Turbo
- Can I compose existing controllers via `data-action` events in HTML? → Compose, don't build
- Is this controller behavior-based (reusable) or resource-based (one page)? → Make it behavior-based
- Am I adding manual `addEventListener`? → Use `data-action` instead
