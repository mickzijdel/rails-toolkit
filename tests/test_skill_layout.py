"""Which skills the plugin loads, and where its wrapper skills point.

Vendored third-party skills (git submodules under vendor/) must never load on their
own: a folder upstream adds would then reach Claude's context unreviewed. Each one is
reached through a rails-toolkit wrapper skill that names its vendored file by a path
relative to the wrapper's folder, so a submodule bump that moves that file breaks the
wrapper silently unless a test resolves the path.
"""

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VENDORED_PATH = re.compile(r"`(\.\./\.\./vendor/[^`]+)`")


def _skill_paths() -> list[str]:
    manifest = json.loads((ROOT / ".claude-plugin" / "plugin.json").read_text())
    skills = manifest.get("skills", [])
    return [skills] if isinstance(skills, str) else skills


def test_plugin_json_loads_no_vendored_skills():
    """plugin.json's skills paths stay out of vendor/; wrappers in skills/ reach them."""
    vendored = [p for p in _skill_paths() if "vendor" in Path(p).parts]
    assert not vendored, f"plugin.json loads vendored skills directly: {vendored}"


def test_wrapper_vendored_paths_exist():
    """Every ../../vendor/ path a skill names resolves inside its submodule."""
    wrappers = {}
    for skill_md in sorted((ROOT / "skills").glob("*/SKILL.md")):
        for rel in VENDORED_PATH.findall(skill_md.read_text()):
            wrappers.setdefault(skill_md.parent.name, []).append(rel)
            target = skill_md.parent / rel
            assert target.exists(), (
                f"{skill_md.relative_to(ROOT)} names {rel}, which doesn't exist "
                "(after a fresh clone, run: git submodule update --init)"
            )
    assert "../../vendor/rails-upgrade-skill/rails-upgrade/SKILL.md" in wrappers.get(
        "rails-upgrade", []
    )
    assert "rails-clean-test-output" in wrappers


def test_rails_upgrade_wrapper_keeps_the_skill_name():
    """rails-core and rails-audit link [[rails-upgrade]], so the wrapper keeps that name."""
    text = (ROOT / "skills" / "rails-upgrade" / "SKILL.md").read_text()
    assert re.search(r"^name: rails-upgrade$", text, re.M)
