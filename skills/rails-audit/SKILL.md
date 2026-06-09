---
name: rails-audit
description: "Use when auditing, reviewing, or doing a health-check of an existing/inherited Rails app — onboarding to a legacy codebase, assessing technical debt, or a pre-engagement code review. Orchestrates the deep-dive rails-* skills and produces a severity-ranked report. Triggers on: code audit, app review, legacy/inherited Rails app, technical debt assessment, 'review my Rails app'."
---

# Rails App Audit

## Overview

A top-level health-check for an **existing** Rails app — inheriting a legacy codebase,
onboarding to an unfamiliar project, or doing a pre-engagement review. This skill is the
entry point for *reviewing* an app, the counterpart to [[rails-core]] which is the entry
point for *writing* one.

It **orchestrates**: it owns the broad health-check items nothing else covers (version
pinning, dependency CVEs, exposed secrets, seeds, tech-debt) and hands off the deep dives
to the specialist skills ([[rails-database-performance]], [[rails-security]],
[[rails-performance]], [[rails-testing]], [[rails-upgrade]]). Do **not** re-derive what
those skills already do — run the cheap detection here, then delegate the fix.

The audit ends in a **written, severity-ranked report** (see [Producing the Report](#producing-the-report)).

## How to Run This Audit

1. Confirm you are at the app root (`Gemfile`, `app/`, `config/` present).
2. Work through every numbered section below — do not stop early.
3. For **each** finding, record three things:
   - **Severity** — 🔴 high (security / data loss / broken in prod), 🟡 medium (tech debt, performance, missing safety net), 🟢 low (polish, style, docs).
   - **Location** — `file:line` (the audit must point at real code, not generalities).
   - **Fix** — the concrete remediation, and **which skill owns the deep fix** if it's a delegated area.
4. When a section hands off to another skill (shown as "→ [[skill-name]]"), run only the quick detection here and note the handoff; the named skill carries the authoritative checklist.

---

## 1. Ruby & Rails Version Pinning

A shared, explicit version is the baseline for reproducible builds. Check the version is
pinned *and* still supported.

```bash
cat .ruby-version 2>/dev/null || echo "MISSING .ruby-version"
grep -nE '^\s*ruby\s+["'\'']' Gemfile
grep -nE '^\s*gem\s+["'\'']rails["'\'']' Gemfile
ruby -v; bin/rails -v 2>/dev/null
```

- **No `.ruby-version`** → 🟡 add one so every dev/CI uses the same interpreter.
- **Rails not locked to a specific version** (`gem "rails"` with no version, or a loose `>=`) → 🟡 a `bundle update` can silently jump majors. Lock it.
- **EOL Ruby or Rails** → 🔴/🟡. Check the running version against the support schedule. An upgrade is its own project — hand off to [[rails-upgrade]] (do **not** hand-roll the version bump).

---

## 2. Gemfile Hygiene

```bash
head -1 Gemfile                                          # source must be HTTPS
grep -nE 'cooldown' Gemfile .bundle/config 2>/dev/null   # supply-chain cooldown set?
grep -nE 'group\s+:' Gemfile                             # dev/test gems grouped out of production?
```

- **`source 'http://...'`** (not HTTPS) → 🔴.
- **No supply-chain cooldown** → 🟡. A compromised gem account can ship a malicious release that any `bundle install` in the following minutes resolves straight to. Bundler's `cooldown` refuses to resolve a version until it has been public for at least N days, leaving time for the release to be vetted. Recommend ~4 days, on the source line:
  ```ruby
  source "https://rubygems.org", cooldown: 4
  ```
  (or `bundle config set cooldown 4`). Requires a recent Bundler. See the [RubyGems announcement](https://blog.rubygems.org/2026/06/03/cooldown-let-new-gems-be-vetted.html).
- **Dev/test gems not grouped** → 🟡. Wrap development- and test-only gems (rspec-rails, capybara, debug, factory_bot, brakeman, rubocop) in `group :development, :test do … end`, so a production deploy run with `BUNDLE_WITHOUT=development:test` (or `bundle install --without development test`) neither installs nor loads them: smaller image, faster boot, smaller attack surface.
- **Undocumented/obscure gems** → 🟢 add a one-line comment for the next maintainer.

> Don't flag missing per-gem version pins. With a committed `Gemfile.lock` (and `bundle install --deployment` / `BUNDLE_FROZEN=true` on deploy), every version is already frozen; loose constraints in the `Gemfile` are fine.

---

## 3. Dependency Vulnerabilities & Static Security Scan

Two free, fast scanners. Run both.

```bash
gem install bundler-audit 2>/dev/null; bundle exec bundler-audit check --update 2>/dev/null || bundler-audit check --update
gem install brakeman 2>/dev/null; bundle exec brakeman -q -A 2>/dev/null || brakeman -q -A
```

- **`bundler-audit`** flags `Gemfile.lock` gems with known CVEs and the patched version → 🔴/🟡 by criticality. Record each advisory + the upgrade target.
- **`brakeman`** flags code-level issues (SQLi, mass-assignment, unsafe redirects, XSS). Triage each warning; confidence `High` first → 🔴.
- For the *design* of auth/authorization behind these findings, hand off to [[rails-security]].

---

## 4. Exposed Secrets

Secrets in the repo (or in git history) are the highest-impact, easiest-to-miss finding.

```bash
grep -rinE '(password|secret|api[_-]?key|access[_-]?key|token)\s*[:=]\s*["'\''][^"'\'' ]{6,}' config/ app/ lib/ 2>/dev/null
git log --oneline -- config/master.key config/credentials.yml.enc 2>/dev/null
grep -nE 'config/master.key|config/credentials.*\.key|\.env' .gitignore 2>/dev/null
```

- **Literal credentials in `config/environments/production.rb`, initializers, or `*.yml`** → 🔴. Move to encrypted credentials (`bin/rails credentials:edit`) or ENV.
- **`config/master.key` or any `.env` NOT gitignored** → 🔴. Modern Rails stores secrets in `config/credentials.yml.enc` (encrypted, committable) decrypted by `master.key` (which must stay out of git).
- **A secret already committed** → 🔴. Rotate it *first* (assume it's compromised), then purge history. See [[rails-security]] for what to rotate and how to scope it.

---

## 5. Test Health

A suite that nobody has touched in a year is a liability, not a safety net.

```bash
git log -1 --pretty=format:'%ci  %s' -- test/ spec/ 2>/dev/null; echo
ls -d test spec 2>/dev/null
grep -c . <(find app -name '*.rb') ; find test spec -name '*_test.rb' -o -name '*_spec.rb' 2>/dev/null | wc -l
```

- **Tests last touched long before app code** → 🟡 likely abandoned after an upgrade broke them, or never written. Note the staleness.
- **No `test/`/`spec/` at all, or near-empty** → 🔴 no regression safety net.
- For coverage strategy, fixtures vs factories, system tests, and parallelization → hand off to [[rails-testing]]. To quantify, run the suite and a coverage tool (SimpleCov) and report the percentage.

---

## 6. Seed Data

Developers must be able to stand up a working local DB without a production dump.

```bash
test -s db/seeds.rb && echo "seeds.rb present ($(wc -l < db/seeds.rb) lines)" || echo "MISSING/empty db/seeds.rb"
grep -nE 'find_or_create_by|destroy_all|delete_all' db/seeds.rb 2>/dev/null
```

- **Missing or empty `db/seeds.rb`** → 🟡 onboarding requires copying prod data (privacy + size risk).
- **Seeds that aren't idempotent** (plain `create!` that dupes on re-run) → 🟢 prefer `find_or_create_by` so seeds can be loaded, cleared, and re-loaded cleanly.

---

## 7. Lint & Style Drift

```bash
bundle exec rubocop --format offenses 2>/dev/null | tail -20 || bundle exec standardrb 2>/dev/null | tail -20
ls .rubocop.yml .standard.yml 2>/dev/null
```

- **No linter configured** → 🟢 add `rubocop-rails` or `standard` for consistent style.
- **Configured but thousands of offenses** → 🟡 style has drifted; consider `rubocop --auto-gen-config` to baseline, then fix incrementally.
- For the project's actual conventions (method ordering, conditionals, REST routing, naming) → [[rails-style]].

---

## 8. Schema & Index Quick Heuristic

A fast smell test before the full schema audit. Foreign keys without indexes are the most
common Rails performance bug.

```bash
echo "FK-ish columns:"; grep -E '_id' db/schema.rb | grep -v 'add_index\|t\.index' | wc -l
echo "indexes:";        grep -E 'add_index|t\.index' db/schema.rb | wc -l
```

- If those two numbers are **drastically different**, indexes have likely been overlooked → 🟡.
- This is only a heuristic. The authoritative index/query/N+1-at-the-DB audit (polymorphic, scope, status, auth, counter-cache, pagination) lives in [[rails-database-performance]] — run it next.

---

## 9. Performance & N+1 Quick Scan

```bash
grep -rnE '\.(each|map)\b' app/views/ app/controllers/ 2>/dev/null | head -20   # loops that may trigger per-row queries
grep -rnE '\.includes\(|\.preload\(|\.eager_load\(' app/ 2>/dev/null | wc -l      # is eager loading used at all?
```

- Views/controllers iterating an association with no matching `includes`/`preload` → 🟡 probable N+1. Spot-check the dev log (or add `bullet`/`prosopite`) to confirm.
- For caching, ETags, batching, and the full N+1 treatment → [[rails-performance]].

---

## 10. Architecture Smells

Cheap size heuristics surface the files most likely to hide problems.

```bash
echo "Fattest models:";      wc -l app/models/**/*.rb 2>/dev/null | sort -rn | head -10
echo "Fattest controllers:"; wc -l app/controllers/**/*.rb 2>/dev/null | sort -rn | head -10
echo "Service-object sprawl:"; ls app/services 2>/dev/null | wc -l
grep -rnE '^\s*def ' app/controllers/ 2>/dev/null | grep -vE 'index|show|new|create|edit|update|destroy' | head   # non-REST actions
```

- **Controllers fat with business logic / many non-REST actions** → 🟡 push behaviour into models, extract concerns. See [[rails-controllers]] and [[rails-style]] (REST routing).
- **God models (many hundreds of lines)** → 🟡 extract concerns / POROs. See [[rails-models]].
- **A large `app/services/` tree** → 🟡 in 37signals-style Rails this is usually logic that belongs on rich models, not a service layer. Weigh against [[rails-philosophy]] before recommending more of it.

---

## 11. Technical-Debt Inventory

```bash
grep -rinE 'todo|fixme|hack|xxx|deprecated' app/ lib/ 2>/dev/null | wc -l
grep -rinE 'todo|fixme|hack|xxx' app/ lib/ 2>/dev/null | head -40
grep -rnE '^\s*#\s*[a-z].*\b(def|end|do|=)\b' app/ lib/ 2>/dev/null | head   # commented-out code
```

- Inventory every `TODO`/`FIXME`/`HACK` → 🟢/🟡. Decide per item: do it, ticket it, or delete the stale note.
- **Large blocks of commented-out code** → 🟢 delete; git is the history.

---

## Producing the Report

End the audit with a written report, **grouped by severity** (🔴 → 🟡 → 🟢). Each item:

```
### 🔴 <short title>
- **Where:** path/to/file.rb:42  (or: Gemfile, db/schema.rb)
- **Finding:** what's wrong, with the evidence (the grep hit / scanner line).
- **Impact:** why it matters (security / perf / maintainability / onboarding).
- **Fix:** the concrete change, and **→ which skill** to use for the deep fix.
```

Close with a one-paragraph **summary**: overall health, the top 3 things to fix first, and
the recommended order (security & exposed secrets before refactors).

## Quick Reference

| # | Check | Command / signal | Deep-dive skill |
|---|---|---|---|
| 1 | Version pinning | `.ruby-version`, locked `gem "rails"`, EOL? | [[rails-upgrade]] |
| 2 | Gemfile hygiene | HTTPS source, cooldown, dev/test groups | — |
| 3 | Vulnerabilities | `bundler-audit`, `brakeman` | [[rails-security]] |
| 4 | Exposed secrets | grep `config/`, `master.key` gitignored | [[rails-security]] |
| 5 | Test health | `git log -1 -- test/ spec/`, coverage | [[rails-testing]] |
| 6 | Seed data | `db/seeds.rb` present & idempotent | — |
| 7 | Lint/style | `rubocop` / `standard` offenses | [[rails-style]] |
| 8 | Schema/index | FK-count vs index-count | [[rails-database-performance]] |
| 9 | N+1/perf | loops without `includes` | [[rails-performance]] |
| 10 | Architecture | fat models/controllers, service sprawl | [[rails-philosophy]], [[rails-models]], [[rails-controllers]] |
| 11 | Tech debt | `TODO`/`FIXME`, dead code | — |

## Common Mistakes

- **Reporting from memory instead of running the commands.** Every finding must cite a real grep hit / scanner line / `file:line`. No evidence, no finding.
- **Re-deriving a deep-dive skill inline.** Sections 8–10 are detection heuristics only; the authoritative checklist lives in the linked skill. Delegate, don't duplicate.
- **Findings without severity or location.** A report the user can't triage or act on is noise.
- **Burying the lede.** Lead with 🔴 security/secrets; refactors and style come last.
- **Treating an EOL version as a quick fix.** Version upgrades are a project — route to [[rails-upgrade]], don't bump in place.
