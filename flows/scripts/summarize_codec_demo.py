#!/usr/bin/env python3
"""Summarize and verify the deterministic public codec demonstration."""

from __future__ import print_function

import argparse
import csv
import hashlib
import json
import sys
from pathlib import Path


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_summary(output_dir):
    with (output_dir / "result.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 1:
        raise RuntimeError("codec demo result must contain exactly one row")
    row = rows[0]
    if row.get("bit_exact") != "PASS":
        raise RuntimeError("codec demo did not report bit-exact PASS")

    input_path = output_dir / "input_iq_le.bin"
    packet_path = output_dir / "packet.bin"
    decoded_path = output_dir / "decoded_iq_le.bin"
    if input_path.read_bytes() != decoded_path.read_bytes():
        raise RuntimeError("decoded IQ bytes do not match the input")

    return {
        "artifact_format": "interleaved little-endian I16Q16",
        "bit_exact": row["bit_exact"],
        "case_name": row["case_name"],
        "codec_mode": row["codec_mode"],
        "decoded_iq_sha256": sha256(decoded_path),
        "input_definition": "I[n]=floor(n/8), Q[n]=-floor(n/16), n=0..1023",
        "input_iq_sha256": sha256(input_path),
        "num_samples": int(row["num_samples"]),
        "packet_bytes": int(row["packet_bytes"]),
        "packet_sha256": sha256(packet_path),
        "payload_bits": int(row["payload_bits"]),
        "payload_bytes": int(row["payload_bytes"]),
        "raw_bypass": bool(int(row["raw_bypass"])),
        "raw_bytes": int(row["raw_bytes"]),
        "selected_k": int(row["selected_k"]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--write-reference", action="store_true")
    args = parser.parse_args()

    summary = build_summary(args.output_dir)
    rendered = json.dumps(summary, indent=2, sort_keys=True) + "\n"
    if args.write_reference:
        args.reference.parent.mkdir(parents=True, exist_ok=True)
        args.reference.write_text(rendered, encoding="utf-8")
        print("codec demo: wrote {}".format(args.reference))
    elif rendered != args.reference.read_text(encoding="utf-8"):
        print("codec demo: FAIL reference is stale", file=sys.stderr)
        return 2
    print(
        "codec demo: PASS mode={codec_mode} samples={num_samples} packet_bytes={packet_bytes} "
        "selected_k={selected_k} bit_exact={bit_exact}".format(**summary)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
