# rails-toolkit

A Claude Code plugin bundling 37signals-style Ruby on Rails skills, a `rails-core`
gotchas skill, and a Rails-detection session hook.

## What's inside

### Skills (`rails-toolkit:<name>`)
- **rails-core** — read first; the project owner's hard-won Rails rules (fixtures, migrations, multi-database rollback, dev-server schema-cache restart, Stimulus LSP, server-side validation, gem docs, full-suite-after-factory-changes).
- **rails-philosophy** — vanilla Rails, rich models, REST everything, Solid Stack, Hotwire first.
- **rails-style** — method ordering, conditionals, REST routing, naming, and enforcing style on AI-generated code with a RuboCop hook.
- **rails-models**, **rails-controllers**, **rails-jobs**, **rails-turbo**, **rails-stimulus**, **rails-viewcomponents**, **rails-activestorage** — area guides.
- **rails-testing** — fixtures, system tests, VCR, parallel execution, SimpleCov coverage checks, test-gap pre-flight, and profiling/speeding up a slow suite (Stackprof, Speedscope, TestProf).
- **rails-clean-test-output** — eliminate noisy test output (warnings, stray puts/p/pp, deprecations) one issue at a time with per-fix verification and commits; detects RSpec vs Minitest, and replaces logging `p`s with severity-appropriate `Rails.logger` calls. Wraps thoughtbot's vendored `clean-rspec-output` skill.
- **rails-performance**, **rails-database-performance** — caching/ETags/N+1 and schema/index audits.
- **rails-migrations** — safe zero-downtime migration patterns: `strong_migrations` gem, concurrent index creation, column removal via `ignored_columns`, dual-write column/table renames, `in_batches` data backfills, column type changes, and reversibility.
- **rails-audit** — top-level health-check of an existing/inherited app (version pinning, bundler-audit/brakeman, exposed secrets, seeds, tech debt) that orchestrates the deep-dive skills and emits a severity-ranked report.
- **rails-multi-tenancy**, **rails-security**, **rails-project-setup**.
- **rails-api** — API-only and JSON API design: `Api::BaseController` setup, namespace versioning, Jbuilder/Blueprinter serialization, CORS with rack-cors, offset (pagy) and keyset/cursor pagination, standardized JSON error responses, authentication guidance, and request-spec/Minitest patterns.

Many code examples are extracted from 37signals' Fizzy codebase and STYLE.md; they
illustrate the patterns and are not files in this repository or yours.

### Hooks
- **SessionStart** (`bin/rails-detect-hook`): when a session opens in a Rails project (a `Gemfile` that requires the `rails` gem), injects a reminder to consult `rails-toolkit:rails-core` and the other `rails-toolkit:rails-*` skills.
- **PostToolUse** (`bin/rubocop-autocorrect-hook`): after Claude edits a Ruby file, runs RuboCop safe-autocorrect on it and reports any remaining offenses back as context. Self-guarding — only acts on `.rb`/`.rake`/`.gemspec` files in a project that opted into RuboCop (a `.rubocop.yml`) with a resolvable runner; no-ops silently everywhere else, and never blocks. See `rails-toolkit:rails-style` §10 for the stronger project-local `Stop`-hook variant.

### Vendored skills (git submodules)
- **`vendor/rails-upgrade-skill`** ([ombulabs](https://github.com/ombulabs/claude-code_rails-upgrade-skill)) — exposes the `rails-upgrade` and `upgrade-cleanup` skills via `plugin.json`'s `skills` path.
- **`vendor/clean-rspec-output`** ([thoughtbot](https://github.com/thoughtbot/clean-rspec-output)) — reference material for `rails-clean-test-output`; not registered directly, the wrapper skill reads it. Update either with `git submodule update --remote <path>` and commit the new pointer.

## Install

This plugin lives in `~/.claude/skills/rails-toolkit/` and auto-loads as
`rails-toolkit@skills-dir`. Its skills are namespaced `rails-toolkit:<name>`.

Clone with submodules (or run `git submodule update --init --recursive` after cloning) so the
vendored skills above are present.

## Usage

Skills load on demand by name (`rails-toolkit:<name>`) and trigger from their descriptions, so
in a Rails project Claude reaches for them automatically — start with `rails-toolkit:rails-core`.
You can also invoke one explicitly, e.g. to clean up a noisy suite:

```
/rails-toolkit:rails-clean-test-output
```

## Development

Tooling is pinned with [mise](https://mise.jdx.dev) and pre-commit checks run via
[hk](https://hk.jdx.dev). Set up and verify:

```bash
mise trust && mise install   # provision hk, shellcheck, shfmt, uv, node, gitleaks (per mise.lock)
hk install                   # install the git pre-commit hook
hk run check                 # lint + audits + gitleaks + large-file guard
uv run pytest                # exercise the bin/ hook scripts as subprocesses
```

The same checks run in CI (`.github/workflows/ci.yml`). Bump the plugin version in
`.claude-plugin/plugin.json` on every commit (patch for fixes, minor for new skills/tools).

## License

MIT
