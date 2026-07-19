#!/usr/bin/env python3
"""Restore an annotated release tag after CI checkout peels its local ref."""

from __future__ import print_function

import argparse
import subprocess
from pathlib import Path


def git(root, *args):
    return subprocess.check_output(
        ["git", "-C", str(root)] + list(args), text=True
    ).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("--root", default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = Path(args.root).resolve()
    ref = "refs/tags/" + args.tag
    subprocess.run(
        ["git", "-C", str(root), "fetch", "--force", "origin", ref + ":" + ref],
        check=True,
    )
    object_type = git(root, "cat-file", "-t", args.tag)
    if object_type != "tag":
        raise SystemExit("release tag is not annotated after restore: {}".format(args.tag))
    print(
        "restored annotated tag {} -> {}".format(
            args.tag, git(root, "rev-list", "-n", "1", args.tag)
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
