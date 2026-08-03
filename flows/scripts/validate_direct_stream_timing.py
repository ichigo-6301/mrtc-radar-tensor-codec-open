#!/usr/bin/env python3
"""Collect and validate the fixed Direct-wrapper stream-timing evidence."""

from __future__ import print_function

import argparse
import csv
import hashlib
import json
import re
from pathlib import Path

import yaml


SOURCE_REF = "99dbd4b5ff29c04de36c4c7e5d802856351495fb"
EVIDENCE_ID = "rdtc_v1_direct_stream_timing_trace_public"
CLAIM_ID = "rdtc_v1_direct_stream_timing_protocol_pass"
NONCLAIM_ID = "rdtc_v1_direct_stream_timing_no_performance_generalization"
EVIDENCE_PATH = "evidence/rdtc_v1_direct_stream_timing_trace.yaml"
CSV_PATHS = {
    "nominal": "evidence/data/rdtc_v1_direct_stream_timing_nominal.csv",
    "backpressure": "evidence/data/rdtc_v1_direct_stream_timing_backpressure.csv",
}
TRACE_FIELDS = (
    "cycle",
    "input_fire",
    "input_owner",
    "input_block",
    "e0_prefix_done",
    "e0_k_valid",
    "e0_k",
    "e0_ring_wr",
    "e0_ring_wr_addr",
    "e0_ring_wr_block",
    "e0_ring_rd_req",
    "e0_ring_rd_req_addr",
    "e0_ring_rd_req_block",
    "e0_ring_rd_rsp",
    "e0_ring_rd_rsp_addr",
    "e0_ring_rd_rsp_block",
    "e0_block",
    "e1_prefix_done",
    "e1_k_valid",
    "e1_k",
    "e1_ring_wr",
    "e1_ring_wr_addr",
    "e1_ring_wr_block",
    "e1_ring_rd_req",
    "e1_ring_rd_req_addr",
    "e1_ring_rd_req_block",
    "e1_ring_rd_rsp",
    "e1_ring_rd_rsp_addr",
    "e1_ring_rd_rsp_block",
    "e1_block",
    "m_tvalid",
    "m_tready",
    "m_tdata",
    "m_tuser",
    "m_tlast",
    "output_owner",
    "output_block",
    "wrapper_error",
    "e0_error",
    "e1_error",
)
CSV_FIELDS = ("scenario",) + TRACE_FIELDS
BINARY_FIELDS = frozenset(
    (
        "input_fire",
        "e0_prefix_done",
        "e0_k_valid",
        "e0_ring_wr",
        "e0_ring_rd_req",
        "e0_ring_rd_rsp",
        "e1_prefix_done",
        "e1_k_valid",
        "e1_ring_wr",
        "e1_ring_rd_req",
        "e1_ring_rd_rsp",
        "m_tvalid",
        "m_tready",
        "m_tlast",
    )
)
HEX_WIDTHS = {"m_tdata": 32, "m_tuser": 2}
EXPECTED_SOURCE_HASHES = {
    "aggregate_sha256": "fd0bf2e33ac7c547ef1f88b7dd7be25165159509c1391190a6dc16ac4747659a",
    "filelist_sha256": "4ed6d78dd51f5dfdc1bbb00f122437539345522a16b80ca3512220e6cbeed7a9",
    "testbench_sha256": "b2dde0907ea19b0e5cff77a18847c59d9f756b514089ea8e8465e6791921a525",
    "runner_sha256": "6e527d89a87ecf39f7c9f7b1c631f7f0372d63a8ecc8d521e75991788b792f6c",
}
EXPECTED_SCENARIOS = {
    "nominal": {
        "raw_manifest_sha256": "badb3c1e18bdf8d1865f872aafbece9445c68b5ba3595c7b9b3f9021fe0a97de",
        "raw_compile_log_sha256": "12c55c7a0be57142b8c2276167d8f4789d3a95325fb8c8f9000537b1612b5eb2",
        "raw_run_log_sha256": "fcfba1ecf2990b6eec4f905880b15c0c3c6d400978912a04fbe0e7c4f814d246",
        "raw_cycle_trace_sha256": "1cde77a354c2d43aada390b275c009be42bf8473ec3e93b31b3115dbdd9e9071",
        "raw_cycle_rows": 5316,
        "backpressure_markers": [],
    },
    "backpressure": {
        "raw_manifest_sha256": "117f63ff60856885836151bd91acf0ea874be10ae9ef891646b68ed5866ac106",
        "raw_compile_log_sha256": "9fb694eff8c724ecd447620ca9a9804a9bbc20e04d6d3abb25fa1233406f01a3",
        "raw_run_log_sha256": "3b8b126591df02281c0257818e97e28ff6e51af5d67d61f7c82f22d390ee6244",
        "raw_cycle_trace_sha256": "49c36694683d98fc05d70529fe1cdfeadb170100015ce2adebf975d74b33323d",
        "raw_cycle_rows": 5316,
        "backpressure_markers": [
            {"kind": "header", "cycle": 51, "packet": 0, "beat": 1, "stall_cycles": 2},
            {"kind": "payload", "cycle": 86, "packet": 0, "beat": 4, "stall_cycles": 2},
        ],
    },
}
EXPECTED_PACKETS = {
    0: {"owner": 0, "beats": 20, "final_tuser": "0f", "final_valid_bytes": 16, "packet_bytes": 320},
    1: {"owner": 1, "beats": 72, "final_tuser": "0e", "final_valid_bytes": 15, "packet_bytes": 1151},
}
NORMALIZED_TRACE_SHA256 = "c0da722b93448cced40ad4ab602a77ce178ae0b8df41c90eb1c1a9226583f3cf"
TOOL_VERSION = "Model Technology ModelSim SE-64 vsim 2020.4 Simulator 2020.10 Oct 13 2020"
TOOL_SHA256 = "011f110291dc69707d7118e8f8d712b91438e0c837f9bc10ce6bf53c1d048cfd"


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_yaml(path):
    with Path(path).open("r", encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def _parse_csv_value(field, value, path, line_number):
    if re.search(r"[xXzZ]", value):
        raise ValueError("{}:{} contains X/Z in {}".format(path, line_number, field))
    if field in HEX_WIDTHS:
        if len(value) != HEX_WIDTHS[field] or not re.fullmatch(r"[0-9a-f]+", value):
            raise ValueError("{}:{} has malformed {}".format(path, line_number, field))
        return value
    try:
        return int(value, 10)
    except ValueError:
        raise ValueError("{}:{} has non-integer {}".format(path, line_number, field))


def read_trace_csv(path, scenario):
    rows = []
    with Path(path).open("r", encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != CSV_FIELDS:
            raise ValueError("{} field contract mismatch".format(path))
        for line_number, raw in enumerate(reader, 2):
            if raw["scenario"] != scenario:
                raise ValueError("{}:{} scenario mismatch".format(path, line_number))
            row = {"scenario": scenario}
            for field in TRACE_FIELDS:
                row[field] = _parse_csv_value(field, raw[field], path, line_number)
            rows.append(row)
    if not rows:
        raise ValueError("{} contains no trace rows".format(path))
    return rows


def active_window(rows):
    first = next((index for index, row in enumerate(rows) if int(row["input_fire"])), None)
    last = next(
        (
            index
            for index in range(len(rows) - 1, -1, -1)
            if int(rows[index]["m_tvalid"])
            and int(rows[index]["m_tready"])
            and int(rows[index]["m_tlast"])
        ),
        None,
    )
    if first is None or last is None or first > last:
        raise ValueError("trace does not contain a complete active packet window")
    selected = rows[first : last + 1]
    cycles = [int(row["cycle"]) for row in selected]
    if cycles != list(range(cycles[0], cycles[-1] + 1)):
        raise ValueError("raw trace is not cycle-contiguous")
    return selected


def write_trace_csv(path, scenario, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS, lineterminator="\n")
        writer.writeheader()
        for raw in active_window(rows):
            row = {"scenario": scenario}
            row.update({field: raw[field] for field in TRACE_FIELDS})
            writer.writerow(row)


def collect(manifest_paths, output_root):
    source_identity = None
    for scenario in ("nominal", "backpressure"):
        manifest_path = Path(manifest_paths[scenario]).resolve()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("status") != "verified" or manifest.get("profiles_requested") != ["register"]:
            raise ValueError("{} is not a verified register-only run".format(manifest_path))
        if bool(manifest.get("short_backpressure")) != (scenario == "backpressure"):
            raise ValueError("{} scenario mode mismatch".format(manifest_path))
        identity = manifest.get("source_identity", {})
        if identity.get("git_commit") != SOURCE_REF:
            raise ValueError("{} source ref mismatch".format(manifest_path))
        if source_identity is None:
            source_identity = identity.get("aggregate_sha256")
        elif identity.get("aggregate_sha256") != source_identity:
            raise ValueError("scenario source identities differ")
        profile = manifest.get("profiles", {}).get("register", {})
        cycle_path = Path(profile.get("cycle_trace", {}).get("path", ""))
        if not cycle_path.is_file():
            raise ValueError("{} cycle trace is missing".format(scenario))
        if sha256_file(cycle_path) != profile["cycle_trace"]["sha256"]:
            raise ValueError("{} cycle trace hash mismatch".format(scenario))
        rows = json.loads(cycle_path.read_text(encoding="utf-8"))
        output = Path(output_root) / CSV_PATHS[scenario]
        write_trace_csv(output, scenario, rows)
        print("wrote {} sha256={}".format(output, sha256_file(output)))


def _require_event_sentinels(row, prefix):
    valid = row[prefix]
    address = row[prefix + "_addr"]
    block = row[prefix + "_block"]
    if valid:
        if not (0 <= address < 256) or block not in (0, 1):
            raise ValueError("{} has invalid event identity at cycle {}".format(prefix, row["cycle"]))
    elif address != -1 or block != -1:
        raise ValueError("{} has malformed sentinels at cycle {}".format(prefix, row["cycle"]))


def _validate_row_contract(rows, scenario):
    if len(rows) != 598 or rows[0]["cycle"] != 6 or rows[-1]["cycle"] != 603:
        raise ValueError("{} curated cycle window must be 6..603".format(scenario))
    if [row["cycle"] for row in rows] != list(range(6, 604)):
        raise ValueError("{} cycles are not contiguous".format(scenario))
    for row in rows:
        for field in BINARY_FIELDS:
            if row[field] not in (0, 1):
                raise ValueError("{} {} is not binary at cycle {}".format(scenario, field, row["cycle"]))
        if row["input_fire"]:
            if row["input_owner"] not in (0, 1) or row["input_block"] not in (0, 1):
                raise ValueError("{} input identity is invalid".format(scenario))
        elif row["input_owner"] != -1 or row["input_block"] != -1:
            raise ValueError("{} input sentinels are malformed".format(scenario))
        for engine in (0, 1):
            prefix = "e{}_".format(engine)
            if row[prefix + "k_valid"]:
                if not (0 <= row[prefix + "k"] <= 15):
                    raise ValueError("{} selected-k is invalid".format(scenario))
            elif row[prefix + "k"] != -1:
                raise ValueError("{} selected-k sentinel is malformed".format(scenario))
            for event in ("ring_wr", "ring_rd_req", "ring_rd_rsp"):
                _require_event_sentinels(row, prefix + event)
            if row[prefix + "block"] not in (-1, engine):
                raise ValueError("{} engine active-block identity changed".format(scenario))
        if row["m_tvalid"]:
            if row["output_owner"] not in (0, 1) or row["output_block"] not in (0, 1):
                raise ValueError("{} output identity is invalid".format(scenario))
        elif (
            row["output_owner"] != -1
            or row["output_block"] != -1
            or row["m_tdata"] != "0" * 32
            or row["m_tuser"] != "00"
            or row["m_tlast"]
        ):
            raise ValueError("{} output sentinels are malformed".format(scenario))
        if row["wrapper_error"] or row["e0_error"] or row["e1_error"]:
            raise ValueError("{} contains a wrapper or Engine error".format(scenario))


def _validate_engine(rows, scenario, engine, expected_k):
    prefix = "e{}_".format(engine)
    fires = [row for row in rows if row["input_fire"] and row["input_owner"] == engine]
    if len(fires) != 256 or any(row["input_block"] != engine for row in fires):
        raise ValueError("{} Engine {} input coverage mismatch".format(scenario, engine))
    if [row["cycle"] for row in fires] != list(range(fires[0]["cycle"], fires[0]["cycle"] + 256)):
        raise ValueError("{} Engine {} input is not one accepted beat per cycle".format(scenario, engine))
    prefix_done = [row for row in rows if row[prefix + "prefix_done"]]
    if len(prefix_done) != 1 or fires[31]["cycle"] >= prefix_done[0]["cycle"]:
        raise ValueError("{} Engine {} prefix-128 boundary mismatch".format(scenario, engine))
    k_rows = [row for row in rows if row[prefix + "k_valid"]]
    if not k_rows or k_rows[0]["cycle"] <= prefix_done[0]["cycle"]:
        raise ValueError("{} Engine {} selected-k ordering mismatch".format(scenario, engine))
    if any(row[prefix + "k"] != expected_k for row in k_rows):
        raise ValueError("{} Engine {} selected-k changed".format(scenario, engine))
    writes = [row for row in rows if row[prefix + "ring_wr"]]
    requests = [row for row in rows if row[prefix + "ring_rd_req"]]
    responses = [row for row in rows if row[prefix + "ring_rd_rsp"]]
    for name, events in (("write", writes), ("request", requests), ("response", responses)):
        if len(events) != 256:
            raise ValueError("{} Engine {} ring {} count mismatch".format(scenario, engine, name))
        address_field = prefix + ("ring_wr_addr" if name == "write" else "ring_rd_{}_addr".format("req" if name == "request" else "rsp"))
        block_field = prefix + ("ring_wr_block" if name == "write" else "ring_rd_{}_block".format("req" if name == "request" else "rsp"))
        if [row[address_field] for row in events] != list(range(256)):
            raise ValueError("{} Engine {} ring {} address order mismatch".format(scenario, engine, name))
        if any(row[block_field] != engine for row in events):
            raise ValueError("{} Engine {} ring {} block mismatch".format(scenario, engine, name))
    if requests[0]["cycle"] <= k_rows[0]["cycle"]:
        raise ValueError("{} Engine {} ring read precedes selected-k".format(scenario, engine))
    if [row["cycle"] for row in requests] != list(range(requests[0]["cycle"], requests[0]["cycle"] + 256)):
        raise ValueError("{} Engine {} ring request II is not one".format(scenario, engine))
    for request, response in zip(requests, responses):
        if response["cycle"] - request["cycle"] != 2:
            raise ValueError("{} Engine {} ring response latency is not two".format(scenario, engine))


def _accepted_packets(rows, scenario):
    valid = [row for row in rows if row["m_tvalid"]]
    if not valid:
        raise ValueError("{} has no output packet activity".format(scenario))
    if any(row["output_owner"] != row["output_block"] for row in valid):
        raise ValueError("{} output owner/block mismatch".format(scenario))
    blocks = [row["output_block"] for row in valid]
    if blocks != sorted(blocks) or set(blocks) != {0, 1}:
        raise ValueError("{} packet owner is not locked".format(scenario))
    accepted = [row for row in valid if row["m_tready"]]
    packets = {}
    for block in (0, 1):
        packet = [row for row in accepted if row["output_block"] == block]
        expected = EXPECTED_PACKETS[block]
        if len(packet) != expected["beats"]:
            raise ValueError("{} packet {} beat count mismatch".format(scenario, block))
        if any(row["output_owner"] != expected["owner"] for row in packet):
            raise ValueError("{} packet {} owner mismatch".format(scenario, block))
        if any(row["m_tlast"] for row in packet[:-1]) or not packet[-1]["m_tlast"]:
            raise ValueError("{} packet {} TLAST is malformed".format(scenario, block))
        if any(int(row["m_tuser"], 16) & 0xF0 for row in packet):
            raise ValueError("{} packet {} TUSER reserved bits are nonzero".format(scenario, block))
        if any(row["m_tuser"] != "0f" for row in packet[:-1]):
            raise ValueError("{} packet {} non-final TUSER is malformed".format(scenario, block))
        final_valid_bytes = (int(packet[-1]["m_tuser"], 16) & 0x0F) + 1
        packet_bytes = ((len(packet) - 1) * 16) + final_valid_bytes
        if (
            packet[-1]["m_tuser"] != expected["final_tuser"]
            or final_valid_bytes != expected["final_valid_bytes"]
            or packet_bytes != expected["packet_bytes"]
        ):
            raise ValueError("{} packet {} final TUSER/byte length mismatch".format(scenario, block))
        if any(row["m_tlast"] for row in packet[:4]):
            raise ValueError("{} packet {} header is shorter than four beats".format(scenario, block))
        packets[block] = [
            (row["m_tdata"], row["m_tuser"], row["m_tlast"], row["output_owner"])
            for row in packet
        ]
    if len([row for row in accepted if row["m_tlast"]]) != 2:
        raise ValueError("{} must contain exactly one accepted TLAST per packet".format(scenario))
    return packets


def _validate_backpressure(rows, scenario):
    stalls = [row["cycle"] for row in rows if row["m_tvalid"] and not row["m_tready"]]
    expected = [] if scenario == "nominal" else [51, 52, 86, 87]
    if stalls != expected:
        raise ValueError("{} output stall cycles mismatch".format(scenario))
    held_fields = ("m_tvalid", "m_tdata", "m_tuser", "m_tlast", "output_owner", "output_block")
    by_cycle = {row["cycle"]: row for row in rows}
    for cycle in stalls:
        current = by_cycle[cycle]
        following = by_cycle[cycle + 1]
        if any(current[field] != following[field] for field in held_fields):
            raise ValueError("{} output changed under backpressure at cycle {}".format(scenario, cycle))
    if scenario == "backpressure":
        accepted_before_header = sum(
            row["m_tvalid"] and row["m_tready"] and row["output_block"] == 0 and row["cycle"] < 51
            for row in rows
        )
        accepted_before_payload = sum(
            row["m_tvalid"] and row["m_tready"] and row["output_block"] == 0 and row["cycle"] < 86
            for row in rows
        )
        if accepted_before_header != 1 or accepted_before_payload != 4:
            raise ValueError("backpressure targets are not header beat 1 and payload beat 4")


def validate_trace(rows, scenario):
    _validate_row_contract(rows, scenario)
    _validate_engine(rows, scenario, 0, 0)
    _validate_engine(rows, scenario, 1, 2)
    packets = _accepted_packets(rows, scenario)
    _validate_backpressure(rows, scenario)
    return packets


def _find_record(records, record_id, kind):
    matches = [record for record in records if record.get("id") == record_id]
    if len(matches) != 1:
        raise ValueError("{} {} registration must be unique".format(kind, record_id))
    return matches[0]


def validate(root):
    root = Path(root).resolve()
    evidence_path = root / EVIDENCE_PATH
    evidence = load_yaml(evidence_path)
    if evidence.get("evidence_id") != EVIDENCE_ID or evidence.get("claim_id") != CLAIM_ID:
        raise ValueError("evidence claim identity mismatch")
    if evidence.get("nonclaim_id") != NONCLAIM_ID or evidence.get("source_ref") != SOURCE_REF:
        raise ValueError("evidence source/nonclaim identity mismatch")
    if evidence.get("fresh_replay_date") != "2026-08-04":
        raise ValueError("fresh replay date mismatch")
    if evidence.get("status") != "verified" or evidence.get("result") != "pass":
        raise ValueError("evidence is not verified/pass")
    tool = evidence.get("tool", {})
    if tool.get("version") != TOOL_VERSION or tool.get("executable_sha256") != TOOL_SHA256:
        raise ValueError("ModelSim identity mismatch")
    if tool.get("functional_clock_period_ns") != 10.0 or tool.get("timing_claim") != "not_applicable_functional_simulation":
        raise ValueError("functional clock boundary mismatch")
    source = evidence.get("source_identity", {})
    for key, expected in EXPECTED_SOURCE_HASHES.items():
        if source.get(key) != expected:
            raise ValueError("source identity {} mismatch".format(key))
    if evidence.get("normalized_trace_sha256") != NORMALIZED_TRACE_SHA256:
        raise ValueError("normalized trace identity mismatch")
    expected_packet_summary = [
        {
            "block": block,
            "owner": values["owner"],
            "beats": values["beats"],
            "final_valid_bytes": values["final_valid_bytes"],
            "packet_bytes": values["packet_bytes"],
        }
        for block, values in sorted(EXPECTED_PACKETS.items())
    ]
    if evidence.get("observed_packets") != expected_packet_summary:
        raise ValueError("observed packet length metadata mismatch")

    packet_sets = {}
    scenario_records = evidence.get("scenarios", {})
    for scenario in ("nominal", "backpressure"):
        record = scenario_records.get(scenario, {})
        expected = EXPECTED_SCENARIOS[scenario]
        for key, value in expected.items():
            if record.get(key) != value:
                raise ValueError("{} evidence {} mismatch".format(scenario, key))
        if record.get("curated_data") != CSV_PATHS[scenario]:
            raise ValueError("{} curated path mismatch".format(scenario))
        csv_path = root / CSV_PATHS[scenario]
        if sha256_file(csv_path) != record.get("curated_data_sha256"):
            raise ValueError("{} curated CSV hash mismatch".format(scenario))
        if record.get("curated_cycle_range") != [6, 603] or record.get("curated_rows") != 598:
            raise ValueError("{} curated window metadata mismatch".format(scenario))
        if record.get("return_code") != 0 or record.get("worktree_status") != "clean" or record.get("result") != "pass":
            raise ValueError("{} replay status mismatch".format(scenario))
        rows = read_trace_csv(csv_path, scenario)
        packet_sets[scenario] = validate_trace(rows, scenario)
    if packet_sets["nominal"] != packet_sets["backpressure"]:
        raise ValueError("accepted packet data/sideband changed under backpressure")

    checks = evidence.get("checks", {})
    required_checks = (
        "cycle_contiguous_no_xz",
        "input_engine_block_identity",
        "prefix_32_beats_before_k",
        "ring_request_addresses_0_to_255_ii1",
        "ring_response_latency_two_cycles",
        "four_header_beats_and_unique_tlast",
        "packet_owner_lock_no_interleaving",
        "output_identity_from_job_fifo_shadow",
        "final_tuser_packet_length_match",
        "backpressure_hold_stable",
        "packet_data_and_sideband_match",
        "decoder_bit_exact",
        "no_fatal_or_error",
    )
    if any(checks.get(name) is not True for name in required_checks):
        raise ValueError("evidence protocol check set is incomplete")
    if evidence.get("decoder", {}) != {
        "bit_exact": True,
        "blocks": 2,
        "samples_per_block": 1024,
        "axis_words_total": 512,
    }:
        raise ValueError("decoder marker summary mismatch")

    evidence_manifest = load_yaml(root / "provenance/evidence.yaml")
    registration = _find_record(evidence_manifest.get("evidence", []), EVIDENCE_ID, "evidence")
    if registration.get("path") != EVIDENCE_PATH or registration.get("source_ref") != SOURCE_REF:
        raise ValueError("evidence registration path/source mismatch")
    if registration.get("claims") != [CLAIM_ID] or registration.get("sha256") != sha256_file(evidence_path):
        raise ValueError("evidence registration claim/hash mismatch")
    if registration.get("public") is not True or registration.get("maturity") != "verified":
        raise ValueError("evidence registration maturity mismatch")

    claims = load_yaml(root / "provenance/claims.yaml")
    claim = _find_record(claims.get("claims", []), CLAIM_ID, "claim")
    if claim.get("source_ref") != SOURCE_REF or claim.get("evidence") != [EVIDENCE_ID]:
        raise ValueError("claim source/evidence backlink mismatch")
    if claim.get("metric") != "direct_stream_timing_protocol_check" or claim.get("value") != "pass":
        raise ValueError("claim metric mismatch")
    if claim.get("status") != "verified" or claim.get("public") is not True:
        raise ValueError("claim status mismatch")

    nonclaims = load_yaml(root / "provenance/nonclaims.yaml")
    nonclaim = _find_record(nonclaims.get("nonclaims", []), NONCLAIM_ID, "nonclaim")
    if nonclaim.get("status") != "not_claimed" or nonclaim.get("public") is not True:
        raise ValueError("nonclaim status mismatch")
    print(
        "direct stream timing evidence: PASS scenarios=2 rows=598+598 source_ref={}".format(
            SOURCE_REF
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2])
    parser.add_argument("--collect", action="store_true")
    parser.add_argument("--nominal-manifest")
    parser.add_argument("--backpressure-manifest")
    args = parser.parse_args()
    if args.collect:
        if not args.nominal_manifest or not args.backpressure_manifest:
            parser.error("--collect requires both scenario manifests")
        collect(
            {
                "nominal": args.nominal_manifest,
                "backpressure": args.backpressure_manifest,
            },
            args.root,
        )
    else:
        validate(args.root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
