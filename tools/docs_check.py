#!/usr/bin/env python3
"""Check the demo's documentation for completeness and command drift.

Checks:
- every local Markdown link target exists (and heading anchors resolve);
- every `make <target>` referenced in documentation exists in the Makefile;
- every numbered section of controls-core/docs/SIDECAR-GUIDE.md has a row in
  docs/GUIDE-COVERAGE.md;
- every `x-*` extension named by the guide is covered by that matrix.

This is intentionally dependency-free and fails closed when the sibling
controls-core checkout (or the guide) is missing.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTROLS = Path(os.environ.get("CONTROLS_CORE", ROOT.parent / "controls-core")).resolve()
MARKDOWN = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md")), *sorted((ROOT / "ci").glob("*.md"))]
COVERAGE = ROOT / "docs" / "GUIDE-COVERAGE.md"
MAKEFILE = ROOT / "Makefile"
GUIDE = CONTROLS / "docs" / "SIDECAR-GUIDE.md"

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.+?)\s*#*\s*$", re.MULTILINE)
MAKE_CMD = re.compile(r"\bmake\s+([^\s`;]+)")
TARGET = re.compile(r"^([A-Za-z0-9_.-]+):(?!=)", re.MULTILINE)


def slug(text: str) -> str:
    text = text.replace("`", "").lower()
    text = re.sub(r"[^\w\-\s]", "", text, flags=re.UNICODE)
    text = re.sub(r"\s+", "-", text.strip())
    return re.sub(r"-+", "-", text)


def anchors(path: Path) -> set[str]:
    return {slug(line) for line in HEADING.findall(path.read_text(encoding="utf-8"))}


def check_links() -> list[str]:
    errors: list[str] = []
    cache: dict[Path, set[str]] = {}
    for md in MARKDOWN:
        text = md.read_text(encoding="utf-8")
        for target in LINK.findall(text):
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            if target.startswith("#"):
                path, anchor = md, target[1:]
            else:
                file_part, _, anchor = target.partition("#")
                path = (md.parent / file_part).resolve()
                if not path.exists():
                    errors.append(f"{md.relative_to(ROOT)}: missing link target {target}")
                    continue
                if not anchor or path.suffix != ".md":
                    continue
            if path.suffix == ".md" and anchor:
                known = cache.setdefault(path, anchors(path))
                if anchor not in known:
                    errors.append(f"{md.relative_to(ROOT)}: missing anchor #{anchor} in {path.name}")
    return errors


def make_targets() -> set[str]:
    return set(TARGET.findall(MAKEFILE.read_text(encoding="utf-8")))


def code_segments(text: str) -> list[str]:
    fenced = re.findall(r"```.*?```", text, re.DOTALL)
    inline = re.findall(r"`([^`\n]+)`", text)
    return fenced + inline


def check_commands(targets: set[str]) -> list[str]:
    errors: list[str] = []
    for md in MARKDOWN:
        for segment in code_segments(md.read_text(encoding="utf-8")):
            for line in segment.splitlines():
                line = line.split("#", 1)[0]
                for token in MAKE_CMD.findall(line):
                    target = token.strip("`.,)")
                    if not target or target.startswith(("-", "$")) or "=" in target:
                        continue
                    if target not in targets:
                        errors.append(f"{md.relative_to(ROOT)}: make target {target!r} does not exist")
    return errors


def check_coverage() -> list[str]:
    errors: list[str] = []
    if not GUIDE.exists():
        return [f"missing guide at {GUIDE}; set CONTROLS_CORE to the sibling checkout"]
    guide = GUIDE.read_text(encoding="utf-8")
    coverage = COVERAGE.read_text(encoding="utf-8")
    for section in re.findall(r"^## (\d+)\.", guide, re.MULTILINE):
        if not re.search(rf"^\|\s*§{section}\b", coverage, re.MULTILINE):
            errors.append(f"coverage matrix has no row for guide §{section}")
    for ext in sorted(set(re.findall(r"`(x-[a-z0-9*-]+)`", guide))):
        if ext not in coverage:
            errors.append(f"coverage matrix does not mention guide extension {ext}")
    return errors


def main() -> int:
    errors = check_links()
    errors += check_commands(make_targets())
    errors += check_coverage()
    if errors:
        print("docs-check failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(
        f"docs-check OK: {len(MARKDOWN)} files, "
        f"{len(make_targets())} make targets, guide sections and extensions covered"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
