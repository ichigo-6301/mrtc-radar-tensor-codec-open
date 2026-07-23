#!/usr/bin/env python3
"""Check public Markdown links and required bilingual release documentation."""

from __future__ import print_function

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote


LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

PRIMARY_SHOWCASE_DOCS = (
    "README.md",
    "README.en.md",
    "docs/zh-CN/results.md",
    "docs/en/results.md",
    "docs/zh-CN/asic_implementation.md",
    "docs/en/asic_implementation.md",
    "docs/zh-CN/limitations.md",
    "docs/en/limitations.md",
    "docs/zh-CN/roadmap.md",
    "docs/en/roadmap.md",
)

README_MARKERS = {
    "README.md": (
        "rdtc_overview.svg",
        "FPGA emulation verified",
        "single-`s0`",
        "公开 Icarus-compatible",
        "软件 reorder 程序 PASS",
        "synthetic",
        "SRAM overall profile 仍为 partial",
        "fixed verified closure point",
    ),
    "README.en.md": (
        "rdtc_overview.svg",
        "FPGA emulation verified",
        "single-`s0`",
        "public Icarus-compatible",
        "software reorder program PASS",
        "synthetic",
        "overall SRAM profile remains partial",
        "fixed verified closure point",
    ),
}


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
        for marker in ("register550-rc3", "rdtc_v1_register_nangate45_550", "rdtc_v1_sram_nangate45_333"):
            if marker not in text:
                errors.append("{} missing release marker {}".format(name, marker))
        for marker in README_MARKERS[name]:
            if marker not in text:
                errors.append("{} missing showcase boundary {}".format(name, marker))
    for name in PRIMARY_SHOWCASE_DOCS:
        text = (root / name).read_text(encoding="utf-8")
        if re.search(r"ICS55|ICsprout55|ECOS", text, flags=re.IGNORECASE):
            errors.append("{} contains archived ICS55/ECOS material".format(name))
    for name in ("docs/zh-CN/algorithm.md", "docs/en/algorithm.md"):
        text = (root / name).read_text(encoding="utf-8")
        marker = "../assets/matlab/rdb_before_after_rdtc_zero_rice.png"
        if marker not in text:
            errors.append("{} missing original MATLAB figure".format(name))
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
