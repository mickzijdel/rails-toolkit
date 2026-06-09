"""Tests for the rails-toolkit plugin's bundled scripts.

readoc-style — run each shipped script exactly as the plugin invokes it (a shell
hook via `bash ...`, fed JSON on stdin) and assert on its real output. Run with
`uv run pytest`.

The plugin currently ships one script: bin/rails-detect-hook, a SessionStart hook
that emits Rails-toolkit guidance as additionalContext when the cwd it is given is
a Rails app (a Gemfile mentioning the rails gem), and stays silent otherwise.
"""

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "bin" / "rails-detect-hook"


def _run(cwd_dir, stdin=None):
    """Run the hook with an optional `{"cwd": ...}` payload on stdin."""
    if stdin is None and cwd_dir is not None:
        stdin = json.dumps({"cwd": str(cwd_dir)})
    return subprocess.run(
        ["bash", str(HOOK)],
        input=stdin if stdin is not None else "",
        capture_output=True,
        text=True,
    )


def test_rails_app_emits_guidance(tmp_path):
    """A Gemfile that requires the rails gem triggers additionalContext output."""
    (tmp_path / "Gemfile").write_text(
        'source "https://rubygems.org"\ngem "rails", "~> 8.0"\n'
    )
    proc = _run(tmp_path)
    assert proc.returncode == 0
    payload = json.loads(proc.stdout)
    ctx = payload["hookSpecificOutput"]["additionalContext"]
    assert payload["hookSpecificOutput"]["hookEventName"] == "SessionStart"
    assert "rails-core" in ctx


def test_non_rails_dir_is_silent(tmp_path):
    """A directory with no Gemfile produces no output."""
    proc = _run(tmp_path)
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


def test_gemfile_without_rails_is_silent(tmp_path):
    """A Gemfile that does not mention the rails gem produces no output."""
    (tmp_path / "Gemfile").write_text('source "https://rubygems.org"\ngem "sinatra"\n')
    proc = _run(tmp_path)
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


def test_empty_stdin_falls_back_to_pwd_without_crashing(tmp_path):
    """No stdin → the hook falls back to $PWD and exits cleanly."""
    proc = subprocess.run(
        ["bash", str(HOOK)],
        input="",
        capture_output=True,
        text=True,
        cwd=str(tmp_path),  # a non-Rails cwd, so it stays silent
    )
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""
