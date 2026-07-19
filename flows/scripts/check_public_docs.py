#!/usr/bin/env python3
"""Check public Markdown links and required bilingual release documentation."""

from __future__ import print_function

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote


LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")


def tracked_markdown(root):
    output = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "--", "*.md"])
    return [root / item.decode("utf-8") for item in output.split(b"\0") if item]


def check(root):
    errors = []
    required = [root / "docs/zh-CN/release_model.md", root / "docs/en/release_model.md"]
    for path in required:
        if not path.is_file():
            errors.append("missing required release document: {}".format(path.relative_to(root)))
    for path in tracked_markdown(root):
        text = path.read_text(encoding="utf-8")
        for match in LINK.finditer(text):
            target = match.group(1).strip().split()[0].strip("<>")
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            relative = unquote(target.split("#", 1)[0])
            if relative and not (path.parent / relative).resolve().is_file():
                errors.append("broken link: {} -> {}".format(path.relative_to(root), target))
    for name in ("README.md", "README.en.md"):
        text = (root / name).read_text(encoding="utf-8")
        for marker in ("register550-rc2", "rdtc_v1_register_nangate45_550", "rdtc_v1_sram_nangate45_333"):
            if marker not in text:
                errors.append("{} missing release marker {}".format(name, marker))
    return errors


def main():
    root = Path(__file__).resolve().parents[2]
    errors = check(root)
    if errors:
        print("documentation check: FAIL", file=sys.stderr)
        for error in errors:
            print("  " + error, file=sys.stderr)
        return 2
    print("documentation check: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

