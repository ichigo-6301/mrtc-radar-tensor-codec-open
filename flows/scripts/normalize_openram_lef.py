#!/usr/bin/env python3
"""Snap OpenRAM LEF geometry to a physical platform manufacturing grid."""

import argparse
import hashlib
import re
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path


NUMBER = re.compile(r"(?<![A-Za-z0-9_])[-+]?\d+(?:\.\d+)?(?![A-Za-z0-9_])")
DATABASE_MICRONS = re.compile(r"^(\s*DATABASE\s+MICRONS\s+)\d+(\s*;\s*)$")


def snap(value: str, grid: Decimal) -> str:
    number = Decimal(value)
    snapped = (number / grid).quantize(Decimal("1"), rounding=ROUND_HALF_UP) * grid
    rendered = format(snapped.normalize(), "f")
    return "0" if rendered in ("-0", "+0") else rendered


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--grid-microns", default="0.005")
    parser.add_argument("--database-microns", type=int)
    args = parser.parse_args()

    source = Path(args.input)
    destination = Path(args.output)
    grid = Decimal(args.grid_microns)
    if grid <= 0:
        raise SystemExit("grid must be positive")

    changed = 0
    database_lines = 0
    output_lines = []
    for line in source.read_text(encoding="ascii").splitlines(keepends=True):
        keyword = line.lstrip().split(None, 1)[0] if line.strip() else ""
        if keyword == "DATABASE" and args.database_microns is not None:
            ending = "\n" if line.endswith("\n") else ""
            content = line[:-1] if ending else line
            match = DATABASE_MICRONS.match(content)
            if not match:
                raise SystemExit("unsupported LEF DATABASE MICRONS line: {}".format(content))
            line = "{}{}{}{}".format(
                match.group(1), args.database_microns, match.group(2), ending
            )
            database_lines += 1
        if keyword in ("RECT", "POLYGON"):
            updated = NUMBER.sub(lambda match: snap(match.group(0), grid), line)
            changed += int(updated != line)
            line = updated
        output_lines.append(line)

    if args.database_microns is not None and database_lines != 1:
        raise SystemExit("expected one LEF DATABASE MICRONS line, found {}".format(database_lines))

    rendered = "".join(output_lines).encode("ascii")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists() or destination.read_bytes() != rendered:
        destination.write_bytes(rendered)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    print("normalized_lef: input={} output={} changed_lines={} grid_um={} database_microns={} sha256={}".format(
        source, destination, changed, grid, args.database_microns, digest
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
