"""Contract: a generated per-skill page exists only while its skill ships.

``website/scripts/generate-skill-docs.py`` writes a page per discovered skill but never *prunes*
pages for skills that were moved or merged. Once the catalogs and the sidebar are regenerated
they stop pointing at the leftovers, so an orphan page stays reachable only through cross-links
from other pages — and it still advertises ``Source | Bundled (installed by default)`` for a
skill that is no longer installed by default (or is not there under that name at all).

#98539 ("shipped-set slim") is what left the current drift behind: 15 skills moved to
``optional-skills/``, the six ``github-*`` skills were merged into one, and ``pdf`` absorbed
``ocr-and-documents``. 25 bundled pages survived that refactor.

Every generated page states the skill path it documents in its ``| Path |`` row, so a page can be
checked against the tree without re-implementing the generator. Reads the shipped ``.md``
artifacts and the skill tree only — never source text.
"""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_PAGES = REPO_ROOT / "website" / "docs" / "user-guide" / "skills"
GENERATOR = REPO_ROOT / "website" / "scripts" / "generate-skill-docs.py"
_PATH_ROW_RE = re.compile(r"^\|\s*Path\s*\|\s*`([^`]+)`", re.MULTILINE)


def _page_targets():
    """(page, skill path it claims) for every generated page that carries a Path row."""
    for page in sorted(SKILL_PAGES.rglob("*.md")):
        match = _PATH_ROW_RE.search(page.read_text(encoding="utf-8"))
        if match:
            yield page, match.group(1).replace("\\", "/")


def test_every_generated_page_documents_a_shipped_skill():
    """No page outlives the skill it documents.

    A deleted or moved skill must take its page with it (or the page must be repointed), otherwise
    the docs keep describing a skill the reader cannot install under that name.
    """
    orphans = [
        f"{page.relative_to(REPO_ROOT)} -> {target}"
        for page, target in _page_targets()
        if not (REPO_ROOT / target / "SKILL.md").exists()
    ]
    assert not orphans, (
        "per-skill pages document skills that no longer ship at that path "
        "(a moved/merged skill leaves these behind — prune or repoint the page):\n"
        + "\n".join(orphans)
    )


def _load_generator():
    """Import ``generate-skill-docs.py`` (the hyphen keeps it off a normal import)."""
    spec = importlib.util.spec_from_file_location("generate_skill_docs", GENERATOR)
    assert spec and spec.loader, f"cannot load {GENERATOR}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_generated_pages_match_the_generator_output():
    """A committed page is byte-for-byte what the generator renders from the skill tree.

    Every generated page carries the ``Path`` row of the skill it documents, so the skill
    tree and the page are two copies of one thing: editing ``SKILL.md`` without
    regenerating leaves the published page describing an older skill. The orphan check
    above cannot see that drift (the skill still ships), and CI never regenerates before
    reading the committed copy, so this compares the generator's in-memory output — the
    same code path ``main`` writes — against the committed artifacts.
    """
    generator = _load_generator()
    pages = generator.render_all_pages(generator.discover_skills())
    stale = [
        str(page.relative_to(REPO_ROOT))
        for page, expected in pages.items()
        if not page.exists() or page.read_text(encoding="utf-8") != expected
    ]
    assert not stale, (
        "generated skill pages differ from the generator's output "
        "(run `python3 website/scripts/generate-skill-docs.py` and commit the result):\n"
        + "\n".join(stale)
    )
