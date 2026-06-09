Make sure to check all of the following and make sure they are up-to-date after making changes;
1. tool-specific documentation for tools you edited
2. skills for tools you edited
3. plugin.json
4. README.md
5. CLAUDE.md

Bump the plugin version on every commit. Patch version for small fixes, minor version for more substantial changes (new skill or tool).

# Development

This repo follows the dev-hooks dev-env standard (shell/Claude Code plugin stack, `DEV_ENV_VERSION` in `mise.toml`). Tools are pinned via mise + `mise.lock`; pre-commit checks run via hk and are mirrored in CI (`.github/workflows/ci.yml`).

- Provision tools: `mise trust && mise install` (hk, pkl, shellcheck, shfmt, ruff, uv, node, gitleaks).
- Install the git hook: `hk install`.
- Lint + audits (shellcheck/shfmt/ruff, vulture dead-code, jscpd duplication, gitleaks, large-file guard): `hk run check`.
- Tests: `uv run pytest` — every bundled script in `bin/` must have a test that runs it as a subprocess and asserts on real output (see `tests/test_scripts.py`).
- Any new Python script must be self-contained (PEP 723 inline deps, `#!/usr/bin/env -S uv run --script`).