---
name: rails-clean-test-output
description: Systematically eliminate unexpected output (warnings, stray puts/p/pp, deprecation notices) from a Rails test suite, one issue at a time, with per-fix verification and commits. Works for both RSpec (`bundle exec rspec`) and Minitest (`bin/rails test`) - detect which the project uses and adapt. Use whenever the user wants to clean up, silence, fix, or investigate noisy test output, mentions warnings or stray logs during test runs, or asks to get their suite running "clean" - e.g. "my test output is noisy", "there's a bunch of warnings when I run specs/tests", "help me clean up the test output".
---

# Clean Up Unexpected Rails Test Output

This skill wraps thoughtbot's [`clean-rspec-output`](https://github.com/thoughtbot/clean-rspec-output),
vendored in this plugin at `../../vendor/clean-rspec-output/`. That skill is the authoritative,
detailed per-issue workflow (capture → scan → isolate → fix → verify → simplify → commit). This
wrapper adds two things on top:

1. **It is framework-agnostic.** The vendored workflow is written for RSpec, but the same approach
   works for Minitest. Detect which the project uses and translate the commands.
2. **Logging `p`/`puts` calls become logger calls, not deletions.** See Override B below.

## Step 0 — Detect the test framework

Before anything else, determine which framework the repo uses, and say which you detected:

- **RSpec** if the `Gemfile`/`Gemfile.lock` includes `rspec-rails` and there is a `spec/` directory.
- **Minitest** otherwise (a `test/` directory with `minitest`, the Rails default).

If both are present, ask the user which suite they want cleaned.

## The workflow

Read and follow `../../vendor/clean-rspec-output/SKILL.md` end to end — its fix-scope rules
(change *how* a test runs, never *what* it covers), its hard gate on reproducing each issue in
isolation before fixing, its one-fix-per-commit discipline, and its commit-message format all
apply unchanged. The two overrides below take precedence wherever they conflict with it.

## Override A — Minitest command map

The vendored workflow hardcodes `bundle exec rspec` commands. When the project uses Minitest,
substitute the equivalents below. Everything else (the verification loop, the anchored Grep
patterns for locating stray output, the isolation gate) carries over identically.

| Purpose | RSpec | Minitest |
|---|---|---|
| Capture full run | `bundle exec rspec 2>&1 \| tee tmp/rspec-output.log` | `bin/rails test 2>&1 \| tee tmp/test-output.log` |
| Locate the source test | `bundle exec rspec --format documentation 2>&1 \| tee tmp/rspec-output-doc.log` | `bin/rails test -v 2>&1 \| tee tmp/test-output-doc.log` |
| Reproduce / verify in isolation | `bundle exec rspec spec/path_spec.rb:LINE` | `bin/rails test test/path_test.rb:LINE` |

Notes for Minitest:

- Minitest has no separate documentation format; `-v` (verbose) prints each test name inline and
  plays the role of the documentation log — stray output appears between the named test lines, so
  the "locate the test immediately preceding the stray output" technique still works.
- System/integration tests live under `test/system` and run the same way (`bin/rails test:system`
  for the whole system suite).
- Use `bin/rails test` (or `bundle exec rails test`) rather than `rake` so the right environment
  loads. The plain log is still the only log you scan for issues; the `-v` log is only for locating
  the test that produced an already-identified issue.

## Override B — logging `p`/`puts` become `Rails.logger` calls, not deletions

The vendored workflow's default for a stray `p`/`puts`/`pp` is to **delete** it. Keep that for
genuine debug leftovers, but do **not** blanket-delete output that is actually *conveying
operational information*. Decide per call:

- **Leftover debug artifact** — a bare `p value` / `pp obj` / `puts var` with no semantic message,
  left over from troubleshooting → **delete it** (same as upstream).
- **Operational / progress message** — a `p`/`puts` that reports what the code is doing (progress,
  a recoverable problem, a failure) → **replace it with a severity-appropriate `Rails.logger`
  call**, so the message routes through the configured log level instead of dumping to stdout (which
  is what makes it noisy in test output).

Pick the level from the message's severity rather than applying one blanket replacement:

- `Rails.logger.info` — normal progress (`"Sending Test Email…"`, `"Converting #{show_title}…"`, `"Adding Team Members"`)
- `Rails.logger.warn` — recoverable problems (`"WARNING: Could not save…"`, `"…cannot be converted to a show"`)
- `Rails.logger.error` — actual failures

Where several adjacent `p` lines form one logical message, collapse them into a single
`Rails.logger.info` call. This is an application-code (or rake-task / service) fix, not a test
fix — it belongs in the code that emits the output, leaving assertions untouched.

For the separate case where a **test** needs to assert on logged output, keep the vendored advice:
refactor to `expect(Rails.logger).to receive(...)` (RSpec) or
`assert_*`/a stubbed logger (Minitest) instead of letting output leak.
