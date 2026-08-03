#!/usr/bin/env python3
"""Validate the published fixed-workload Bitpacker pipeline A/B evidence."""

from __future__ import print_function

import argparse
import csv
import datetime
import hashlib
import math
from pathlib import Path

import yaml


EVIDENCE_ID = "rdtc_v1_bitpacker_pipeline_ab_public"
CLAIM_ID = "rdtc_v1_bitpacker_pipeline_cycle_speedup"
BLOCK_CLAIM_ID = "rdtc_v1_single_engine_block_interval_speedup"
NONCLAIM_ID = "rdtc_v1_bitpacker_ab_no_system_speedup"
BLOCK_NONCLAIM_ID = "rdtc_v1_single_engine_interval_no_latency_or_direct"
EVIDENCE_PATH = "evidence/rdtc_v1_bitpacker_pipeline_ab.yaml"
CSV_PATH = "evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv"
MULTIENGINE_CSV_PATH = "evidence/data/rdtc_v1_multiengine_scaling.csv"
EXPECTED_CSV_FIELDS = [
    "point",
    "role",
    "source_branch",
    "source_commit",
    "mode",
    "scenario",
    "workload",
    "payload_first_valid_cycle",
    "packet_last_cycle",
    "payload_stream_cycles",
    "steady_state_scenario",
    "steady_state_blocks",
    "steady_state_cycles_per_block",
    "selected_k",
    "payload_bits",
    "payload_bytes",
    "packet_bytes",
    "input_stall_cycles",
    "output_stall_cycles",
    "payload_byte_exact",
    "packet_byte_exact",
    "decoder_loopback",
    "fresh_replay_status",
]
EXPECTED_MONITOR_BLOB = "f994a0b4f820b698bcc229d2cd6f4f0d06075f18"
EXPECTED_ROWS = {
    "baseline": {
        "point": "stage16c3",
        "source_commit": "327c463896bda94c60eb2b47d3c3dfc61a183367",
        "scenario": "prefix_capture_zero_sparse",
        "payload_first_valid_cycle": 1169,
        "packet_last_cycle": 8861,
        "payload_stream_cycles": 7693,
        "steady_state_scenario": "prefix_capture_256_block_beam",
        "steady_state_blocks": 256,
        "steady_state_cycles_per_block": 8220,
    },
    "optimized": {
        "point": "stage16d2",
        "source_commit": "2c1d9a75d2742659b604dd3f9c754096e196d132",
        "scenario": "prefix_lane4_zero_sparse",
        "payload_first_valid_cycle": 706,
        "packet_last_cycle": 1426,
        "payload_stream_cycles": 721,
        "steady_state_scenario": "prefix_lane4_256_block_beam",
        "steady_state_blocks": 256,
        "steady_state_cycles_per_block": 785,
    },
}
EXPECTED_FILE_HASHES = {
    "vectors/rdtc_v1/smoke_zero_sparse/axis_raw_in.hex": "db8e83367cd0219edd004d3f1ad4e35099afd5b906d6e26f4f976ca9affe4b46",
    "vectors/rdtc_v1/smoke_zero_sparse/manifest.json": "1924010e24a27805b452039c62985b727b3356cc625f93539c115c3969b6c1cc",
    "vectors/rdtc_v1/smoke_zero_sparse/axis_comp_expected.hex": "99dbb08d3df40b67653d1f4cb8500fe44e8f93a0e2ddf23f901678bca04d2ef9",
}
EXPECTED_WORKLOAD = {
    "name": "smoke_zero_sparse",
    "input": "vectors/rdtc_v1/smoke_zero_sparse/axis_raw_in.hex",
    "input_sha256": "db8e83367cd0219edd004d3f1ad4e35099afd5b906d6e26f4f976ca9affe4b46",
    "manifest": "vectors/rdtc_v1/smoke_zero_sparse/manifest.json",
    "manifest_sha256": "1924010e24a27805b452039c62985b727b3356cc625f93539c115c3969b6c1cc",
    "expected_packet": "vectors/rdtc_v1/smoke_zero_sparse/axis_comp_expected.hex",
    "expected_packet_sha256": "99dbb08d3df40b67653d1f4cb8500fe44e8f93a0e2ddf23f901678bca04d2ef9",
    "monitor_path": "tb/sv/mrtc_encoder_latency_monitor.sv",
    "baseline_monitor_git_blob": "f994a0b4f820b698bcc229d2cd6f4f0d06075f18",
    "optimized_monitor_git_blob": "f994a0b4f820b698bcc229d2cd6f4f0d06075f18",
}
EXPECTED_EQUIVALENCE = {
    "selected_k": 0,
    "payload_bits": 2158,
    "payload_bytes": 270,
    "packet_bytes": 334,
    "input_stall_cycles": 0,
    "output_stall_cycles": 0,
    "payload_byte_exact": True,
    "packet_byte_exact": True,
    "baseline_decoder_loopback": "pass",
    "optimized_decoder_loopback": "pass",
}
EXPECTED_SOURCE_HASHES = {
    "baseline_latency": "974f6bd134e6a706e78746252a80239006f36609da8e74a130c640150e610d5c",
    "baseline_throughput": "beb06f66ab286a66647be4ef1fd24856b1d1f1bd9a4ec4ca7055ea9279b5fd27",
    "optimized_latency": "d78a04854ff297e679a7ed030edd23b90564efc8d6fc3c41b992da8dffd966e3",
    "optimized_throughput": "5f4558040382b439ce688bed749f13ea69994d61fd3e8931f72e703c328f5b7a",
    "optimized_packet_compare": "e6b01207b1c78ddf412dd62dd9f25eeeebdf2a1146ae869f09c89fc7dfa0f2ab",
}
EXPECTED_POINTS = {
    "baseline": {
        "branch": "stage16c3-prefix-during-capture",
        "source_commit": "327c463896bda94c60eb2b47d3c3dfc61a183367",
        "mode": "PREFIX_FAST_STREAM_LENGTH_CAPTURE_PREFIX",
        "scenario": "prefix_capture_zero_sparse",
        "source_latency_csv": "docs/reports/data/stage16c3_latency/latency_per_block.csv",
        "source_latency_csv_git_blob": "5caec459dc0810e3bd54e75498fe61ba2bb8d6bb",
        "source_latency_csv_sha256": "974f6bd134e6a706e78746252a80239006f36609da8e74a130c640150e610d5c",
        "source_throughput_csv": "docs/reports/data/stage16c3_latency/throughput_summary.csv",
        "source_throughput_csv_git_blob": "799cd70c9ea61155c6825c5aa22d61299a0e1aa3",
        "source_throughput_csv_sha256": "beb06f66ab286a66647be4ef1fd24856b1d1f1bd9a4ec4ca7055ea9279b5fd27",
        "payload_first_valid_cycle": 1169,
        "packet_last_cycle": 8861,
        "payload_stream_cycles": 7693,
        "steady_state_scenario": "prefix_capture_256_block_beam",
        "steady_state_blocks": 256,
        "steady_state_cycles_per_block": 8220,
    },
    "optimized": {
        "branch": "stage16d2-integrate-lane4-bitpacker",
        "source_commit": "2c1d9a75d2742659b604dd3f9c754096e196d132",
        "mode": "PREFIX_FAST_STREAM_LENGTH_CAPTURE_PREFIX_LANE4_BPACK",
        "scenario": "prefix_lane4_zero_sparse",
        "source_latency_csv": "docs/reports/data/stage16d2_integrated_lane4/latency_per_block.csv",
        "source_latency_csv_git_blob": "a222dff12da80292596c21521a26213b2b260de2",
        "source_latency_csv_sha256": "d78a04854ff297e679a7ed030edd23b90564efc8d6fc3c41b992da8dffd966e3",
        "source_throughput_csv": "docs/reports/data/stage16d2_integrated_lane4/throughput_summary.csv",
        "source_throughput_csv_git_blob": "1c7e12127ee5f030d496f1cec656ef94d058e556",
        "source_throughput_csv_sha256": "5f4558040382b439ce688bed749f13ea69994d61fd3e8931f72e703c328f5b7a",
        "source_packet_compare_csv": "docs/reports/data/stage16d2_integrated_lane4/lane4_vs_legacy_packet_compare.csv",
        "source_packet_compare_csv_git_blob": "d43ae69842672c6a70d2f257848cc406951dec99",
        "source_packet_compare_csv_sha256": "e6b01207b1c78ddf412dd62dd9f25eeeebdf2a1146ae869f09c89fc7dfa0f2ab",
        "payload_first_valid_cycle": 706,
        "packet_last_cycle": 1426,
        "payload_stream_cycles": 721,
        "steady_state_scenario": "prefix_lane4_256_block_beam",
        "steady_state_blocks": 256,
        "steady_state_cycles_per_block": 785,
    },
}
EXPECTED_REPLAY = {
    "date": datetime.date(2026, 8, 1),
    "tool_version": "Model Technology ModelSim SE-64 vsim 2020.4 Simulator 2020.10 Oct 13 2020",
    "tool_executable_sha256": "011f110291dc69707d7118e8f8d712b91438e0c837f9bc10ce6bf53c1d048cfd",
    "baseline": {
        "source_commit": "327c463896bda94c60eb2b47d3c3dfc61a183367",
        "worktree_status": "clean",
        "commands": [
            "tb/scripts/run_stage16c3_latency_smoke.bat",
            "tb/scripts/run_rdtc_encoder_prefix_during_capture_smoke.bat",
        ],
        "return_code": 0,
        "raw_scenario_csv_sha256": "816d244cf1a6f738646e8c54e4c529d26c923eec0a5837d3d825786d66b6f65e",
        "compile_log_sha256": "183a18d8ee1f0172b168a2eb5ed4a836f40196569100d375631903deb1cd8d82",
        "latency_log_sha256": "89f4095435284820bdb79514f52ecb179074a44d6bb7c92b552fb55aaa5809ac",
        "loopback_log_sha256": "7853c1a791d59cea8566c0e736c1a0b22397ac6c3c22bd227d39a1d13c33e2ae",
    },
    "optimized": {
        "source_commit": "2c1d9a75d2742659b604dd3f9c754096e196d132",
        "worktree_status": "clean",
        "commands": [
            "tb/scripts/run_stage16d2_lane4_latency_smoke.bat",
            "tb/scripts/run_rdtc_encoder_prefix_lane4_active_smoke.bat",
            "tb/scripts/run_rdtc_encoder_prefix_lane4_active_loopback_smoke.bat",
        ],
        "return_code": 0,
        "raw_scenario_csv_sha256": "b031a9cd9e2f8a133e76bd0acf43c854d5602eca8d5b8c4e817ab1884f0079b0",
        "compile_log_sha256": "7d64ff646f0ad957c99bb102e4aa1e345e478ec3a0463020d4c4f587cf481601",
        "latency_log_sha256": "611cea620f7ed45b79732b2978b3ca444da1cf5b0218cbcb2e02b2e8fd1d4a29",
        "packet_compare_csv_sha256": "520d4f91ce635b8b0ac6ec2c3f06ebe28becaea5aea115941b3c5d97b1c34951",
        "packet_compare_log_sha256": "bb9ac4a8c7d53c862357e557077a2fb0eee1dbbe58e3beb5af53284524928613",
        "loopback_log_sha256": "8a00b64aa4cc0bb5170c2adcbc87c2e8758ae81a8dac8148cdcf9ecd30333197",
    },
    "result": "pass",
}
EXPECTED_CLAIM = {
    "id": CLAIM_ID,
    "profile": "rdtc_v1_historical_lane4_bitpacker",
    "statement": "On one fixed smoke_zero_sparse RTL workload, the integrated four-lane word Bitpacker reduced the inclusive payload stream interval from 7693 to 721 cycles, a 10.6699029x speedup.",
    "metric": "payload_stream_cycle_speedup",
    "value": 10.669902912621358,
    "unit": "x",
    "benchmark": "fixed smoke_zero_sparse historical RTL workload",
    "configuration": "Stage16C3 prefix-during-capture baseline versus Stage16D2 integrated lane4 Bitpacker, identical vector and latency monitor, no input or output stalls",
    "source_ref": "2c1d9a75d2742659b604dd3f9c754096e196d132",
    "tool": "ModelSim SE-64 2020.4",
    "evidence": [EVIDENCE_ID],
    "status": "verified",
    "caveat": "The metric is the inclusive first-payload-valid to accepted-TLAST interval for one historical fixed RTL workload; it is not whole-block latency, Multi-Engine throughput, current Direct-AXIS sustained throughput, FPGA performance, ASIC frequency, or Fmax.",
    "public": True,
}
EXPECTED_BLOCK_CLAIM = {
    "id": BLOCK_CLAIM_ID,
    "profile": "rdtc_v1_historical_lane4_bitpacker",
    "statement": "On fixed 256-block ZERO_RICE single-Engine RTL streams, the integrated four-lane word Bitpacker reduced average packet-completion spacing from 8220 to 785 cycles/block, a 10.4713376x speedup.",
    "metric": "single_engine_steady_state_block_interval_speedup",
    "value": 10.471337579617835,
    "unit": "x",
    "benchmark": "fixed 256-block zero-sparse historical RTL stream",
    "configuration": "Stage16C3 versus Stage16D2 integrated lane4 Bitpacker; both points retain prefix-during-capture and emit identical 334-byte packets",
    "source_ref": "2c1d9a75d2742659b604dd3f9c754096e196d132",
    "tool": "ModelSim SE-64 2020.4",
    "evidence": [EVIDENCE_ID],
    "status": "verified",
    "caveat": "This is average single-Engine packet-completion spacing over fixed 256-block streams, not one-block latency, current Direct-AXIS throughput, FPGA timing, ASIC frequency, or Fmax.",
    "public": True,
}
EXPECTED_REGISTRATION = {
    "id": EVIDENCE_ID,
    "path": EVIDENCE_PATH,
    "type": "historical_fixed_workload_rtl_pipeline_ab",
    "source_ref": "2c1d9a75d2742659b604dd3f9c754096e196d132",
    "source_visibility": "private_fixed_commits",
    "public_evidence_scope": "curated two-point payload and single-Engine steady-state CSV, fixed source/workload identities, metric derivations, and fresh ModelSim replay hashes",
    "tool": "ModelSim SE-64 2020.4",
    "claims": [CLAIM_ID, BLOCK_CLAIM_ID],
    "public": True,
    "maturity": "verified",
}
EXPECTED_NONCLAIM = {
    "id": NONCLAIM_ID,
    "profile": "rdtc_v1_historical_lane4_bitpacker",
    "statement": "The historical 10.6699x Bitpacker result is not a whole-block, Multi-Engine, Direct-AXIS sustained-throughput, FPGA-performance, ASIC-frequency, or Fmax claim.",
    "reason": "It measures only the inclusive interval from first payload valid to accepted packet TLAST on one fixed smoke_zero_sparse RTL workload.",
    "status": "not_claimed",
    "public": True,
}
EXPECTED_BLOCK_NONCLAIM = {
    "id": BLOCK_NONCLAIM_ID,
    "profile": "rdtc_v1_historical_lane4_bitpacker",
    "statement": "The historical 8220-to-785 cycles/block result is not one-block latency, current Direct-AXIS sustained throughput, FPGA timing, ASIC frequency, or Fmax.",
    "reason": "It is the average packet-completion spacing over fixed 256-block single-Engine streams; both A/B points already retain prefix-during-capture.",
    "status": "not_claimed",
    "public": True,
}
EXPECTED_METRIC_DEFINITION = {
    "name": "payload_stream_cycles",
    "formula": "packet_last_cycle - payload_first_valid_cycle + 1",
    "interval": "inclusive",
    "packet_last_event": "accepted packet TLAST",
}
EXPECTED_STEADY_STATE_METRIC_DEFINITION = {
    "name": "single_engine_steady_state_cycles_per_block",
    "formula": "average packet-completion spacing over the fixed 256-block stream",
    "interval": "packet_last_cycle[n] - packet_last_cycle[n-1]",
    "scope": "single Engine with prefix-during-capture enabled at both A/B points",
}
EXPECTED_STEADY_STATE_WORKLOAD_IDENTITY = {
    "source_case": "smoke_zero_sparse",
    "source_tree_git_sha": "2f361efc2ff32115d7cc2037d0bc7939da6d5d92",
    "identical_source_tree_at_commits": {
        "baseline": "327c463896bda94c60eb2b47d3c3dfc61a183367",
        "optimized": "2c1d9a75d2742659b604dd3f9c754096e196d132",
        "multiengine": "8628ee4d561bf4ee4a97a02c800e1c52c9e9a28a",
    },
    "source_vector_path": "vectors/rdtc_v1/smoke_zero_sparse/block_000_axis_raw_in.hex",
    "source_vector_git_blob": "88135ef82cfb15c601964fe1d9072b19e22421f5",
    "source_vector_sha256": "db8e83367cd0219edd004d3f1ad4e35099afd5b906d6e26f4f976ca9affe4b46",
    "source_manifest_path": "vectors/rdtc_v1/smoke_zero_sparse/manifest.json",
    "source_manifest_git_blob": "5f3821f7e52a15edeea5b1e37c4a6eef94f507e6",
    "source_manifest_sha256": "1924010e24a27805b452039c62985b727b3356cc625f93539c115c3969b6c1cc",
    "single_engine_generator": {
        "path": "scripts/stage16c3_gen_latency_vectors.py",
        "git_blob": "585d7372faa58af44ec8df32a9e65f6a5f1b6c8b",
        "sha256": "42fac83943b1d13c65f1cb5d1981c0b6b31837f1182092b152c768be56c681f0",
        "generated_case": "prefix_256_block_beam",
        "repeat_count": 256,
        "identical_at_baseline_and_optimized_commits": True,
    },
    "multiengine_generator": {
        "source_commit": "8628ee4d561bf4ee4a97a02c800e1c52c9e9a28a",
        "path": "scripts/stage16f1_gen_vectors.py",
        "git_blob": "4a9ec8bc7b8b0c55b1e1277b59ba9d9f20973d60",
        "sha256": "87eae094f9608003efbbcbd74edcbbb245aa555cea7874b94fe626fb0e0cc42f",
        "generated_case": "prefix_256_block_beam",
        "repeat_count": 256,
        "reuses_source_vector_and_manifest": True,
    },
    "public_multiengine_binding": {
        "evidence": "evidence/rdtc_v1_multiengine_rtl.yaml",
        "curated_data": MULTIENGINE_CSV_PATH,
        "engine_count": 1,
        "workload_blocks": 256,
        "effective_cycles_per_block": 785.0,
        "measurement_scope": "imported Stage16D2 single-Engine reference; not a wrapper NUM_ENGINES=1 rerun",
    },
}
EXPECTED_CAVEATS = [
    "The 10.6699x value is the inclusive first-payload-valid to accepted-TLAST interval on one fixed historical RTL workload.",
    "The 10.4713x value is average packet-completion spacing over fixed 256-block single-Engine streams; it is not one-block latency.",
    "Both A/B points retain prefix-during-capture, so the measured delta isolates the integrated Lane4 Bitpacker rather than attributing the full change to front-end ping-pong.",
    "Neither metric is current Direct-AXIS sustained throughput, FPGA performance, ASIC frequency, or Fmax.",
    "The 256-block workload identity closes over the common source vector/manifest and deterministic repeat generators; generated runtime directories were not committed and have no independent artifact hashes.",
    "The Multi-Engine chart's one-Engine row imports the same-workload Stage16D2 reference; it is not a separate wrapper NUM_ENGINES=1 measurement.",
    "Historical source commits and raw ModelSim logs remain private; this public record publishes curated values and immutable identities only.",
]
EXPECTED_EVIDENCE_FIELDS = {
    "title",
    "status",
    "source_visibility",
    "public_evidence_scope",
    "curated_data",
    "curated_data_sha256",
    "tool",
    "workload",
    "metric_definition",
    "steady_state_metric_definition",
    "steady_state_workload_identity",
    "points",
    "equivalence",
    "derivation",
    "fresh_replay",
    "result",
    "caveats",
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


def require_exact_mapping(actual, expected, context):
    require(isinstance(actual, dict), context + " must be a mapping")
    require(set(actual) == set(expected), context + " fields mismatch")
    for field, value in expected.items():
        actual_value = actual.get(field)
        require(type(actual_value) is type(value), context + " " + field + " type mismatch")
        if isinstance(value, dict):
            require_exact_mapping(actual_value, value, context + " " + field)
        else:
            require(actual_value == value, context + " " + field + " mismatch")


def validate(root):
    root = Path(root).resolve()
    evidence_path = root / EVIDENCE_PATH
    csv_path = root / CSV_PATH
    evidence = load_yaml(evidence_path)

    require(set(evidence) == EXPECTED_EVIDENCE_FIELDS, "evidence fields mismatch")
    require(evidence.get("title") == "RDTC v1 historical Bitpacker pipeline fixed-workload RTL A/B", "evidence title mismatch")
    require(evidence.get("status") == "verified", "evidence status must be verified")
    require(evidence.get("result") == "pass", "evidence result must be pass")
    require(evidence.get("source_visibility") == "private_fixed_commits", "evidence source visibility mismatch")
    require(
        evidence.get("public_evidence_scope")
        == "curated two-point payload and single-Engine steady-state CSV, fixed source/workload identities, metric derivations, and fresh ModelSim replay hashes",
        "public evidence scope mismatch",
    )
    require(evidence.get("curated_data") == CSV_PATH, "curated CSV path mismatch")
    require(evidence.get("curated_data_sha256") == sha256(csv_path), "curated CSV hash mismatch")
    require_exact_mapping(evidence.get("metric_definition"), EXPECTED_METRIC_DEFINITION, "metric definition")
    require_exact_mapping(
        evidence.get("steady_state_metric_definition"),
        EXPECTED_STEADY_STATE_METRIC_DEFINITION,
        "steady-state metric definition",
    )
    steady_state_workload = evidence.get("steady_state_workload_identity")
    require_exact_mapping(
        steady_state_workload,
        EXPECTED_STEADY_STATE_WORKLOAD_IDENTITY,
        "steady-state workload identity",
    )
    require(
        sha256(root / steady_state_workload["source_vector_path"])
        == steady_state_workload["source_vector_sha256"],
        "steady-state source vector hash mismatch",
    )
    require(
        sha256(root / steady_state_workload["source_manifest_path"])
        == steady_state_workload["source_manifest_sha256"],
        "steady-state source manifest hash mismatch",
    )
    with (root / MULTIENGINE_CSV_PATH).open("r", encoding="utf-8", newline="") as stream:
        multiengine_rows = list(csv.DictReader(stream))
    multiengine_single = [row for row in multiengine_rows if row.get("engine_count") == "1"]
    require(len(multiengine_single) == 1, "Multi-Engine CSV must contain exactly one single-Engine reference row")
    multiengine_single = multiengine_single[0]
    multiengine_binding = steady_state_workload["public_multiengine_binding"]
    require(int(multiengine_single["workload_blocks"]) == multiengine_binding["workload_blocks"], "Multi-Engine workload block count mismatch")
    require(math.isclose(float(multiengine_single["effective_cycles_per_block"]), multiengine_binding["effective_cycles_per_block"], rel_tol=0.0, abs_tol=1.0e-12), "Multi-Engine single-Engine reference mismatch")
    require(evidence.get("caveats") == EXPECTED_CAVEATS, "evidence caveats mismatch")

    workload = evidence.get("workload", {})
    require_exact_mapping(workload, EXPECTED_WORKLOAD, "workload")
    require(workload["baseline_monitor_git_blob"] == EXPECTED_MONITOR_BLOB, "baseline monitor identity mismatch")
    require(workload["optimized_monitor_git_blob"] == EXPECTED_MONITOR_BLOB, "optimized monitor identity mismatch")
    for relative, digest in EXPECTED_FILE_HASHES.items():
        yaml_hash_field = {
            EXPECTED_WORKLOAD["input"]: "input_sha256",
            EXPECTED_WORKLOAD["manifest"]: "manifest_sha256",
            EXPECTED_WORKLOAD["expected_packet"]: "expected_packet_sha256",
        }[relative]
        require(workload[yaml_hash_field] == digest, "workload published hash mismatch: " + relative)
        require(sha256(root / relative) == digest, "workload file hash mismatch: " + relative)

    equivalence = evidence.get("equivalence", {})
    require_exact_mapping(equivalence, EXPECTED_EQUIVALENCE, "equivalence")

    points = evidence.get("points", {})
    require(set(points) == set(EXPECTED_POINTS), "evidence point roles mismatch")
    for role, expected in EXPECTED_POINTS.items():
        require_exact_mapping(points.get(role), expected, role + " evidence point")
    require(points["baseline"]["source_latency_csv_sha256"] == EXPECTED_SOURCE_HASHES["baseline_latency"], "baseline source CSV hash mismatch")
    require(points["baseline"]["source_throughput_csv_sha256"] == EXPECTED_SOURCE_HASHES["baseline_throughput"], "baseline throughput CSV hash mismatch")
    require(points["optimized"]["source_latency_csv_sha256"] == EXPECTED_SOURCE_HASHES["optimized_latency"], "optimized source CSV hash mismatch")
    require(points["optimized"]["source_throughput_csv_sha256"] == EXPECTED_SOURCE_HASHES["optimized_throughput"], "optimized throughput CSV hash mismatch")
    require(points["optimized"]["source_packet_compare_csv_sha256"] == EXPECTED_SOURCE_HASHES["optimized_packet_compare"], "packet compare source hash mismatch")

    with csv_path.open("r", encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        require(reader.fieldnames == EXPECTED_CSV_FIELDS, "curated CSV header mismatch")
        rows = list(reader)
    require(len(rows) == 2, "curated CSV must contain exactly two rows")
    for row in rows:
        require(set(row) == set(EXPECTED_CSV_FIELDS), "curated CSV row fields mismatch")
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
        require(row["steady_state_scenario"] == expected["steady_state_scenario"], role + " steady-state scenario mismatch")
        require(int(row["steady_state_blocks"]) == expected["steady_state_blocks"] == 256, role + " steady-state block count mismatch")
        require(int(row["steady_state_cycles_per_block"]) == expected["steady_state_cycles_per_block"], role + " steady-state cycles/block mismatch")
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
        for field in (
            "selected_k",
            "payload_bits",
            "payload_bytes",
            "packet_bytes",
            "input_stall_cycles",
            "output_stall_cycles",
        ):
            require(int(row[field]) == equivalence[field], role + " CSV/equivalence " + field + " mismatch")
        require(bool(int(row["payload_byte_exact"])) == equivalence["payload_byte_exact"], role + " CSV/equivalence payload exactness mismatch")
        require(bool(int(row["packet_byte_exact"])) == equivalence["packet_byte_exact"], role + " CSV/equivalence packet exactness mismatch")
        require(
            ("pass" if int(row["decoder_loopback"]) else "fail") == equivalence[role + "_decoder_loopback"],
            role + " CSV/equivalence decoder loopback mismatch",
        )
        point = points[role]
        for csv_field, point_field in (
            ("source_branch", "branch"),
            ("source_commit", "source_commit"),
            ("mode", "mode"),
            ("scenario", "scenario"),
            ("payload_first_valid_cycle", "payload_first_valid_cycle"),
            ("packet_last_cycle", "packet_last_cycle"),
            ("payload_stream_cycles", "payload_stream_cycles"),
            ("steady_state_scenario", "steady_state_scenario"),
            ("steady_state_blocks", "steady_state_blocks"),
            ("steady_state_cycles_per_block", "steady_state_cycles_per_block"),
        ):
            csv_value = row[csv_field]
            if csv_field.endswith("_cycle") or csv_field in (
                "payload_stream_cycles",
                "steady_state_blocks",
                "steady_state_cycles_per_block",
            ):
                csv_value = int(csv_value)
            require(csv_value == point[point_field], role + " YAML/CSV " + point_field + " mismatch")

    baseline = float(by_role["baseline"]["payload_stream_cycles"])
    optimized = float(by_role["optimized"]["payload_stream_cycles"])
    speedup = baseline / optimized
    reduction = 100.0 * (baseline - optimized) / baseline
    block_baseline = float(by_role["baseline"]["steady_state_cycles_per_block"])
    block_optimized = float(by_role["optimized"]["steady_state_cycles_per_block"])
    block_speedup = block_baseline / block_optimized
    block_reduction = 100.0 * (block_baseline - block_optimized) / block_baseline
    derivation = evidence.get("derivation", {})
    require(
        set(derivation) == {
            "cycle_reduction",
            "cycle_reduction_percent",
            "speedup",
            "steady_state_cycle_reduction",
            "steady_state_cycle_reduction_percent",
            "steady_state_speedup",
        },
        "derivation fields mismatch",
    )
    cycle_reduction = derivation.get("cycle_reduction")
    require(type(cycle_reduction) is int, "cycle reduction must be an integer")
    require(cycle_reduction == int(baseline - optimized) == 6972, "cycle reduction mismatch")
    published_speedup = derivation.get("speedup")
    published_reduction = derivation.get("cycle_reduction_percent")
    require(type(published_speedup) is float and math.isfinite(published_speedup), "speedup must be a finite float")
    require(type(published_reduction) is float and math.isfinite(published_reduction), "cycle reduction percentage must be a finite float")
    require(math.isclose(published_speedup, speedup, rel_tol=0.0, abs_tol=1.0e-12), "speedup mismatch")
    require(math.isclose(published_reduction, reduction, rel_tol=0.0, abs_tol=1.0e-12), "cycle reduction percentage mismatch")
    require(derivation.get("steady_state_cycle_reduction") == 7435, "steady-state cycle reduction mismatch")
    require(math.isclose(float(derivation.get("steady_state_speedup")), block_speedup, rel_tol=0.0, abs_tol=1.0e-12), "steady-state speedup mismatch")
    require(math.isclose(float(derivation.get("steady_state_cycle_reduction_percent")), block_reduction, rel_tol=0.0, abs_tol=1.0e-12), "steady-state reduction percentage mismatch")

    require(evidence.get("tool") == "ModelSim SE-64 2020.4", "evidence tool identity mismatch")
    replay = evidence.get("fresh_replay", {})
    require_exact_mapping(replay, EXPECTED_REPLAY, "fresh replay")

    claims_doc = load_yaml(root / "provenance/claims.yaml")
    evidence_doc = load_yaml(root / "provenance/evidence.yaml")
    nonclaims_doc = load_yaml(root / "provenance/nonclaims.yaml")
    claim_items = claims_doc.get("claims", [])
    evidence_items = evidence_doc.get("evidence", [])
    claims = {item["id"]: item for item in claim_items}
    evidence_index = {item["id"]: item for item in evidence_items}
    nonclaim_items = nonclaims_doc.get("nonclaims", [])
    nonclaims = {item["id"]: item for item in nonclaim_items}
    require(len(claims) == len(claim_items), "duplicate claim identity")
    require(len(evidence_index) == len(evidence_items), "duplicate evidence identity")
    require(len(nonclaims) == len(nonclaim_items), "duplicate nonclaim identity")
    require(CLAIM_ID in claims, "missing Bitpacker A/B claim")
    require(BLOCK_CLAIM_ID in claims, "missing single-Engine block-interval claim")
    require(EVIDENCE_ID in evidence_index, "missing Bitpacker A/B evidence registration")
    require(NONCLAIM_ID in nonclaims, "missing Bitpacker A/B nonclaim")
    require(BLOCK_NONCLAIM_ID in nonclaims, "missing single-Engine interval nonclaim")
    claim = claims[CLAIM_ID]
    registration = evidence_index[EVIDENCE_ID]
    require_exact_mapping(claim, EXPECTED_CLAIM, "claim")
    require_exact_mapping(claims[BLOCK_CLAIM_ID], EXPECTED_BLOCK_CLAIM, "block interval claim")
    require(set(registration) == set(EXPECTED_REGISTRATION) | {"sha256"}, "evidence registration fields mismatch")
    for field, value in EXPECTED_REGISTRATION.items():
        require(registration.get(field) == value, "evidence registration " + field + " mismatch")
    require(registration.get("sha256") == sha256(evidence_path), "registered evidence hash mismatch")
    require_exact_mapping(nonclaims[NONCLAIM_ID], EXPECTED_NONCLAIM, "nonclaim")
    require_exact_mapping(nonclaims[BLOCK_NONCLAIM_ID], EXPECTED_BLOCK_NONCLAIM, "block interval nonclaim")
    require(math.isclose(float(claim.get("value")), speedup, rel_tol=0.0, abs_tol=1.0e-12), "claim speedup mismatch")
    require(math.isclose(float(claims[BLOCK_CLAIM_ID].get("value")), block_speedup, rel_tol=0.0, abs_tol=1.0e-12), "block interval claim speedup mismatch")
    return {
        "rows": len(rows),
        "speedup": speedup,
        "reduction_percent": reduction,
        "block_speedup": block_speedup,
        "block_reduction_percent": block_reduction,
    }


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
        "bitpacker pipeline A/B validation: PASS rows={rows} payload_speedup={speedup:.7f} payload_reduction={reduction_percent:.2f}% block_speedup={block_speedup:.7f} block_reduction={block_reduction_percent:.2f}%".format(
            **result
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
