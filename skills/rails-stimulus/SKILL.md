---
name: rails-stimulus
description: Use when writing Stimulus controllers with modern JavaScript patterns (ES2022 private fields, values, targets)
---

# Rails Stimulus Patterns

## 0. Design Philosophy

**Stimulus is "just sprinkles"** — Turbo handles the reactive application layer. Stimulus covers the last 10–20%. Always ask: can CSS alone solve this? Can Turbo handle it? Reach for Stimulus last.

**Build behavior-based controllers, not resource-based ones.** A `ClipboardController` that copies text works everywhere. A `PinsController` with a `copyPIN()` method is dead weight. Think: showing/hiding, focusing inputs, sorting tables, tooltips — not page-specific resources.

**Minimize dependencies.** Modern JS has excellent browser support. Check [youmightnotneedjquery.com](https://youmightnotneedjquery.com) before adding a library. Fewer dependencies = simpler upgrades.

---

## 1. Private Fields (ES2022)

Use `#fieldName` / `#methodName()` / `get #propertyName()` for internal state, timers, and cached values — truly private, not just convention.

```javascript
// auto_save_controller.js
import { Controller } from "@hotwired/stimulus"
import { submitForm } from "helpers/form_helpers"

const AUTOSAVE_INTERVAL = 3000

export default class extends Controller {
  #timer

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

  get #dirty() {
    return !!this.#timer
  }
}
```

---

## 2. Static Targets and Values

Declare `targets`, `values`, and `classes` statically; always use object syntax for values with defaults.

```javascript
// dialog_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "dialog" ]
  static values = {
    modal: { type: Boolean, default: false },
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

- `hasXxxValue` checks whether a value was explicitly provided in HTML.
- `this.xxxTargets` (plural) returns all matching targets as an array.

---

## 3. Lifecycle Hooks

- `initialize()` — once per instantiation; use for method binding/debouncing.
- `connect()` — each time the element attaches to the DOM; setup, observers.
- `disconnect()` — element removed; clean up timers and library instances.

**Prefer `data-action` over manual `addEventListener`** — Stimulus handles cleanup automatically and the HTML communicates intent. Manual listeners require remembering to remove them in `disconnect()`.

```html
<!-- ✅ Prefer: Stimulus manages listener lifecycle -->
<details data-controller="menu" data-action="toggle->menu#trapFocus"></details>
```

```javascript
// filter_controller.js
import { Controller } from "@hotwired/stimulus"
import { debounce } from "helpers/timing_helpers"

export default class extends Controller {
  static targets = [ "input", "item" ]

  initialize() {
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

---

## 4. Action Methods

Public methods are callable via `data-action="controller#method"` and receive the event object.

```javascript
// toggle_class_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static classes = [ "toggle" ]

  toggle() {
    this.element.classList.toggle(this.toggleClass)
  }

  add() {
    this.element.classList.add(this.toggleClass)
  }

  remove() {
    this.element.classList.remove(this.toggleClass)
  }
}
```

Check `event.defaultPrevented` before handling events another controller may have handled; use `event.preventDefault()` / `event.stopPropagation()` as needed.

---

## 5. Custom Events with dispatch()

`this.dispatch("name")` emits a bubbling `controllerName:name` event — the loose-coupling mechanism for cross-controller communication. Pass data via `{ detail: { ... } }`.

```javascript
// dialog_controller.js
open() {
  this.dialogTarget.show()
  this.dispatch("show")  // emits "dialog:show"
}
```

```html
<!-- Compose existing controllers in HTML without writing new code:
     ClipboardController dispatches "clipboard:copy"; FlashController listens -->
<div data-controller="clipboard flash"
     data-action="clipboard:copy->flash#show">
  <input data-clipboard-target="source" value="some text">
  <button data-action="clipboard#copy">Copy</button>
</div>
```

**Compose behaviors in HTML** — wire up existing controllers before building new ones.

---

## 6. Wrapping External Libraries

Wrap third-party libraries (tippy.js, chart.js) in a controller so swapping the library means changing one file.

```javascript
// tooltip_controller.js
import { Controller } from "@hotwired/stimulus"
import tippy from "tippy.js"

export default class extends Controller {
  static values = { message: String }

  connect() {
    this.#instance = tippy(this.element, { content: this.messageValue })
  }

  disconnect() {
    this.#instance.destroy()   // always teardown to prevent leaks
  }

  #instance = null
}
```

```html
<button data-controller="tooltip" data-tooltip-message-value="Saved!">Save</button>
```

---

## 7. Helper Utilities

Extract shared logic to modules in `app/javascript/helpers/`:

```javascript
// helpers/timing_helpers.js
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

export function nextEvent(element, eventName) {
  return new Promise(resolve => element.addEventListener(eventName, resolve, { once: true }))
}
```

Same idea for form helpers (`submitForm(form)` wrapping `@rails/request.js` FetchRequest) and text helpers (diacritic-insensitive `filterMatches`).

---

## 8. Async/Await Patterns

Action methods can be `async`; use `nextFrame()` to wait for DOM updates before reading layout or scrolling.

```javascript
// copy_to_clipboard_controller.js
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
    this.element.offsetWidth  // force reflow so the CSS animation can restart
  }
}
```

```javascript
// navigable_list_controller.js — wait for DOM before scrolling
async selectItem(item) {
  this.#clearSelection()
  item.setAttribute(this.selectionAttributeValue, "true")

  await nextFrame()

  item.scrollIntoView({ block: "nearest" })
}
```

---

## 9. Drag and Drop

HTML5 Drag and Drop API with Stimulus actions for dragstart, dragover, drop, and dragend.

```javascript
// drag_and_drop_controller.js
import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"
import { nextFrame } from "helpers/timing_helpers"

export default class extends Controller {
  static targets = [ "item", "container" ]
  static classes = [ "draggedItem", "hoverContainer" ]

  async dragStart(event) {
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.dropEffect = "move"
    event.dataTransfer.setData("app/move", event.target)

    await nextFrame()  // wait before applying styles
    this.dragItem = this.#itemContaining(event.target)
    this.sourceContainer = this.#containerContaining(this.dragItem)
    this.dragItem.classList.add(this.draggedItemClass)
  }

  dragOver(event) {
    event.preventDefault()  // required to allow dropping
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
    // called whether or not the drop succeeded — reset ALL state here
    this.dragItem.classList.remove(this.draggedItemClass)
    this.#clearContainerHoverClasses()

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

Set `draggable="true"` on draggable elements; `event.preventDefault()` in `dragOver` is what allows drops.

---

## 10. Outlets (Cross-Controller Communication)

Outlets give one controller a direct reference to another (vs the loose event composition of Pattern 5).

```javascript
export default class extends Controller {
  static outlets = [ "auto-save" ]

  submit() {
    this.autoSaveOutlet.submit()
  }
}
```

```html
<div data-controller="outlet-auto-save"
     data-outlet-auto-save-auto-save-outlet="#auto-save-form">
  <button data-action="click->outlet-auto-save#submit">Save</button>
</div>

<form id="auto-save-form" data-controller="auto-save"></form>
```

For ad-hoc lookup (e.g. a parent controller of the same type), use `this.application.getControllerForElementAndIdentifier(element, "identifier")`.

---

## 11. IntersectionObserver Pattern

Lazy-load content when an element becomes visible:

```javascript
// fetch_on_visible_controller.js
import { Controller } from "@hotwired/stimulus"
import { get } from "@rails/request.js"

export default class extends Controller {
  static values = { url: String }

  connect() {
    const observer = new IntersectionObserver((entries) => {
      if (entries.some(entry => entry.isIntersecting)) {
        get(this.urlValue, { responseKind: "turbo-stream" })
      }
    })

    observer.observe(this.element)
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
| `connect()` / `disconnect()` | Setup observers / cleanup timers and library instances |
| `initialize()` | One-time setup (debounce binding) |
| `nextFrame()` | Wait for DOM updates |
| Wrap library in controller | Decouple HTML from third-party libs |

## Design Checklist

Before building a new controller, ask:
- Can CSS alone solve this? → Don't use Stimulus
- Can Turbo handle it? → Use Turbo
- Can I compose existing controllers via `data-action` events in HTML? → Compose, don't build
- Is this controller behavior-based (reusable) or resource-based (one page)? → Make it behavior-based
- Am I adding manual `addEventListener`? → Use `data-action` instead
