#!/usr/bin/env python3
"""Remove the narrow set of SKY130 attributes unsupported by LC O-2018.06."""

import argparse
import re
from pathlib import Path


INTERNAL_PIN_CELLS = {
    "sky130_fd_sc_hd__dlclkp_1",
    "sky130_fd_sc_hd__dlclkp_2",
    "sky130_fd_sc_hd__dlclkp_4",
    "sky130_fd_sc_hd__sdlclkp_1",
    "sky130_fd_sc_hd__sdlclkp_2",
    "sky130_fd_sc_hd__sdlclkp_4",
}

BIAS_PIN_CELLS = {
    "sky130_fd_sc_hd__lpflow_lsbuf_lh_hl_isowell_tap_1",
    "sky130_fd_sc_hd__lpflow_lsbuf_lh_hl_isowell_tap_2",
    "sky130_fd_sc_hd__lpflow_lsbuf_lh_hl_isowell_tap_4",
    "sky130_fd_sc_hd__lpflow_lsbuf_lh_isowell_tap_1",
    "sky130_fd_sc_hd__lpflow_lsbuf_lh_isowell_tap_2",
    "sky130_fd_sc_hd__lpflow_lsbuf_lh_isowell_tap_4",
}


def sanitize(source, destination):
    cell = None
    cell_depth = None
    depth = 0
    removed = []
    output = []
    cell_pattern = re.compile(r'^\s*cell\s*\(\s*"?([^"\s)]+)"?\s*\)\s*\{')
    for line_number, line in enumerate(source.read_text(encoding="utf-8").splitlines(True), 1):
        match = cell_pattern.match(line)
        if match:
            cell = match.group(1)
            cell_depth = depth
        remove = False
        if cell in INTERNAL_PIN_CELLS and re.match(
            r'^\s*related_ground_pin\s*:\s*"VNB"\s*;', line
        ):
            remove = True
        if cell in BIAS_PIN_CELLS and re.match(
            r'^\s*related_bias_pin\s*:\s*"VNB"\s*;', line
        ):
            remove = True
        if remove:
            removed.append({"line": line_number, "cell": cell, "text": line.strip()})
        else:
            output.append(line)
        depth += line.count("{") - line.count("}")
        if cell is not None and depth == cell_depth:
            cell = None
            cell_depth = None
    if len(removed) != 12:
        raise RuntimeError("expected exactly 12 LC compatibility removals, found {}".format(len(removed)))
    destination.write_text("".join(output), encoding="utf-8")
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    source = Path(args.input).resolve()
    destination = Path(args.output).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    removed = sanitize(source, destination)
    print("sky130-liberty-sanitize: PASS removed={} output={}".format(len(removed), destination))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
