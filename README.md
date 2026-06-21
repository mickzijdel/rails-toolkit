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
- **rails-api** — API-only and JSON API design: `Api::BaseController` setup, namespace versioning, Jbuilder/Blueprinter serialization, CORS with rack-cors, pagy pagination, standardized JSON error responses, authentication guidance, and request-spec/Minitest patterns.
- **rails-action-mailer** — Action Mailer patterns: shallow mailers, `deliver_later` everywhere, multi-part HTML/text templates, `ApplicationMailer` defaults, URL generation, previews, testing with `assert_emails`/`assert_enqueued_email_with`, attachments via Active Storage URLs, and SMTP credential configuration.

Many code examples are extracted from 37signals' Fizzy codebase and STYLE.md; they
illustrate the patterns and are not files in this repository or yours.

### Hook
- **SessionStart** (`bin/rails-detect-hook`): when a session opens in a Rails project (a `Gemfile` that requires the `rails` gem), injects a reminder to consult `rails-toolkit:rails-core` and the other `rails-toolkit:rails-*` skills.

## Install

This plugin lives in `~/.claude/skills/rails-toolkit/` and auto-loads as
`rails-toolkit@skills-dir`. Its skills are namespaced `rails-toolkit:<name>`.

## Development

Tooling is pinned with [mise](https://mise.jdx.dev) and pre-commit checks run via
[hk](https://hk.jdx.dev). Set up and verify:

```bash
mise trust && mise install   # provision hk, shellcheck, shfmt, uv, node, gitleaks (per mise.lock)
hk install                   # install the git pre-commit hook
hk run check                 # lint + audits + gitleaks + large-file guard
uv run pytest                # exercise bin/rails-detect-hook as a subprocess
```

The same checks run in CI (`.github/workflows/ci.yml`). Bump the plugin version in
`.claude-plugin/plugin.json` on every commit (patch for fixes, minor for new skills/tools).

## License

MIT
