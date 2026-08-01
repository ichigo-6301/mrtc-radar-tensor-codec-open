#!/usr/bin/env python3
"""Validate the published fixed-workload Bitpacker pipeline A/B evidence."""

from __future__ import print_function

import argparse
import csv
import hashlib
import math
from pathlib import Path

import yaml


EVIDENCE_ID = "rdtc_v1_bitpacker_pipeline_ab_public"
CLAIM_ID = "rdtc_v1_bitpacker_pipeline_cycle_speedup"
EVIDENCE_PATH = "evidence/rdtc_v1_bitpacker_pipeline_ab.yaml"
CSV_PATH = "evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv"
EXPECTED_MONITOR_BLOB = "f994a0b4f820b698bcc229d2cd6f4f0d06075f18"
EXPECTED_ROWS = {
    "baseline": {
        "point": "stage16c3",
        "source_commit": "327c463896bda94c60eb2b47d3c3dfc61a183367",
        "scenario": "prefix_capture_zero_sparse",
        "payload_first_valid_cycle": 1169,
        "packet_last_cycle": 8861,
        "payload_stream_cycles": 7693,
    },
    "optimized": {
        "point": "stage16d2",
        "source_commit": "2c1d9a75d2742659b604dd3f9c754096e196d132",
        "scenario": "prefix_lane4_zero_sparse",
        "payload_first_valid_cycle": 706,
        "packet_last_cycle": 1426,
        "payload_stream_cycles": 721,
    },
}
EXPECTED_FILE_HASHES = {
    "vectors/rdtc_v1/smoke_zero_sparse/axis_raw_in.hex": "db8e83367cd0219edd004d3f1ad4e35099afd5b906d6e26f4f976ca9affe4b46",
    "vectors/rdtc_v1/smoke_zero_sparse/manifest.json": "1924010e24a27805b452039c62985b727b3356cc625f93539c115c3969b6c1cc",
    "vectors/rdtc_v1/smoke_zero_sparse/axis_comp_expected.hex": "99dbb08d3df40b67653d1f4cb8500fe44e8f93a0e2ddf23f901678bca04d2ef9",
}
EXPECTED_SOURCE_HASHES = {
    "baseline_latency": "974f6bd134e6a706e78746252a80239006f36609da8e74a130c640150e610d5c",
    "optimized_latency": "d78a04854ff297e679a7ed030edd23b90564efc8d6fc3c41b992da8dffd966e3",
    "optimized_packet_compare": "e6b01207b1c78ddf412dd62dd9f25eeeebdf2a1146ae869f09c89fc7dfa0f2ab",
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_yaml(path):
    with path.open("r", encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def validate(root):
    root = Path(root).resolve()
    evidence_path = root / EVIDENCE_PATH
    csv_path = root / CSV_PATH
    evidence = load_yaml(evidence_path)

    require(evidence.get("status") == "verified", "evidence status must be verified")
    require(evidence.get("result") == "pass", "evidence result must be pass")
    require(evidence.get("curated_data") == CSV_PATH, "curated CSV path mismatch")
    require(evidence.get("curated_data_sha256") == sha256(csv_path), "curated CSV hash mismatch")
    require(evidence.get("metric_definition", {}).get("interval") == "inclusive", "metric interval must be inclusive")
    require(
        evidence.get("metric_definition", {}).get("formula")
        == "packet_last_cycle - payload_first_valid_cycle + 1",
        "metric formula mismatch",
    )

    workload = evidence.get("workload", {})
    require(workload.get("baseline_monitor_git_blob") == EXPECTED_MONITOR_BLOB, "baseline monitor identity mismatch")
    require(workload.get("optimized_monitor_git_blob") == EXPECTED_MONITOR_BLOB, "optimized monitor identity mismatch")
    for relative, digest in EXPECTED_FILE_HASHES.items():
        require(sha256(root / relative) == digest, "workload file hash mismatch: " + relative)

    points = evidence.get("points", {})
    require(points.get("baseline", {}).get("source_latency_csv_sha256") == EXPECTED_SOURCE_HASHES["baseline_latency"], "baseline source CSV hash mismatch")
    require(points.get("optimized", {}).get("source_latency_csv_sha256") == EXPECTED_SOURCE_HASHES["optimized_latency"], "optimized source CSV hash mismatch")
    require(points.get("optimized", {}).get("source_packet_compare_csv_sha256") == EXPECTED_SOURCE_HASHES["optimized_packet_compare"], "packet compare source hash mismatch")

    with csv_path.open("r", encoding="utf-8", newline="") as stream:
        rows = list(csv.DictReader(stream))
    require(len(rows) == 2, "curated CSV must contain exactly two rows")
    by_role = {row["role"]: row for row in rows}
    require(set(by_role) == set(EXPECTED_ROWS), "curated CSV roles must be baseline and optimized")
    require(len({row["point"] for row in rows}) == 2, "point identities must be unique")

    for role, expected in EXPECTED_ROWS.items():
        row = by_role[role]
        for field in ("point", "source_commit", "scenario"):
            require(row[field] == expected[field], role + " " + field + " mismatch")
        first_cycle = int(row["payload_first_valid_cycle"])
        last_cycle = int(row["packet_last_cycle"])
        interval = int(row["payload_stream_cycles"])
        require(first_cycle == expected["payload_first_valid_cycle"], role + " first payload cycle mismatch")
        require(last_cycle == expected["packet_last_cycle"], role + " packet last cycle mismatch")
        require(interval == expected["payload_stream_cycles"], role + " payload interval mismatch")
        require(last_cycle - first_cycle + 1 == interval, role + " inclusive interval derivation mismatch")
        for field, value in (
            ("selected_k", 0),
            ("payload_bits", 2158),
            ("payload_bytes", 270),
            ("packet_bytes", 334),
            ("input_stall_cycles", 0),
            ("output_stall_cycles", 0),
            ("payload_byte_exact", 1),
            ("packet_byte_exact", 1),
            ("decoder_loopback", 1),
        ):
            require(int(row[field]) == value, role + " " + field + " mismatch")
        require(row["workload"] == "smoke_zero_sparse", role + " workload mismatch")
        require(row["fresh_replay_status"] == "pass", role + " replay did not pass")

    baseline = float(by_role["baseline"]["payload_stream_cycles"])
    optimized = float(by_role["optimized"]["payload_stream_cycles"])
    speedup = baseline / optimized
    reduction = 100.0 * (baseline - optimized) / baseline
    derivation = evidence.get("derivation", {})
    require(int(derivation.get("cycle_reduction")) == 6972, "cycle reduction mismatch")
    require(math.isclose(float(derivation.get("speedup")), speedup, rel_tol=0.0, abs_tol=1.0e-12), "speedup mismatch")
    require(math.isclose(float(derivation.get("cycle_reduction_percent")), reduction, rel_tol=0.0, abs_tol=1.0e-12), "cycle reduction percentage mismatch")

    replay = evidence.get("fresh_replay", {})
    require(replay.get("result") == "pass", "fresh replay result must be pass")
    require(replay.get("baseline", {}).get("return_code") == 0, "baseline replay return code mismatch")
    require(replay.get("optimized", {}).get("return_code") == 0, "optimized replay return code mismatch")

    claims_doc = load_yaml(root / "provenance/claims.yaml")
    evidence_doc = load_yaml(root / "provenance/evidence.yaml")
    claims = {item["id"]: item for item in claims_doc.get("claims", [])}
    evidence_index = {item["id"]: item for item in evidence_doc.get("evidence", [])}
    require(CLAIM_ID in claims, "missing Bitpacker A/B claim")
    require(EVIDENCE_ID in evidence_index, "missing Bitpacker A/B evidence registration")
    claim = claims[CLAIM_ID]
    registration = evidence_index[EVIDENCE_ID]
    require(claim.get("evidence") == [EVIDENCE_ID], "claim evidence link mismatch")
    require(registration.get("claims") == [CLAIM_ID], "evidence claim link mismatch")
    require(registration.get("path") == EVIDENCE_PATH, "registered evidence path mismatch")
    require(registration.get("sha256") == sha256(evidence_path), "registered evidence hash mismatch")
    require(math.isclose(float(claim.get("value")), speedup, rel_tol=0.0, abs_tol=1.0e-12), "claim speedup mismatch")
    return {"rows": len(rows), "speedup": speedup, "reduction_percent": reduction}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        result = validate(args.root)
    except (OSError, KeyError, TypeError, ValueError, RuntimeError) as error:
        print("bitpacker pipeline A/B validation: FAIL: {}".format(error))
        return 2
    print(
        "bitpacker pipeline A/B validation: PASS rows={rows} speedup={speedup:.7f} reduction={reduction_percent:.2f}%".format(
            **result
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
