"""Tests for the rails-toolkit plugin's bundled scripts.

readoc-style — run each shipped script exactly as the plugin invokes it (a shell
hook via `bash ...`, fed JSON on stdin) and assert on its real output. Run with
`uv run pytest`.

The plugin ships two scripts:

- bin/rails-detect-hook, a SessionStart hook that emits Rails-toolkit guidance as
  additionalContext when the cwd it is given is a Rails app (a Gemfile mentioning
  the rails gem), and stays silent otherwise.
- bin/rubocop-autocorrect-hook, a PostToolUse hook that safe-autocorrects an edited
  Ruby file and reports remaining offenses as additionalContext, but only when the
  edited file is Ruby AND the project opted into RuboCop (a .rubocop.yml). It
  no-ops silently in every other case. The tests below exercise those guard paths,
  which are independent of whether RuboCop is actually installed.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "bin" / "rails-detect-hook"
RUBOCOP_HOOK = ROOT / "bin" / "rubocop-autocorrect-hook"


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


def _run_rubocop_hook(file_path, cwd_dir):
    """Run the PostToolUse rubocop hook with a PostToolUse-shaped payload."""
    payload = json.dumps(
        {"cwd": str(cwd_dir), "tool_input": {"file_path": str(file_path)}}
    )
    return subprocess.run(
        ["bash", str(RUBOCOP_HOOK)],
        input=payload,
        capture_output=True,
        text=True,
    )


def test_rubocop_hook_ignores_non_ruby_file(tmp_path):
    """A non-Ruby file is skipped before any rubocop work — silent exit 0."""
    (tmp_path / ".rubocop.yml").write_text("{}\n")
    target = tmp_path / "README.md"
    target.write_text("# hi\n")
    proc = _run_rubocop_hook(target, tmp_path)
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


def test_rubocop_hook_silent_without_config(tmp_path):
    """A Ruby file in a project with no .rubocop.yml is left alone — silent exit 0."""
    target = tmp_path / "thing.rb"
    target.write_text("x=1\n")
    proc = _run_rubocop_hook(target, tmp_path)
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


def test_rubocop_hook_silent_for_missing_file(tmp_path):
    """A file_path that does not exist is skipped — silent exit 0."""
    (tmp_path / ".rubocop.yml").write_text("{}\n")
    proc = _run_rubocop_hook(tmp_path / "gone.rb", tmp_path)
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


def test_rubocop_hook_silent_without_file_path(tmp_path):
    """No file_path in the payload → nothing to do, silent exit 0."""
    proc = subprocess.run(
        ["bash", str(RUBOCOP_HOOK)],
        input=json.dumps({"cwd": str(tmp_path)}),
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


def test_rubocop_hook_empty_stdin_does_not_crash(tmp_path):
    """No stdin at all → the hook exits cleanly without output."""
    proc = subprocess.run(
        ["bash", str(RUBOCOP_HOOK)],
        input="",
        capture_output=True,
        text=True,
        cwd=str(tmp_path),
    )
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


@pytest.mark.skipif(
    shutil.which("rubocop") is None, reason="rubocop not installed in this environment"
)
def test_rubocop_hook_autocorrects_and_reports(tmp_path):
    """End-to-end: with a real rubocop, the hook fixes what it can in place and
    reports only the offenses it cannot autocorrect (skipped when rubocop absent).

    tmp_path lives under the system temp dir, whose ancestors carry no .rubocop.yml,
    so the config written here is the only one rubocop loads — the test is hermetic.
    """
    (tmp_path / ".rubocop.yml").write_text(
        "AllCops:\n"
        "  NewCops: disable\n"
        "Style/FrozenStringLiteralComment:\n"
        "  Enabled: false\n"
    )
    target = tmp_path / "thing.rb"
    # `( name )` spacing is autocorrectable; the camelCase method name is not.
    target.write_text("def myBadMethod( name )\n  name\nend\n")

    proc = _run_rubocop_hook(target, tmp_path)
    assert proc.returncode == 0

    # The autocorrectable offense was fixed in place.
    assert "( name )" not in target.read_text()

    # The non-autocorrectable offense is reported back as context.
    payload = json.loads(proc.stdout)
    ctx = payload["hookSpecificOutput"]["additionalContext"]
    assert payload["hookSpecificOutput"]["hookEventName"] == "PostToolUse"
    assert "Naming/MethodName" in ctx
    # Corrected offenses must not be nagged about.
    assert "[Corrected]" not in ctx
