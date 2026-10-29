# Deferred upgrades

## ruff 0.15 → 0.16+ (dev group held at 0.15.22 in uv.lock, 2026-10-29)

**Why:** ruff 0.16 enables a much larger default rule set (413 rules, up from 59) and formats
Markdown code blocks by default. This repo sets no `[tool.ruff.lint] select`, so ruff 0.17.2
reports 6 findings (PLW1510 5, I001 1). The gating ruff (hk and CI) is mise's, locked at 0.15.16
in `mise.lock`, so the uv copy stays on 0.15 to match it.

**Manual steps (pick one), then move mise's ruff and the uv dev group together:**

1. Keep today's rules: add `[tool.ruff.lint] select = ["E4", "E7", "E9", "F"]` (the pre-0.16
   default) and `extend-exclude = ["*.md"]` if Markdown should stay unformatted.
2. Adopt the new defaults: fix the findings (`ruff check --fix .`, review the rest by hand).

Then `mise upgrade ruff` (through the dev-env standard), `uv lock -P ruff && uv sync`, and run
`hk run check --all` and `uv run pytest`.
