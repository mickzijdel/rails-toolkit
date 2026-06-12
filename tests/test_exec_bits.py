"""Executable-bit gate for shipped scripts (v15 of the dev-env standard).

A fresh clone or plugin-cache install receives the GIT INDEX mode, not the local
working-tree permissions — and with core.fileMode=false a local chmod +x never
reaches git. A shebang script tracked at 100644 therefore dies with exit 126
"Permission denied" on every other machine. This mirrors the hk
`exec-bit-scripts` pre-commit step and the CI lint-job step so the gates can't drift.
"""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _index_modes() -> dict[str, str]:
    """Map of tracked path -> git index mode (e.g. '100755').

    -z gives NUL-separated entries with unquoted paths, so a filename containing
    quotes or newlines can't dodge the scan (without it git C-quotes such paths
    and the shebang read below would open a non-existent literal path).
    """
    out = subprocess.run(
        ["git", "ls-files", "-s", "-z"],
        capture_output=True,
        text=True,
        check=True,
        cwd=ROOT,
    ).stdout
    modes = {}
    for line in out.split("\0"):
        if not line:
            continue
        meta, path = line.split("\t", 1)
        modes[path] = meta.split(" ", 1)[0]
    return modes


def _has_shebang(path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(2) == b"#!"
    except OSError:
        return False


def test_shebang_scripts_are_executable_in_git_index():
    """Any tracked file whose first line is a shebang must be index mode 100755.

    Fix: git update-index --chmod=+x <file>
    """
    modes = _index_modes()
    bad = [
        path
        for path, mode in modes.items()
        if mode == "100644" and _has_shebang(ROOT / path)
    ]
    assert not bad, (
        "shebang scripts missing the executable bit in the git index "
        "(fix: git update-index --chmod=+x <file>):\n" + "\n".join(bad)
    )
    # Sanity-check the detection: known shipped scripts must be among the
    # executables, otherwise the shebang scan is silently matching nothing.
    assert modes.get("bin/rails-detect-hook") == "100755"
    assert modes.get("scripts/run-jscpd.sh") == "100755"
