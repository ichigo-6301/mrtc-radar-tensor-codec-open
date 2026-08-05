#!/usr/bin/env python3
"""Command-line validator for sanitized RDTC-POWER-2A evidence."""

from __future__ import print_function

import argparse
import sys

from rdtc_power_2a_evidence import ValidationError, validate


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "evidence_dir",
        help="directory containing the schema-v3 manifest and canonical evidence files",
    )
    parser.add_argument("--require-promotion", action="store_true",
                        help="fail when any deterministic promotion gate is blocked")
    args = parser.parse_args(argv)
    try:
        result = validate(args.evidence_dir, require_promotion=args.require_promotion)
    except ValidationError as exc:
        print("FAIL: {}".format(exc), file=sys.stderr)
        return 1
    classifications = ",".join(row["classification"] for row in result["classifications"])
    print("PASS: points={} comparisons={} gates={} classifications={} promotion_eligible={}".format(
        len(result["points"]), len(result["comparisons"]), len(result["gates"]),
        classifications or "none", str(result["promotion_eligible"]).lower()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
