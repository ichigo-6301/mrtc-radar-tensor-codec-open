#!/usr/bin/env python3
"""Create a PrimeTime-compatible SDC from the OpenROAD final SDC."""

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    source = Path(args.input)
    destination = Path(args.output)
    kept = []
    removed = 0
    for line in source.read_text(encoding="ascii").splitlines(keepends=True):
        if line.strip().startswith("current_design "):
            removed += 1
            continue
        kept.append(line)
    if removed != 1:
        raise SystemExit("expected exactly one OpenROAD current_design statement, found {}".format(removed))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("".join(kept), encoding="ascii")
    print("sanitized_sdc: input={} output={} removed_current_design={}".format(
        source, destination, removed
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
