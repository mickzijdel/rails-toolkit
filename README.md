# rails-toolkit

A Claude Code plugin bundling 37signals-style Ruby on Rails skills, a `rails-core`
gotchas skill, and a Rails-detection session hook.

## What's inside

### Skills (`rails-toolkit:<name>`)
- **rails-core** — read first; the project owner's hard-won Rails rules (fixtures, migrations, multi-database rollback, dev-server schema-cache restart, Stimulus LSP, server-side validation, gem docs, full-suite-after-factory-changes).
- **rails-philosophy** — vanilla Rails, rich models, REST everything, Solid Stack, Hotwire first.
- **rails-style** — method ordering, conditionals, REST routing, naming.
- **rails-models**, **rails-controllers**, **rails-jobs**, **rails-turbo**, **rails-stimulus**, **rails-viewcomponents**, **rails-activestorage** — area guides.
- **rails-testing** — fixtures, system tests, VCR, parallel execution.
- **rails-performance**, **rails-database-performance** — caching/ETags/N+1 and schema/index audits.
- **rails-audit** — top-level health-check of an existing/inherited app (version pinning, bundler-audit/brakeman, exposed secrets, seeds, tech debt) that orchestrates the deep-dive skills and emits a severity-ranked report.
- **rails-multi-tenancy**, **rails-security**, **rails-project-setup**.

### Hook
- **SessionStart** (`bin/rails-detect-hook`): when a session opens in a Rails project (a `Gemfile` that requires the `rails` gem), injects a reminder to consult `rails-toolkit:rails-core` and the other `rails-toolkit:rails-*` skills.

## Install

This plugin lives in `~/.claude/skills/rails-toolkit/` and auto-loads as
`rails-toolkit@skills-dir`. Its skills are namespaced `rails-toolkit:<name>`.

## License

MIT
