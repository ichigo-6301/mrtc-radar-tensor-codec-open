#!/usr/bin/env python3
"""Generate and check deterministic showcase charts from public evidence CSVs."""

import argparse
import csv
import hashlib
import re
import sys
import xml.etree.ElementTree as ET
from decimal import Decimal, ROUND_HALF_UP, localcontext
from pathlib import Path

import yaml


GENERATED_ASSETS = (
    "bitpacker_pipeline_ab.svg",
    "clock_gating_power_ab.svg",
    "compression_vs_snr.svg",
    "engine_scaling.svg",
    "rdtc_multiengine_packet_timing.svg",
    "rdtc_performance_evolution.svg",
    "rdtc_stage1_architecture_ppa_power.svg",
    "rdtc_stage2_clock_gating_power.svg",
    "rdtc_stream_timing.svg",
)

AUTHORED_ASSETS = (
    "bounded_direct_dual_engine.svg",
    "rdtc_overview.svg",
    "rdtc_way_ring.svg",
    "system_context.svg",
    "single_engine_pipeline.svg",
    "multi_engine_wrapper.svg",
    "zynq_emulation_path.svg",
)

OBSOLETE_ASSETS = ("rdtc_data_contract.svg",)

BINARY_ASSETS = {
    "matlab/rdb_before_after_rdtc_zero_rice.png": {
        "sha256": "773c320c15225425ae37f884e6d92bbc49df499ded4d894613e50aa7bf458f68",
        "size_bytes": 49094,
        "dimensions_px": (875, 656),
    },
}

AUTHORED_ASSET_RULES = {
    "bounded_direct_dual_engine.svg": {
        "required": (
            "Current bounded Direct-AXIS dual-Engine profile",
            "separate valid / ready",
            "data follows reservation",
            "256 beats / block",
            "~277-cycle ordered service &gt; 256-cycle zero-gap arrival",
            "Register-expanded: 600 MHz",
            "OpenRAM: 8 macros, 300 MHz",
            "not Fmax",
        ),
        "forbidden": (
            "785",
            "397.52",
            "197.41",
            "beam/s",
        ),
    },
    "rdtc_overview.svg": {
        "required": (
            "MRTC-RDTC: sensing tensor to bit-exact reconstruction",
            "N independent Engines",
            "Packet-locked AXI",
            "No software reorder PASS claimed",
            "Explicit mode and selected k",
            "Length from header or TLAST/TUSER",
            "FFT backend boundary",
            'width="1600" height="1000" viewBox="0 0 1600 1000"',
            "End-to-End Contract and Maturity Boundary",
            "performance, PPA, and power claims are reported in separate controlled A/B figures below",
        ),
        "forbidden": (
            "N x independent Engine",
            "Explicit mode, payload length, and selected k",
            "ADC / FFT pipeline boundary",
            "#dbeafe",
            "#dcfce7",
            "#fef3c7",
            "#ede9fe",
            "#cffafe",
            "#fee2e2",
            "linearGradient",
            "@font-face",
            "&lt;image",
        ),
    },
    "rdtc_way_ring.svg": {
        "required": (
            "4 x 32 x 128-bit true-1RW = 2048 B",
            "beat 127 -&gt; 128 wraps W3 -&gt; W0",
            "response arrives two clocks later",
            "read Way 0 + write Way 1",
            "read Way 0 + write Way 0",
            "Not an output FIFO",
            "not the historical full-block ping-pong buffer",
        ),
        "forbidden": ("continuous compressed-output",),
    },
    "single_engine_pipeline.svg": {
        "required": (
            "Historical full-block Single-Engine pipeline",
            "not the bounded Direct-AXIS shallow ring",
            "configured ZERO / DELTA",
            "Internal k-select",
            "RAW fallback only on supporting encoder paths",
            "tuser / tlast",
        ),
        "forbidden": ("RAW / ZERO / DELTA", "tkeep / tlast"),
    },
    "system_context.svg": {
        "required": (
            "OFDM sensing to lossless radar-tensor packets",
            "1024 samples / block",
            "64-byte header + payload",
        ),
        "forbidden": (),
    },
    "multi_engine_wrapper.svg": {
        "required": (
            "Descriptor and DDR-backed",
            "Round-Robin",
            "dispatcher",
            "Packet-locked",
            "arbiter",
            "Historical 2/4-Engine wrapper scaling; 1-Engine point is the Stage16D2 reference.",
            "same-workload Stage16D2 single-Engine result as a reference",
            "completion order may vary",
            "no software reorder PASS claimed",
        ),
        "forbidden": ("Current bounded Direct-AXIS", "retained for historical evidence"),
    },
    "zynq_emulation_path.svg": {
        "required": (
            "AXIS32 XSim verified; Zynq build maturity separate",
            "Layer A - Vivado 2018.3 XSim: verified 3/3",
            "Layer B - historical Zynq-7000 trial copy",
        ),
        "forbidden": (
            "FPGA emulation verified, with explicit maturity boundaries",
        ),
    },
}

GENERATED_ASSET_RULES = {
    "rdtc_performance_evolution.svg": {
        "required": (
            "RDTC Performance Evolution",
            "Single-Engine Datapath Optimization and Multi-Engine Scaling",
            "Service-rate improvement",
            "10.47&#215;",
            "7693 -&gt; 721 cycles",
            "Packet-level atomic output",
            "completion order is not guaranteed",
            "not a wrapper NUM_ENGINES=1 rerun",
            "separate fixed historical RTL measurements",
        ),
        "forbidden": (
            "mapped GLS",
            "SE=0",
            "315 MHz",
            "identical order across all engine counts",
            "software reorder PASS",
        ),
    },
    "rdtc_stage1_architecture_ppa_power.svg": {
        "required": (
            "Stage 1 &#8212; Buffered to Direct-AXIS",
            "Measured Impact &#8212; BURST_IDLE Workload",
            "1,529,495.20",
            "420,208.44",
            "-74.60%",
            "RTL-SAIF-to-mapped",
            "the Buffered and Direct wrapper architectures differ",
            "Both profiles contain the Codec Engine",
            "Four-Way Shallow Ring",
            "Shared Output FIFO",
            "Codec-Engine power remains at a similar level",
        ),
        "forbidden": (
            "Same top-level function",
            "Lane4 caused 75% power",
            "mapped GLS",
        ),
    },
    "rdtc_stage2_clock_gating_power.svg": {
        "required": (
            "Stage 2 &#8212; Automatic Clock Gating on the Direct Profile",
            "272 x CLKGATETST_X1 inserted",
            "34,816 gated bits",
            "32,768 / 32,768 bits",
            "G0 ungated",
            "G1 clock-gated",
            "Functional mode SE=0",
            "Gate-level regression equivalence evidence",
        ),
        "forbidden": (
            "Formality PASS",
            "post-route power result",
            "silicon power result",
            "100% output TVALID",
        ),
    },
    "clock_gating_power_ab.svg": {
        "required": (
            "Direct G0/G1 mapped dynamic power",
            "G0 ungated",
            "G1 clock-gated",
            "IDLE",
            "BURST_IDLE",
            "ACTIVE_LEGAL",
            "Stage 2 only",
            "not cumulative",
        ),
        "forbidden": (
            "Stage 1 + Stage 2",
            "cumulative saving",
        ),
    },
    "rdtc_stream_timing.svg": {
        "required": (
            "Engine 0 / Block 0",
            "Fixed ModelSim functional trace",
            "256 accepted AXIS128 beats",
            "prefix-128 = first 32 beats",
            "selected k valid",
            "ring read req",
            "continuous addresses 0..255; II=1",
            "response +2 cycles",
            "4 accepted header beats",
            "payload TVALID bubbles",
            "TLAST",
            "header hold: 2 cycles",
            "payload hold: 2 cycles",
            "not a frequency, throughput, or duty claim",
            "nominal CSV SHA256",
            "backpressure CSV SHA256",
        ),
        "forbidden": ("NUM_ENGINES=1", "measured duty", "Fmax"),
    },
    "rdtc_multiengine_packet_timing.svg": {
        "required": (
            "B0 -&gt; E0",
            "B1 -&gt; E1",
            "P0",
            "P1",
            "packet lock",
            "No beat interleaving",
            "Packet-internal bubbles allowed",
            "Fixed ModelSim functional trace",
        ),
        "forbidden": ("P2", "P3", "Fmax"),
    },
}

PURE_SVG_FORBIDDEN = (
    "<image",
    "data:image",
    "http://",
    "https://",
    "@font-face",
    "linearGradient",
    "radialGradient",
    "filter=",
)

DIRECT_TRACE_REQUIRED_FIELDS = frozenset(
    (
        "scenario",
        "cycle",
        "input_fire",
        "input_owner",
        "input_block",
        "e0_prefix_done",
        "e0_k_valid",
        "e0_ring_wr",
        "e0_ring_rd_req",
        "e0_ring_rd_rsp",
        "m_tvalid",
        "m_tready",
        "m_tlast",
        "output_owner",
        "output_block",
    )
)


def read_csv(path):
    with path.open("r", encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream))


def read_yaml(path):
    with path.open("r", encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decimal_percent_change(baseline, candidate, precision=100):
    with localcontext() as context:
        context.prec = precision
        return (candidate - baseline) * Decimal(100) / baseline


def rounded_int(value):
    return int(value.quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def compact_decimal(value):
    return format(value.normalize(), "f")


def load_compression_data(path):
    rows = read_csv(path)
    expected_algorithms = ("rdtc_zero_rice", "rdtc_delta_rice")
    expected_snr = (-20, -10, 0, 10, 20, 30)
    grouped = {name: {} for name in expected_algorithms}

    for row in rows:
        algorithm = row["algorithm_name"]
        if algorithm not in grouped:
            raise ValueError("unexpected algorithm in {}: {}".format(path, algorithm))
        snr = int(row["snr_db"])
        if snr in grouped[algorithm]:
            raise ValueError("duplicate {} SNR {} in {}".format(algorithm, snr, path))
        if row["lossless_flag"] != "1":
            raise ValueError("non-lossless row in {}: {}".format(path, row))
        for field in ("nmse", "max_abs_error"):
            if Decimal(row[field]) != 0:
                raise ValueError("{} must be zero in {}".format(field, path))
        if Decimal(row["pointcloud_match_ratio"]) != 1:
            raise ValueError("pointcloud_match_ratio must be one in {}".format(path))
        grouped[algorithm][snr] = Decimal(row["compression_ratio"])

    for algorithm in expected_algorithms:
        if tuple(sorted(grouped[algorithm])) != expected_snr:
            raise ValueError("unexpected SNR sweep for {} in {}".format(algorithm, path))
    return expected_snr, grouped


def load_scaling_data(path):
    rows = read_csv(path)
    by_engine = {}
    for row in rows:
        engine_count = int(row["engine_count"])
        if engine_count in by_engine:
            raise ValueError("duplicate engine count {} in {}".format(engine_count, path))
        if int(row["workload_blocks"]) != 256:
            raise ValueError("showcase scaling requires the fixed 256-block workload")
        by_engine[engine_count] = row
    if tuple(sorted(by_engine)) != (1, 2, 4):
        raise ValueError("showcase scaling requires exactly 1/2/4 Engine rows")
    return by_engine


def load_bitpacker_data(path):
    rows = read_csv(path)
    by_role = {}
    for row in rows:
        role = row["role"]
        if role not in ("baseline", "optimized"):
            raise ValueError("unexpected Bitpacker role in {}: {}".format(path, role))
        if role in by_role:
            raise ValueError("duplicate Bitpacker role {} in {}".format(role, path))
        first_cycle = int(row["payload_first_valid_cycle"])
        last_cycle = int(row["packet_last_cycle"])
        interval = int(row["payload_stream_cycles"])
        if interval != last_cycle - first_cycle + 1:
            raise ValueError("invalid inclusive Bitpacker interval in {}".format(path))
        if int(row["steady_state_blocks"]) != 256:
            raise ValueError("Bitpacker block-interval chart requires 256-block streams")
        steady_state_cycles = Decimal(row["steady_state_cycles_per_block"])
        if not steady_state_cycles.is_finite() or steady_state_cycles <= 0:
            raise ValueError("invalid steady-state cycles/block in {}".format(path))
        if row["fresh_replay_status"] != "pass":
            raise ValueError("Bitpacker replay did not pass in {}".format(path))
        for field in ("payload_byte_exact", "packet_byte_exact", "decoder_loopback"):
            if row[field] != "1":
                raise ValueError("{} must pass in {}".format(field, path))
        by_role[role] = row

    if tuple(sorted(by_role)) != ("baseline", "optimized"):
        raise ValueError("Bitpacker chart requires one baseline and one optimized row")
    identity_fields = (
        "workload",
        "selected_k",
        "payload_bits",
        "payload_bytes",
        "packet_bytes",
        "input_stall_cycles",
        "output_stall_cycles",
    )
    for field in identity_fields:
        if by_role["baseline"][field] != by_role["optimized"][field]:
            raise ValueError("Bitpacker rows disagree on {} in {}".format(field, path))
    return by_role


CLOCK_GATING_POINT_ORDER = (
    "G0_IDLE",
    "G0_BURST_IDLE",
    "G0_ACTIVE_LEGAL",
    "G1_IDLE",
    "G1_BURST_IDLE",
    "G1_ACTIVE_LEGAL",
)

CLOCK_GATING_WORKLOADS = ("IDLE", "BURST_IDLE", "ACTIVE_LEGAL")


def load_clock_gating_power_data(path):
    """Load the fixed mapped G0/G1 dynamic-power points used by the chart."""
    rows = read_csv(path)
    required_fields = {
        "point_id",
        "variant",
        "workload",
        "status",
        "activity_method",
        "drive_mode",
        "test_enable",
        "dynamic_mw",
    }
    if not rows or not required_fields.issubset(rows[0]):
        raise ValueError("clock-gating points schema mismatch: {}".format(path))
    if tuple(row["point_id"] for row in rows) != CLOCK_GATING_POINT_ORDER:
        raise ValueError("clock-gating chart requires the canonical six-point order")

    by_workload = {workload: {} for workload in CLOCK_GATING_WORKLOADS}
    for row in rows:
        variant = row["variant"]
        workload = row["workload"]
        expected_point = "{}_{}".format(variant, workload)
        if variant not in ("G0", "G1") or workload not in by_workload:
            raise ValueError("unexpected clock-gating point: {}".format(row["point_id"]))
        if row["point_id"] != expected_point:
            raise ValueError("clock-gating point identity mismatch: {}".format(row["point_id"]))
        if variant in by_workload[workload]:
            raise ValueError("duplicate {} {} point".format(variant, workload))
        if row["status"] != "PASS":
            raise ValueError("clock-gating point did not pass: {}".format(row["point_id"]))
        if (
            row["activity_method"] != "mapped_zero_delay"
            or row["drive_mode"] != "RACE_FREE_DRIVE"
            or row["test_enable"] != "0"
        ):
            raise ValueError("clock-gating activity contract mismatch: {}".format(row["point_id"]))
        dynamic_mw = Decimal(row["dynamic_mw"])
        if not dynamic_mw.is_finite() or dynamic_mw <= 0:
            raise ValueError("invalid dynamic power for {}".format(row["point_id"]))
        by_workload[workload][variant] = dynamic_mw

    if any(tuple(sorted(points)) != ("G0", "G1") for points in by_workload.values()):
        raise ValueError("clock-gating chart requires paired G0/G1 points")
    return by_workload


def load_performance_report_data(root):
    evidence = root / "evidence"
    data_dir = evidence / "data"
    bitpacker_yaml_path = evidence / "rdtc_v1_bitpacker_pipeline_ab.yaml"
    bitpacker_csv_path = data_dir / "rdtc_v1_bitpacker_pipeline_ab.csv"
    scaling_yaml_path = evidence / "rdtc_v1_multiengine_rtl.yaml"
    scaling_csv_path = data_dir / "rdtc_v1_multiengine_scaling.csv"

    bitpacker = load_bitpacker_data(bitpacker_csv_path)
    scaling = load_scaling_data(scaling_csv_path)
    bitpacker_yaml = read_yaml(bitpacker_yaml_path)
    scaling_yaml = read_yaml(scaling_yaml_path)

    require(bitpacker_yaml.get("status") == "verified", "Bitpacker YAML is not verified")
    require(scaling_yaml.get("status") == "verified", "Multi-Engine YAML is not verified")
    require(
        bitpacker_yaml.get("curated_data") == "evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv",
        "Bitpacker YAML curated-data path mismatch",
    )
    require(
        bitpacker_yaml.get("curated_data_sha256") == _sha256_file(bitpacker_csv_path),
        "Bitpacker YAML curated-data hash mismatch",
    )
    require(
        scaling_yaml.get("curated_data") == "evidence/data/rdtc_v1_multiengine_scaling.csv",
        "Multi-Engine YAML curated-data path mismatch",
    )
    require(
        scaling_yaml.get("curated_data_sha256") == _sha256_file(scaling_csv_path),
        "Multi-Engine YAML curated-data hash mismatch",
    )

    for role in ("baseline", "optimized"):
        yaml_point = bitpacker_yaml["points"][role]
        csv_point = bitpacker[role]
        for field in ("payload_stream_cycles", "steady_state_blocks", "steady_state_cycles_per_block"):
            require(
                Decimal(str(yaml_point[field])) == Decimal(csv_point[field]),
                "Bitpacker YAML/CSV mismatch for {} {}".format(role, field),
            )

    scaling_bindings = {
        1: scaling_yaml["single_engine"],
        2: scaling_yaml["two_engine"],
        4: scaling_yaml["four_engine"],
    }
    for engine, yaml_point in scaling_bindings.items():
        require(
            Decimal(str(yaml_point["effective_cycles_per_block"]))
            == Decimal(scaling[engine]["effective_cycles_per_block"]),
            "Multi-Engine YAML/CSV cycles mismatch for {} Engines".format(engine),
        )
        if engine in (2, 4):
            require(
                Decimal(str(yaml_point["scaling_efficiency_vs_single_engine"]))
                == Decimal(scaling[engine]["scaling_efficiency_vs_single_engine"]),
                "Multi-Engine YAML/CSV efficiency mismatch for {} Engines".format(engine),
            )
    require(
        Decimal(bitpacker["optimized"]["steady_state_cycles_per_block"])
        == Decimal(scaling[1]["effective_cycles_per_block"]),
        "Stage16D2 and imported one-Engine reference disagree",
    )
    require(
        scaling_yaml["ordering"]["mode"] == "OUT_OF_ORDER"
        and scaling_yaml["ordering"]["packet_atomic"] is True
        and scaling_yaml["ordering"]["software_indexed_reassembly_status"] == "not_claimed",
        "Multi-Engine ordering contract mismatch",
    )
    return {"bitpacker": bitpacker, "scaling": scaling}


def load_architecture_power_report_data(root):
    package = root / "evidence" / "rdtc_v1_power_architecture_ab"
    points = read_csv(package / "points.csv")
    comparisons = read_csv(package / "comparisons.csv")
    hierarchy = read_csv(package / "hierarchy_power.csv")

    by_point = {}
    for row in points:
        point_id = row["point_id"]
        require(point_id not in by_point, "duplicate Stage-1 point: " + point_id)
        by_point[point_id] = row
    expected_points = ("arch315-a0-bursty", "arch315-a1-bursty")
    require(all(point in by_point for point in expected_points), "Stage-1 BURST_IDLE points missing")
    for point_id, variant in zip(expected_points, ("A0", "A1")):
        row = by_point[point_id]
        require(row["variant"] == variant and row["workload_id"] == "bursty", "Stage-1 point identity mismatch")
        require(row["status"] == "PASS", "Stage-1 point did not pass: " + point_id)
        require(row["implementation"] == "mapped_dc", "Stage-1 implementation mismatch")
        require(row["activity_method"] == "rtl_saif_mapped", "Stage-1 activity method mismatch")
        require(row["frequency_mhz"] == "315", "Stage-1 frequency mismatch")
        require(row["library_id"] == "Nangate45:TT_1p1V_25C", "Stage-1 library mismatch")

    required_metrics = ("area_total_um2", "cell_count", "dynamic_mw", "total_mw", "energy_per_block_nj")
    by_metric = {}
    for row in comparisons:
        if row["workload_id"] != "bursty" or row["metric"] not in required_metrics:
            continue
        metric = row["metric"]
        require(metric not in by_metric, "duplicate Stage-1 comparison: " + metric)
        require(row["status"] == "PASS", "Stage-1 comparison did not pass: " + metric)
        require(
            row["baseline_point"] == expected_points[0] and row["candidate_point"] == expected_points[1],
            "Stage-1 comparison endpoints mismatch: " + metric,
        )
        baseline = Decimal(row["baseline"])
        candidate = Decimal(row["candidate"])
        published = Decimal(row["delta_percent"])
        require(
            decimal_percent_change(baseline, candidate, len(published.as_tuple().digits)) == published,
            "Stage-1 comparison percentage mismatch: " + metric,
        )
        by_metric[metric] = {"baseline": baseline, "candidate": candidate, "percent": published}
    require(tuple(sorted(by_metric)) == tuple(sorted(required_metrics)), "Stage-1 comparison set mismatch")

    point_field = {
        "area_total_um2": "area_total_um2",
        "cell_count": "cell_count",
        "dynamic_mw": "dynamic_mw",
        "total_mw": "total_mw",
    }
    for metric, field in point_field.items():
        require(
            Decimal(by_point[expected_points[0]][field]) == by_metric[metric]["baseline"]
            and Decimal(by_point[expected_points[1]][field]) == by_metric[metric]["candidate"],
            "Stage-1 point/comparison mismatch: " + metric,
        )

    engine_totals = {point: [] for point in expected_points}
    for row in hierarchy:
        if row["point_id"] in engine_totals and re.fullmatch(r"g_engine\[[01]\]\.u_engine", row["hierarchy_id"]):
            require(row["status"] == "PASS", "Stage-1 hierarchy row did not pass")
            engine_totals[row["point_id"]].append(Decimal(row["total_mw"]))
    require(all(len(values) == 2 for values in engine_totals.values()), "Stage-1 Engine hierarchy rows missing")
    baseline_engines = sum(engine_totals[expected_points[0]])
    candidate_engines = sum(engine_totals[expected_points[1]])
    require(
        abs(decimal_percent_change(baseline_engines, candidate_engines)) < Decimal(5),
        "Stage-1 Codec-Engine hierarchy power is not at a similar level",
    )
    return by_metric


def load_clock_gating_report_data(root):
    package = root / "evidence" / "rdtc_v1_clock_gating_mapped_dc"
    dynamic = load_clock_gating_power_data(package / "points.csv")
    point_rows = read_csv(package / "points.csv")
    comparison_rows = read_csv(package / "comparisons.csv")
    clock_rows = read_csv(package / "clock_gating.csv")
    gate_rows = read_csv(package / "gates.csv")

    points = {row["point_id"]: row for row in point_rows}
    require(len(points) == len(point_rows), "duplicate Stage-2 point")
    comparisons = {}
    for row in comparison_rows:
        key = (row["workload"], row["metric"])
        require(key not in comparisons, "duplicate Stage-2 comparison: {} {}".format(*key))
        require(row["status"] == "PASS", "Stage-2 comparison did not pass: {} {}".format(*key))
        if row["baseline"] != "NA":
            baseline = Decimal(row["baseline"])
            candidate = Decimal(row["candidate"])
            if row["percent_change"] != "NA":
                require(
                    decimal_percent_change(
                        baseline,
                        candidate,
                        len(Decimal(row["percent_change"]).as_tuple().digits),
                    )
                    == Decimal(row["percent_change"]),
                    "Stage-2 comparison percentage mismatch: {} {}".format(*key),
                )
        comparisons[key] = row

    clock = {}
    for row in clock_rows:
        key = (row["variant"], row["metric"])
        require(key not in clock, "duplicate clock-gating metric: {} {}".format(*key))
        require(row["status"] == "PASS", "clock-gating metric did not pass: {} {}".format(*key))
        clock[key] = Decimal(row["value"])
    gates = {row["gate_id"]: row for row in gate_rows}
    require(len(gates) == len(gate_rows), "duplicate Stage-2 promotion gate")
    for gate_id in (
        "equivalence", "activity_coverage", "icg_inserted", "gated_bits",
        "ring_coverage", "g0_setup_wns", "g1_setup_wns", "electrical",
        "gating_setup_wns", "gating_hold_wns",
    ):
        require(gates.get(gate_id, {}).get("status") == "PASS", "Stage-2 promotion gate failed: " + gate_id)

    g0 = points["G0_BURST_IDLE"]
    g1 = points["G1_BURST_IDLE"]
    require(Decimal(g0["icg_count"]) == 0 and Decimal(g1["icg_count"]) == clock[("G1", "icg_count")], "ICG count mismatch")
    require(Decimal(g1["gated_bits"]) == clock[("G1", "gated_bits")], "gated-bit mismatch")
    require(
        Decimal(g1["ring_gated_bits"]) == clock[("G1", "ring_gated_bits")]
        and Decimal(g1["ring_total_bits"]) == clock[("G1", "ring_total_bits")],
        "Ring coverage identity mismatch",
    )
    return {"dynamic": dynamic, "points": points, "comparisons": comparisons, "clock": clock, "gates": gates}


def _sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _trace_rows(path, scenario):
    rows = read_csv(path)
    if not rows or not DIRECT_TRACE_REQUIRED_FIELDS.issubset(rows[0]):
        raise ValueError("direct timing trace schema mismatch: {}".format(path))
    if any(row.get("scenario") != scenario for row in rows):
        raise ValueError("direct timing trace scenario mismatch: {}".format(path))
    for row in rows:
        if any("x" in value.lower() or "z" in value.lower() for value in row.values()):
            raise ValueError("direct timing trace contains X/Z: {}".format(path))
        for field in DIRECT_TRACE_REQUIRED_FIELDS - {"scenario"}:
            if field not in row:
                raise ValueError("direct timing trace field missing: {}".format(field))
        try:
            row["cycle"] = int(row["cycle"])
            for field in (
                "input_fire", "input_owner", "input_block", "e0_prefix_done",
                "e0_k_valid", "e0_ring_wr", "e0_ring_rd_req", "e0_ring_rd_rsp",
                "m_tvalid", "m_tready", "m_tlast", "output_owner", "output_block",
            ):
                row[field] = int(row[field])
        except ValueError:
            raise ValueError("direct timing trace has non-integer control field: {}".format(path))
    cycles = [row["cycle"] for row in rows]
    if cycles != list(range(cycles[0], cycles[-1] + 1)):
        raise ValueError("direct timing trace cycles are not contiguous: {}".format(path))
    return rows


def _contiguous(values, expected_count, name):
    if len(values) != expected_count or values != list(range(values[0], values[0] + expected_count)):
        raise ValueError("direct timing trace {} is not contiguous".format(name))


def load_direct_timing_data(nominal_path, backpressure_path):
    """Load the fixed two-Engine trace fields used by the public timing figures."""
    nominal = _trace_rows(nominal_path, "nominal")
    backpressure = _trace_rows(backpressure_path, "backpressure")
    e0_input = [row["cycle"] for row in nominal if row["input_fire"] and row["input_owner"] == 0]
    e1_input = [row["cycle"] for row in nominal if row["input_fire"] and row["input_owner"] == 1]
    _contiguous(e0_input, 256, "Engine 0 input")
    _contiguous(e1_input, 256, "Engine 1 input")
    prefix = [row["cycle"] for row in nominal if row["e0_prefix_done"]]
    selected_k = [row["cycle"] for row in nominal if row["e0_k_valid"]]
    requests = [row["cycle"] for row in nominal if row["e0_ring_rd_req"]]
    responses = [row["cycle"] for row in nominal if row["e0_ring_rd_rsp"]]
    if prefix != [e0_input[31] + 10] or not selected_k or selected_k[0] <= prefix[0]:
        raise ValueError("direct timing trace prefix/k ordering changed")
    _contiguous(requests, 256, "Engine 0 ring request")
    _contiguous(responses, 256, "Engine 0 ring response")
    if any(response - request != 2 for request, response in zip(requests, responses)):
        raise ValueError("direct timing trace response latency changed")

    e0_output = [
        row for row in nominal if row["m_tvalid"] and row["output_owner"] == 0 and row["output_block"] == 0
    ]
    e1_output = [
        row for row in nominal if row["m_tvalid"] and row["output_owner"] == 1 and row["output_block"] == 1
    ]
    if len(e0_output) != 20 or len(e1_output) != 72:
        raise ValueError("direct timing trace packet beat count changed")
    headers = e0_output[:4]
    if [row["cycle"] for row in headers] != list(range(headers[0]["cycle"], headers[0]["cycle"] + 4)):
        raise ValueError("direct timing trace header is not four contiguous beats")
    if any(row["m_tlast"] for row in e0_output[:-1]) or not e0_output[-1]["m_tlast"]:
        raise ValueError("direct timing trace Engine 0 TLAST changed")
    if any(row["m_tlast"] for row in e1_output[:-1]) or not e1_output[-1]["m_tlast"]:
        raise ValueError("direct timing trace Engine 1 TLAST changed")

    stalls = [
        row["cycle"] for row in backpressure if row["m_tvalid"] and not row["m_tready"] and row["output_owner"] == 0
    ]
    if stalls != [51, 52, 86, 87]:
        raise ValueError("direct timing trace backpressure hold locations changed")
    return {
        "nominal_sha256": _sha256_file(nominal_path),
        "backpressure_sha256": _sha256_file(backpressure_path),
        "e0_input": e0_input,
        "e1_input": e1_input,
        "prefix_cycle": prefix[0],
        "selected_k_cycle": selected_k[0],
        "requests": requests,
        "responses": responses,
        "e0_output": e0_output,
        "e1_output": e1_output,
        "stalls": stalls,
    }


def _svg_escape(value):
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _cycle_x(cycle, first_cycle, last_cycle, left, right):
    return left + (cycle - first_cycle) * (right - left) / float(last_cycle - first_cycle)


def _rect_for_cycles(first, last, y, height, first_cycle, last_cycle, left, right, css, label=""):
    x = _cycle_x(first, first_cycle, last_cycle, left, right)
    end = _cycle_x(last + 1, first_cycle, last_cycle, left, right)
    text = '<rect x="{:.2f}" y="{}" width="{:.2f}" height="{}" class="{}"/>'.format(
        x, y, max(2.0, end - x), height, css
    )
    if label:
        text += '<text x="{:.2f}" y="{}" text-anchor="middle" class="inside">{}</text>'.format(
            (x + end) / 2, y + height / 2 + 6, _svg_escape(label)
        )
    return text


def direct_stream_timing_svg(trace):
    first_cycle = trace["e0_input"][0]
    last_cycle = trace["e0_output"][-1]["cycle"]
    left, right = 194, 950
    x = lambda cycle: _cycle_x(cycle, first_cycle, last_cycle, left, right)
    prefix_end = trace["e0_input"][31]
    input_blocks = (
        _rect_for_cycles(first_cycle, prefix_end, 155, 34, first_cycle, last_cycle, left, right, "prefix"),
        _rect_for_cycles(prefix_end + 1, trace["e0_input"][-1], 155, 34, first_cycle, last_cycle, left, right, "input"),
    )
    requests = _rect_for_cycles(trace["requests"][0], trace["requests"][-1], 350, 28, first_cycle, last_cycle, left, right, "request")
    responses = _rect_for_cycles(trace["responses"][0], trace["responses"][-1], 405, 28, first_cycle, last_cycle, left, right, "response")
    headers = "".join(
        _rect_for_cycles(
            row["cycle"], row["cycle"], 508, 34,
            first_cycle, last_cycle, left, right, "header"
        )
        for row in trace["e0_output"][:4]
    )
    payload = "".join(
        _rect_for_cycles(row["cycle"], row["cycle"], 508, 34, first_cycle, last_cycle, left, right, "payload")
        for row in trace["e0_output"][4:]
    )
    e0_end = trace["e0_output"][-1]["cycle"]
    backpressure_display = (
        '<rect x="252" y="608" width="58" height="34" class="accepted"/>'
        '<rect x="310" y="608" width="116" height="34" class="hold"/>'
        '<rect x="426" y="608" width="58" height="34" class="accepted"/>'
        '<text x="368" y="634" text-anchor="middle" class="inside">H1 hold</text>'
        '<rect x="606" y="608" width="58" height="34" class="accepted"/>'
        '<rect x="664" y="608" width="116" height="34" class="hold"/>'
        '<rect x="780" y="608" width="58" height="34" class="accepted"/>'
        '<text x="722" y="634" text-anchor="middle" class="inside">P0 hold</text>'
    )
    marker_cycles = (first_cycle, prefix_end + 1, trace["requests"][0], e0_end)
    marker_label_offsets = (0, -18, 18, 0)
    markers = "".join(
        '<line x1="{0:.2f}" y1="140" x2="{0:.2f}" y2="590" class="marker"/><text x="{1:.2f}" y="132" class="tiny" text-anchor="middle">c{2}</text>'.format(
            x(cycle), x(cycle) + label_offset, cycle
        )
        for cycle, label_offset in zip(marker_cycles, marker_label_offsets)
    )
    return """<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1020" viewBox="0 0 1000 1020" role="img" aria-labelledby="title desc">
  <title id="title">Direct wrapper stream trace: Engine 0 / Block 0</title>
  <desc id="desc">Fixed ModelSim functional trace from the final two-Engine Direct wrapper. The diagram derives input, prefix, ring, output, and deterministic backpressure events from public nominal and backpressure CSV files.</desc>
  <style>.title{{font:700 36px Arial,sans-serif;fill:#0f172a}}.sub{{font:400 28px Arial,sans-serif;fill:#475569}}.lane{{font:700 29px Arial,sans-serif;fill:#0f172a}}.note{{font:400 28px Arial,sans-serif;fill:#334155}}.tiny{{font:400 28px Arial,sans-serif;fill:#475569}}.hash{{font:400 28px 'Courier New',monospace;fill:#475569}}.inside{{font:700 28px Arial,sans-serif;fill:#0f172a}}.axis{{stroke:#64748b;stroke-width:2}}.marker{{stroke:#cbd5e1;stroke-width:1.5;stroke-dasharray:5 6}}.input{{fill:#bfdbfe;stroke:#2563eb;stroke-width:1}}.prefix{{fill:#dbeafe;stroke:#2563eb;stroke-width:1}}.write{{fill:#dcfce7;stroke:#16a34a;stroke-width:1}}.request{{fill:#fef3c7;stroke:#d97706;stroke-width:1}}.response{{fill:#ffedd5;stroke:#ea580c;stroke-width:1}}.header{{fill:#ddd6fe;stroke:#7c3aed;stroke-width:1}}.payload{{fill:#cffafe;stroke:#0891b2;stroke-width:1}}.hold{{fill:#fecaca;stroke:#dc2626;stroke-width:1}}.accepted{{fill:#bbf7d0;stroke:#16a34a;stroke-width:1}}.panel{{fill:#ffffff;stroke:#cbd5e1;stroke-width:1.5}}</style>
  <rect width="1000" height="1020" fill="#f8fafc"/>
  <text x="42" y="45" class="title">Direct wrapper stream trace: Engine 0 / Block 0</text>
  <text x="42" y="80" class="sub">Fixed ModelSim functional trace: 2-Engine / 2-block Direct wrapper</text>
  <text x="42" y="112" class="sub">Register-expanded profile; not a frequency, throughput, or duty claim.</text>
{markers}
  <text x="42" y="180" class="lane">input fire</text>{input0}{input1}<text x="204" y="217" class="tiny">prefix-128 = first 32 beats</text><text x="590" y="217" class="tiny">256 accepted AXIS128 beats</text>
  <text x="42" y="260" class="lane">prefix / k</text><line x1="{prefix_x:.2f}" y1="225" x2="{prefix_x:.2f}" y2="275" stroke="#7c3aed" stroke-width="4"/><text x="{prefix_label_x:.2f}" y="245" class="tiny">prefix done</text><line x1="{k_x:.2f}" y1="225" x2="{k_x:.2f}" y2="275" stroke="#be123c" stroke-width="4"/><text x="{k_label_x:.2f}" y="275" class="tiny">selected k valid</text>
  <text x="42" y="320" class="lane">ring write</text>{writes}
  <text x="42" y="370" class="lane">ring read req</text>{requests}<text x="{req_x:.2f}" y="342" class="tiny">continuous addresses 0..255; II=1</text>
  <text x="42" y="425" class="lane">ring read rsp</text>{responses}<text x="{right}" y="468" class="tiny" text-anchor="end">fixed response +2 cycles</text>
  <line x1="{left}" y1="485" x2="{right}" y2="485" class="axis"/>
  <text x="42" y="530" class="lane">m_axis TVALID</text>{headers}{payload}
  <text x="300" y="578" class="tiny" text-anchor="middle">4 accepted header beats</text><text x="705" y="578" class="tiny" text-anchor="middle">payload TVALID bubbles</text>
  <rect x="244" y="608" width="602" height="34" class="panel"/><text x="42" y="630" class="lane">backpressure</text>{backpressure_display}
  <text x="368" y="684" class="tiny" text-anchor="middle">header hold: 2 cycles</text><text x="722" y="684" class="tiny" text-anchor="middle">payload hold: 2 cycles</text>
  <rect x="42" y="720" width="916" height="285" rx="5" class="panel"/>
  <text x="58" y="752" class="note">TVALID &amp;&amp; !TREADY holds TDATA / TUSER / TLAST stable.</text>
  <text x="58" y="784" class="note">Red cells are deterministic two-cycle holds.</text>
  <text x="58" y="824" class="tiny">nominal CSV SHA256</text>
  <text x="58" y="856" class="hash">{nominal_hash_a}</text><text x="58" y="888" class="hash">{nominal_hash_b}</text>
  <text x="58" y="928" class="tiny">backpressure CSV SHA256</text>
  <text x="58" y="960" class="hash">{backpressure_hash_a}</text><text x="58" y="992" class="hash">{backpressure_hash_b}</text>
</svg>
""".format(
        markers=markers, input0=input_blocks[0], input1=input_blocks[1],
        prefix_x=x(trace["prefix_cycle"]), prefix_label_x=x(trace["prefix_cycle"]) + 8,
        k_x=x(trace["selected_k_cycle"]), k_label_x=x(trace["selected_k_cycle"]) + 8,
        writes=_rect_for_cycles(first_cycle, trace["e0_input"][-1], 300, 28, first_cycle, last_cycle, left, right, "write"),
        requests=requests, req_x=x(trace["requests"][0]), responses=responses,
        left=left, right=right, headers=headers, payload=payload,
        backpressure_display=backpressure_display,
        nominal_hash_a=trace["nominal_sha256"][:32], nominal_hash_b=trace["nominal_sha256"][32:],
        backpressure_hash_a=trace["backpressure_sha256"][:32], backpressure_hash_b=trace["backpressure_sha256"][32:],
    )


def direct_multiengine_packet_timing_svg(trace):
    first_cycle = trace["e0_input"][0]
    last_cycle = trace["e1_output"][-1]["cycle"]
    left, right = 250, 950
    e0_out = trace["e0_output"]
    e1_out = trace["e1_output"]
    lanes = []
    for output, y, css in ((e0_out, 290, "p0"), (e1_out, 430, "p1")):
        for row in output:
            lanes.append(_rect_for_cycles(row["cycle"], row["cycle"], y, 28, first_cycle, last_cycle, left, right, css))
    shared = []
    for output, css in ((e0_out, "p0"), (e1_out, "p1")):
        for row in output:
            shared.append(_rect_for_cycles(row["cycle"], row["cycle"], 545, 34, first_cycle, last_cycle, left, right, css))
    x = lambda cycle: _cycle_x(cycle, first_cycle, last_cycle, left, right)
    return """<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="890" viewBox="0 0 1000 890" role="img" aria-labelledby="title desc">
  <title id="title">Two-Engine Direct wrapper packet service trace</title>
  <desc id="desc">Fixed ModelSim functional trace showing Block 0 assigned to Engine 0 and Block 1 to Engine 1. Shared output presents packet 0 then packet 1 without beat interleaving; packet-internal TVALID bubbles are shown as gaps.</desc>
  <style>.title{{font:700 36px Arial,sans-serif;fill:#0f172a}}.sub{{font:400 28px Arial,sans-serif;fill:#475569}}.lane{{font:700 28px Arial,sans-serif;fill:#0f172a}}.note{{font:400 28px Arial,sans-serif;fill:#334155}}.tiny{{font:400 28px Arial,sans-serif;fill:#475569}}.hash{{font:400 28px 'Courier New',monospace;fill:#475569}}.inside{{font:700 28px Arial,sans-serif;fill:#0f172a}}.axis{{stroke:#64748b;stroke-width:2}}.p0{{fill:#bfdbfe;stroke:#2563eb;stroke-width:1}}.p1{{fill:#dcfce7;stroke:#16a34a;stroke-width:1}}.dispatch0{{fill:#dbeafe;stroke:#2563eb;stroke-width:1.5}}.dispatch1{{fill:#bbf7d0;stroke:#16a34a;stroke-width:1.5}}.window0{{fill:#eff6ff;stroke:#93c5fd;stroke-width:1.5;stroke-dasharray:5 4}}.window1{{fill:#f0fdf4;stroke:#86efac;stroke-width:1.5;stroke-dasharray:5 4}}.panel{{fill:#ffffff;stroke:#cbd5e1;stroke-width:1.5}}</style>
  <rect width="1000" height="890" fill="#f8fafc"/>
  <text x="42" y="45" class="title">Two-Engine Direct wrapper packet service</text>
  <text x="42" y="80" class="sub">Fixed ModelSim functional trace: B0 -&gt; E0 and B1 -&gt; E1.</text>
  <text x="42" y="114" class="sub">Two-block protocol evidence; not historical scaling data.</text>
  <text x="42" y="170" class="lane">input dispatch</text>
  <rect x="{b0_x:.2f}" y="145" width="{b0_w:.2f}" height="38" class="dispatch0"/><text x="{b0_t:.2f}" y="173" text-anchor="middle" class="inside">B0 -&gt; E0</text>
  <rect x="{b1_x:.2f}" y="145" width="{b1_w:.2f}" height="38" class="dispatch1"/><text x="{b1_t:.2f}" y="173" text-anchor="middle" class="inside">B1 -&gt; E1</text>
  <text x="42" y="250" class="lane">Engine 0</text><rect x="{p0_x:.2f}" y="215" width="{p0_w:.2f}" height="65" class="window0"/><text x="{p0_t:.2f}" y="242" text-anchor="middle" class="inside">P0 packet window</text><text x="{p0_t:.2f}" y="269" text-anchor="middle" class="tiny">accepted beats + bubbles</text>
  <text x="42" y="312" class="lane">E0 output</text>{e0_lanes}
  <text x="42" y="390" class="lane">Engine 1</text><rect x="{p1_x:.2f}" y="355" width="{p1_w:.2f}" height="65" class="window1"/><text x="{p1_t:.2f}" y="382" text-anchor="middle" class="inside">P1 packet window</text><text x="{p1_t:.2f}" y="409" text-anchor="middle" class="tiny">accepted beats + bubbles</text>
  <text x="42" y="452" class="lane">E1 output</text>{e1_lanes}
  <line x1="{left}" y1="500" x2="{right}" y2="500" class="axis"/>
  <text x="42" y="570" class="lane">shared AXIS</text><rect x="{p0_x:.2f}" y="545" width="{p0_w:.2f}" height="34" class="window0"/><rect x="{p1_x:.2f}" y="545" width="{p1_w:.2f}" height="34" class="window1"/>{shared}
  <text x="{p0_t:.2f}" y="615" text-anchor="middle" class="tiny">packet lock: P0</text><text x="{p1_t:.2f}" y="615" text-anchor="middle" class="tiny">packet lock: P1</text>
  <rect x="42" y="645" width="916" height="225" rx="5" class="panel"/>
  <text x="58" y="681" class="note">No beat interleaving: one shared-AXIS owner through accepted TLAST.</text>
  <text x="58" y="715" class="note">Packet-internal bubbles allowed.</text>
  <text x="58" y="749" class="note">TVALID may deassert between accepted beats.</text>
  <text x="58" y="787" class="tiny">nominal CSV SHA256; only B0/B1 and P0/P1 are shown</text>
  <text x="58" y="823" class="hash">{nominal_hash_a}</text>
  <text x="58" y="859" class="hash">{nominal_hash_b}</text>
</svg>
""".format(
        b0_x=x(trace["e0_input"][0]), b0_w=x(trace["e0_input"][-1] + 1) - x(trace["e0_input"][0]), b0_t=(x(trace["e0_input"][0]) + x(trace["e0_input"][-1] + 1)) / 2,
        b1_x=x(trace["e1_input"][0]), b1_w=x(trace["e1_input"][-1] + 1) - x(trace["e1_input"][0]), b1_t=(x(trace["e1_input"][0]) + x(trace["e1_input"][-1] + 1)) / 2,
        p0_x=x(e0_out[0]["cycle"]), p0_w=x(e0_out[-1]["cycle"] + 1) - x(e0_out[0]["cycle"]), p0_t=(x(e0_out[0]["cycle"]) + x(e0_out[-1]["cycle"] + 1)) / 2,
        p1_x=x(e1_out[0]["cycle"]), p1_w=x(e1_out[-1]["cycle"] + 1) - x(e1_out[0]["cycle"]), p1_t=(x(e1_out[0]["cycle"]) + x(e1_out[-1]["cycle"] + 1)) / 2,
        e0_lanes="".join(lanes[:len(e0_out)]), e1_lanes="".join(lanes[len(e0_out):]), shared="".join(shared),
        left=left, right=right,
        nominal_hash_a=trace["nominal_sha256"][:32],
        nominal_hash_b=trace["nominal_sha256"][32:],
    )


def compression_svg(snr_values, grouped):
    x_positions = {snr: 120 + index * 160 for index, snr in enumerate(snr_values)}

    def y_position(ratio):
        return rounded_int(Decimal(500) - ((ratio - Decimal(1)) * Decimal(400) / Decimal(7)))

    zero_points = [(x_positions[snr], y_position(grouped["rdtc_zero_rice"][snr])) for snr in snr_values]
    delta_points = [(x_positions[snr], y_position(grouped["rdtc_delta_rice"][snr])) for snr in snr_values]

    def point_string(points):
        return " ".join("{},{}".format(x, y) for x, y in points)

    zero_circles = "".join(
        '    <circle cx="{}" cy="{}" r="6"/>'.format(x, y) for x, y in zero_points
    )
    delta_circles = "".join(
        '    <circle cx="{}" cy="{}" r="6"/>'.format(x, y) for x, y in delta_points
    )

    return """<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="620" viewBox="0 0 1000 620" role="img" aria-labelledby="title desc">
  <title id="title">Synthetic compression ratio versus SNR</title>
  <desc id="desc">ZERO Rice and DELTA Rice compression ratios from negative 20 through 30 decibels on a controlled synthetic dataset.</desc>
  <style>.title{{font:700 31px Arial,sans-serif;fill:#0f172a}}.sub{{font:400 17px Arial,sans-serif;fill:#475569}}.axis{{font:400 16px Arial,sans-serif;fill:#334155}}.label{{font:700 17px Arial,sans-serif;fill:#0f172a}}.grid{{stroke:#cbd5e1;stroke-width:1}}.zero{{stroke:#2563eb;stroke-width:5;fill:none}}.delta{{stroke:#dc2626;stroke-width:5;fill:none}}</style>
  <rect width="1000" height="620" fill="#f8fafc"/>
  <text x="55" y="48" class="title">Compression ratio vs. synthetic SNR</text>
  <text x="55" y="75" class="sub">Controlled MATLAB study. Higher is smaller payload; this is not measured radar data.</text>

  <g class="grid">
    <line x1="100" y1="500" x2="920" y2="500"/><line x1="100" y1="443" x2="920" y2="443"/>
    <line x1="100" y1="386" x2="920" y2="386"/><line x1="100" y1="329" x2="920" y2="329"/>
    <line x1="100" y1="271" x2="920" y2="271"/><line x1="100" y1="214" x2="920" y2="214"/>
    <line x1="100" y1="157" x2="920" y2="157"/><line x1="100" y1="100" x2="920" y2="100"/>
    <line x1="120" y1="100" x2="120" y2="500"/><line x1="280" y1="100" x2="280" y2="500"/>
    <line x1="440" y1="100" x2="440" y2="500"/><line x1="600" y1="100" x2="600" y2="500"/>
    <line x1="760" y1="100" x2="760" y2="500"/><line x1="920" y1="100" x2="920" y2="500"/>
  </g>
  <line x1="100" y1="100" x2="100" y2="500" stroke="#334155" stroke-width="2"/>
  <line x1="100" y1="500" x2="920" y2="500" stroke="#334155" stroke-width="2"/>
  <g class="axis" text-anchor="end">
    <text x="88" y="505">1</text><text x="88" y="448">2</text><text x="88" y="391">3</text><text x="88" y="334">4</text>
    <text x="88" y="276">5</text><text x="88" y="219">6</text><text x="88" y="162">7</text><text x="88" y="105">8</text>
  </g>
  <g class="axis" text-anchor="middle">
    <text x="120" y="525">-20</text><text x="280" y="525">-10</text><text x="440" y="525">0</text><text x="600" y="525">10</text><text x="760" y="525">20</text><text x="920" y="525">30</text>
  </g>
  <text x="510" y="558" text-anchor="middle" class="label">Synthetic SNR (dB)</text>
  <text x="30" y="300" text-anchor="middle" class="label" transform="rotate(-90 30 300)">Compression ratio</text>

  <polyline class="zero" points="{zero_points}"/>
  <polyline class="delta" points="{delta_points}"/>
  <g fill="#2563eb" stroke="#fff" stroke-width="2">
{zero_circles}
  </g>
  <g fill="#dc2626" stroke="#fff" stroke-width="2">
{delta_circles}
  </g>

  <rect x="620" y="105" width="235" height="72" rx="6" fill="#fff" stroke="#94a3b8"/>
  <line x1="642" y1="130" x2="686" y2="130" class="zero"/><circle cx="664" cy="130" r="5" fill="#2563eb"/>
  <text x="700" y="135" class="axis">ZERO_RICE</text>
  <line x1="642" y1="156" x2="686" y2="156" class="delta"/><circle cx="664" cy="156" r="5" fill="#dc2626"/>
  <text x="700" y="161" class="axis">DELTA_RICE</text>
  <text x="55" y="595" class="sub">Recorded points: -20, -10, 0, 10, 20, and 30 dB. Lossless reconstruction is checked separately.</text>
</svg>
""".format(
        zero_points=point_string(zero_points),
        delta_points=point_string(delta_points),
        zero_circles=zero_circles,
        delta_circles=delta_circles,
    )


def bitpacker_svg(by_role):
    payload_baseline = Decimal(by_role["baseline"]["payload_stream_cycles"])
    payload_optimized = Decimal(by_role["optimized"]["payload_stream_cycles"])
    block_baseline = Decimal(by_role["baseline"]["steady_state_cycles_per_block"])
    block_optimized = Decimal(by_role["optimized"]["steady_state_cycles_per_block"])
    payload_speedup = (payload_baseline / payload_optimized).quantize(
        Decimal("0.01"), rounding=ROUND_HALF_UP
    )
    block_speedup = (block_baseline / block_optimized).quantize(
        Decimal("0.01"), rounding=ROUND_HALF_UP
    )
    block_reduction = (
        (Decimal(1) - (block_optimized / block_baseline)) * Decimal(100)
    ).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    bar_x = 260
    baseline_width = 650
    optimized_width = rounded_int(Decimal(baseline_width) * block_optimized / block_baseline)

    return """<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="620" viewBox="0 0 1000 620" role="img" aria-labelledby="title desc">
  <title id="title">Single-Engine RTL block-interval pipeline A/B</title>
  <desc id="desc">On fixed 256-block zero-sparse streams, average single-Engine packet-completion spacing falls from {block_baseline} to {block_optimized} cycles per block. A separate smoke_zero_sparse measurement records the {payload_optimized}-cycle payload-valid-to-TLAST interval.</desc>
  <style>.title{{font:700 31px Arial,sans-serif;fill:#0f172a}}.sub{{font:400 17px Arial,sans-serif;fill:#475569}}.label{{font:700 20px Arial,sans-serif;fill:#0f172a}}.value{{font:700 24px Arial,sans-serif;fill:#0f172a}}.callout{{font:700 30px Arial,sans-serif;fill:#166534}}.note{{font:400 16px Arial,sans-serif;fill:#334155}}.small{{font:400 15px Arial,sans-serif;fill:#475569}}</style>
  <rect width="1000" height="620" fill="#f8fafc"/>
  <text x="55" y="48" class="title">Single-Engine steady-state pipeline A/B</text>
  <text x="55" y="76" class="sub">Fixed 256-block ZERO_RICE stream; lower packet-completion spacing is better.</text>

  <text x="55" y="154" class="label">Stage16C3 baseline</text>
  <rect x="{bar_x}" y="120" width="{baseline_width}" height="58" rx="6" fill="#2563eb"/>
  <text x="{baseline_text_x}" y="157" text-anchor="end" fill="#fff" class="value">{block_baseline} cycles/block</text>

  <text x="55" y="264" class="label">Stage16D2 Lane4</text>
  <rect x="{bar_x}" y="230" width="{optimized_width}" height="58" rx="6" fill="#16a34a"/>
  <text x="{optimized_text_x}" y="267" class="value">{block_optimized} cycles/block</text>

  <rect x="55" y="330" width="890" height="118" rx="6" fill="#f0fdf4" stroke="#16a34a" stroke-width="2"/>
  <text x="275" y="375" text-anchor="middle" class="callout">{block_speedup}&#215; block service rate</text>
  <text x="275" y="408" text-anchor="middle" class="label">{block_reduction}% fewer cycles/block</text>
  <line x1="500" y1="350" x2="500" y2="427" stroke="#86efac" stroke-width="2"/>
  <text x="720" y="370" text-anchor="middle" class="label">Separate payload metric</text>
  <text x="720" y="404" text-anchor="middle" class="callout">{payload_baseline} -&gt; {payload_optimized} cycles</text>
  <text x="720" y="430" text-anchor="middle" class="small">{payload_speedup}&#215;; identical 334-byte packet</text>

  <text x="55" y="493" class="note">Block spacing uses 256-block streams; payload-valid-to-TLAST uses a separate smoke_zero_sparse run.</text>
  <text x="55" y="525" class="note">Both A/B points already use prefix-during-capture; the measured delta isolates the Lane4 packer.</text>
  <text x="55" y="557" class="note">Packet byte-exactness and decoder loopback pass.</text>
  <text x="55" y="590" class="sub">Historical ModelSim RTL metrics - not one-block latency, Direct-AXIS throughput, FPGA timing, or Fmax.</text>
</svg>
""".format(
        payload_baseline=compact_decimal(payload_baseline),
        payload_optimized=compact_decimal(payload_optimized),
        block_baseline=compact_decimal(block_baseline),
        block_optimized=compact_decimal(block_optimized),
        bar_x=bar_x,
        baseline_width=baseline_width,
        optimized_width=optimized_width,
        baseline_text_x=bar_x + baseline_width - 16,
        optimized_text_x=bar_x + optimized_width + 16,
        payload_speedup=compact_decimal(payload_speedup),
        block_speedup=compact_decimal(block_speedup),
        block_reduction=compact_decimal(block_reduction),
    )


def scaling_svg(by_engine, bitpacker_by_role):
    cycles = {
        engine: Decimal(by_engine[engine]["effective_cycles_per_block"])
        for engine in (1, 2, 4)
    }
    stage16d2_cycles = Decimal(
        bitpacker_by_role["optimized"]["steady_state_cycles_per_block"]
    )
    if cycles[1] != stage16d2_cycles:
        raise ValueError(
            "Multi-Engine one-Engine baseline does not match Stage16D2 steady-state evidence: {} != {}".format(
                cycles[1], stage16d2_cycles
            )
        )
    y_positions = {
        engine: rounded_int(Decimal(500) - cycles[engine] * Decimal(412) / Decimal(800))
        for engine in (1, 2, 4)
    }
    heights = {engine: 500 - y_positions[engine] for engine in (1, 2, 4)}
    labels = {engine: compact_decimal(cycles[engine]) for engine in (1, 2, 4)}
    eff2 = compact_decimal(
        Decimal(by_engine[2]["scaling_efficiency_vs_single_engine"]) * Decimal(100)
    ) + "%"
    eff4 = compact_decimal(
        Decimal(by_engine[4]["scaling_efficiency_vs_single_engine"]) * Decimal(100)
    ) + "%"
    scale2 = compact_decimal((cycles[1] / cycles[2]).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)) + "x"
    scale4 = compact_decimal((cycles[1] / cycles[4]).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)) + "x"

    return """<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="620" viewBox="0 0 1000 620" role="img" aria-labelledby="title desc">
  <title id="title">Multi-Engine wrapper block-interval scaling</title>
  <desc id="desc">Starting from the Stage16D2-matched {label1}-cycle single Engine, the historical buffered wrapper reduces average block interval to {label2} cycles with two Engines and {label4} cycles with four Engines.</desc>
  <style>.title{{font:700 31px Arial,sans-serif;fill:#0f172a}}.sub{{font:400 17px Arial,sans-serif;fill:#475569}}.axis{{font:400 16px Arial,sans-serif;fill:#334155}}.label{{font:700 18px Arial,sans-serif;fill:#0f172a}}.value{{font:700 21px Arial,sans-serif;fill:#0f172a}}.light{{fill:#fff}}.grid{{stroke:#cbd5e1;stroke-width:1}}</style>
  <rect width="1000" height="620" fill="#f8fafc"/>
  <text x="55" y="48" class="title">Multi-Engine wrapper block-interval scaling</text>
  <text x="55" y="75" class="sub">Historical buffered profile; fixed 256-block RTL workload. Lower cycles/block is better.</text>

  <g class="grid">
    <line x1="110" y1="500" x2="920" y2="500"/><line x1="110" y1="397" x2="920" y2="397"/>
    <line x1="110" y1="294" x2="920" y2="294"/><line x1="110" y1="191" x2="920" y2="191"/>
    <line x1="110" y1="88" x2="920" y2="88"/>
  </g>
  <line x1="110" y1="88" x2="110" y2="500" stroke="#334155" stroke-width="2"/>
  <line x1="110" y1="500" x2="920" y2="500" stroke="#334155" stroke-width="2"/>
  <g class="axis" text-anchor="end"><text x="98" y="505">0</text><text x="98" y="402">200</text><text x="98" y="299">400</text><text x="98" y="196">600</text><text x="98" y="93">800</text></g>
  <text x="32" y="300" text-anchor="middle" class="label" transform="rotate(-90 32 300)">Cycles / block</text>

  <rect x="185" y="{y1}" width="170" height="{h1}" rx="6" fill="#2563eb"/>
  <rect x="430" y="{y2}" width="170" height="{h2}" rx="6" fill="#16a34a"/>
  <rect x="675" y="{y4}" width="170" height="{h4}" rx="6" fill="#f59e0b"/>
  <text x="270" y="{t1}" text-anchor="middle" class="value light">{label1}</text>
  <text x="515" y="{t2}" text-anchor="middle" class="value">{label2}</text>
  <text x="760" y="{t4}" text-anchor="middle" class="value">{label4}</text>
  <g class="label" text-anchor="middle"><text x="270" y="528">1 Engine reference</text><text x="515" y="528">2 Engines</text><text x="760" y="528">4 Engines</text></g>
  <g class="axis" text-anchor="middle">
    <text x="270" y="552">Stage16D2; not wrapper rerun</text>
    <text x="515" y="552">{scale2} throughput</text>
    <text x="760" y="552">{scale4} throughput</text>
    <text x="515" y="576">scaling efficiency {eff2}</text>
    <text x="760" y="576">scaling efficiency {eff4}</text>
  </g>
  <rect x="650" y="105" width="270" height="70" rx="6" fill="#fff7ed" stroke="#f59e0b"/>
  <text x="785" y="132" text-anchor="middle" class="label">Starts from {label1} cycles/block</text>
  <text x="785" y="155" text-anchor="middle" class="axis">validated against Stage16D2 evidence</text>
  <text x="500" y="606" text-anchor="middle" class="sub">Cycle metric only - not an implemented clock, FPGA timing, board DDR throughput, or Direct-AXIS result.</text>
</svg>
""".format(
        y1=y_positions[1], h1=heights[1], t1=y_positions[1] + 28, label1=labels[1],
        y2=y_positions[2], h2=heights[2], t2=y_positions[2] - 10, label2=labels[2],
        y4=y_positions[4], h4=heights[4], t4=y_positions[4] - 10, label4=labels[4],
        eff2=eff2, eff4=eff4, scale2=scale2, scale4=scale4,
    )


def clock_gating_power_svg(by_workload):
    axis_max = Decimal("120")
    plot_top = 120
    plot_bottom = 500
    plot_height = plot_bottom - plot_top
    group_centers = {"IDLE": 250, "BURST_IDLE": 520, "ACTIVE_LEGAL": 790}
    bar_width = 76
    bar_gap = 14

    bars = []
    labels = []
    savings = []
    for workload in CLOCK_GATING_WORKLOADS:
        center = group_centers[workload]
        g0 = by_workload[workload]["G0"]
        g1 = by_workload[workload]["G1"]
        if g0 > axis_max or g1 > axis_max:
            raise ValueError("clock-gating dynamic power exceeds the fixed chart axis")
        for variant, value, x, color in (
            ("G0", g0, center - bar_gap // 2 - bar_width, "#2563eb"),
            ("G1", g1, center + bar_gap // 2, "#16a34a"),
        ):
            height = rounded_int(value * Decimal(plot_height) / axis_max)
            y = plot_bottom - height
            bars.append(
                '  <rect class="{}-bar" x="{}" y="{}" width="{}" height="{}" rx="5" fill="{}"/>'.format(
                    variant.lower(), x, y, bar_width, height, color
                )
            )
            labels.append(
                '  <text x="{}" y="{}" text-anchor="middle" class="value">{}</text>'.format(
                    x + bar_width // 2, y - 10, compact_decimal(value)
                )
            )
        reduction = ((g0 - g1) * Decimal(100) / g0).quantize(
            Decimal("0.1"), rounding=ROUND_HALF_UP
        )
        savings.append(
            '  <text x="{}" y="568" text-anchor="middle" class="saving">{}% lower</text>'.format(
                center, compact_decimal(reduction)
            )
        )

    return """<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="650" viewBox="0 0 1000 650" role="img" aria-labelledby="title desc" preserveAspectRatio="xMidYMid meet">
  <title id="title">Direct G0/G1 mapped dynamic power</title>
  <desc id="desc">Grouped bars compare Direct G0 ungated and Direct G1 clock-gated mapped-netlist dynamic power for IDLE, BURST_IDLE, and ACTIVE_LEGAL at 315 MHz.</desc>
  <style>.title{{font:700 31px Arial,sans-serif;fill:#0f172a}}.sub{{font:400 17px Arial,sans-serif;fill:#475569}}.axis{{font:400 16px Arial,sans-serif;fill:#334155}}.label{{font:700 18px Arial,sans-serif;fill:#0f172a}}.value{{font:700 17px Arial,sans-serif;fill:#0f172a}}.saving{{font:700 17px Arial,sans-serif;fill:#166534}}.grid{{stroke:#cbd5e1;stroke-width:1}}</style>
  <rect width="1000" height="650" fill="#f8fafc"/>
  <text x="55" y="48" class="title">Direct G0/G1 mapped dynamic power</text>
  <text x="55" y="76" class="sub">315 MHz mapped-netlist estimate; lower is better.</text>
  <rect x="680" y="38" width="18" height="18" rx="3" fill="#2563eb"/><text x="708" y="53" class="axis">G0 ungated</text>
  <rect x="820" y="38" width="18" height="18" rx="3" fill="#16a34a"/><text x="848" y="53" class="axis">G1 clock-gated</text>

  <g class="grid">
    <line x1="110" y1="500" x2="930" y2="500"/><line x1="110" y1="405" x2="930" y2="405"/>
    <line x1="110" y1="310" x2="930" y2="310"/><line x1="110" y1="215" x2="930" y2="215"/>
    <line x1="110" y1="120" x2="930" y2="120"/>
  </g>
  <line x1="110" y1="120" x2="110" y2="500" stroke="#334155" stroke-width="2"/>
  <line x1="110" y1="500" x2="930" y2="500" stroke="#334155" stroke-width="2"/>
  <g class="axis" text-anchor="end"><text x="98" y="505">0</text><text x="98" y="410">30</text><text x="98" y="315">60</text><text x="98" y="220">90</text><text x="98" y="125">120</text></g>
  <text x="34" y="310" text-anchor="middle" class="label" transform="rotate(-90 34 310)">Dynamic power (mW)</text>

{bars}
{labels}
  <g class="label" text-anchor="middle"><text x="250" y="532">IDLE</text><text x="520" y="532">BURST_IDLE</text><text x="790" y="532">ACTIVE_LEGAL</text></g>
{savings}
  <text x="500" y="610" text-anchor="middle" class="sub">Stage 2 only: G1 relative to Direct G0; architecture and clock-gating savings are not cumulative.</text>
  <text x="500" y="635" text-anchor="middle" class="sub">Activity-driven zero-delay mapped estimate; not CTS clock-tree, post-route, or silicon power.</text>
</svg>
""".format(bars="\n".join(bars), labels="\n".join(labels), savings="\n".join(savings))


REPORT_STYLE = """
    .title{font:700 38px Arial,Helvetica,sans-serif;fill:#111827}
    .subtitle{font:400 22px Arial,Helvetica,sans-serif;fill:#4b5563}
    .panel-title{font:700 25px Arial,Helvetica,sans-serif;fill:#102f5e}
    .section{font:700 22px Arial,Helvetica,sans-serif;fill:#111827}
    .body{font:400 19px Arial,Helvetica,sans-serif;fill:#1f2937}
    .body-bold{font:700 19px Arial,Helvetica,sans-serif;fill:#111827}
    .metric{font:700 23px Arial,Helvetica,sans-serif;fill:#0f4c9a}
    .small{font:400 16px Arial,Helvetica,sans-serif;fill:#4b5563}
    .foot{font:400 17px Arial,Helvetica,sans-serif;fill:#374151}
    .table-head{font:700 17px Arial,Helvetica,sans-serif;fill:#ffffff}
    .table-header{font:700 16px Arial,Helvetica,sans-serif;fill:#111827}
    .table{font:400 17px Arial,Helvetica,sans-serif;fill:#1f2937}
    .table-strong{font:700 17px Arial,Helvetica,sans-serif;fill:#0f4c9a}
    .axis{font:400 16px Arial,Helvetica,sans-serif;fill:#374151}
    .grid{stroke:#d1d5db;stroke-width:1;stroke-dasharray:5 5}
    .rule{stroke:#102f5e;stroke-width:1.5}
    .thin{stroke:#9ca3af;stroke-width:1}
    .box{fill:#ffffff;stroke:#6b7280;stroke-width:1.2}
    .box-blue{fill:#ffffff;stroke:#1456a0;stroke-width:1.4}
"""


def format_fixed(value, places, comma=False):
    quantum = Decimal(1).scaleb(-places)
    rendered = format(value.quantize(quantum, rounding=ROUND_HALF_UP), ".{}f".format(places))
    if comma:
        integer, dot, fraction = rendered.partition(".")
        rendered = "{:,}".format(int(integer)) + (dot + fraction if dot else "")
    return rendered


def format_signed(value, places):
    rendered = format_fixed(value, places)
    return rendered if value < 0 else "+" + rendered


def performance_scaling_points(scaling, single_engine_cycles):
    """Return one Evidence-derived geometry record per measured Engine count."""
    engine_x = {1: 885, 2: 1120, 4: 1420}
    plot_y_at_one = Decimal(575)
    plot_y_at_four = Decimal(250)
    y_per_normalized_unit = (plot_y_at_one - plot_y_at_four) / Decimal(3)
    points = []
    for engine in (1, 2, 4):
        actual = single_engine_cycles / Decimal(scaling[engine]["effective_cycles_per_block"])
        ideal = Decimal(engine)
        actual_y = rounded_int(plot_y_at_one - (actual - Decimal(1)) * y_per_normalized_unit)
        ideal_y = rounded_int(plot_y_at_one - (ideal - Decimal(1)) * y_per_normalized_unit)
        label_y = actual_y + 31 if engine == 4 else actual_y - 27
        points.append(
            {
                "engine": engine,
                "x": engine_x[engine],
                "ideal_y": ideal_y,
                "actual_y": actual_y,
                "label_y": label_y,
                "actual": actual,
            }
        )
    return points


def performance_evolution_svg(data):
    bitpacker = data["bitpacker"]
    scaling = data["scaling"]
    block_baseline = Decimal(bitpacker["baseline"]["steady_state_cycles_per_block"])
    block_optimized = Decimal(bitpacker["optimized"]["steady_state_cycles_per_block"])
    payload_baseline = Decimal(bitpacker["baseline"]["payload_stream_cycles"])
    payload_optimized = Decimal(bitpacker["optimized"]["payload_stream_cycles"])
    service_speedup = (block_baseline / block_optimized).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    payload_speedup = (payload_baseline / payload_optimized).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    scaling_points = performance_scaling_points(scaling, block_optimized)
    efficiency = {
        engine: (Decimal(scaling[engine]["scaling_efficiency_vs_single_engine"]) * Decimal(100)).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP
        )
        for engine in (2, 4)
    }
    actual_points = " ".join("{x},{actual_y}".format(**point) for point in scaling_points)
    ideal_points = " ".join("{x},{ideal_y}".format(**point) for point in scaling_points)
    measured_circles = "".join(
        '<circle id="actual-point-{engine}" data-engine="{engine}" '
        'data-normalized-throughput="{actual_text}" cx="{x}" cy="{actual_y}" r="9"/>'.format(
            actual_text=compact_decimal(point["actual"]), **point
        )
        for point in scaling_points
    )
    measured_labels = "".join(
        '<text id="actual-label-{engine}" data-engine="{engine}" x="{x}" y="{label_y}">'
        '{value}&#215;</text>'.format(
            value=format_fixed(point["actual"], 3), **point
        )
        for point in scaling_points
    )
    engine_labels = "".join(
        '<text x="{x}" y="630">{engine} Engine{suffix}</text>'.format(
            suffix="" if point["engine"] == 1 else "s", **point
        )
        for point in scaling_points
    )

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" viewBox="0 0 1600 1000" role="img" aria-labelledby="title desc" preserveAspectRatio="xMidYMid meet">
  <title id="title">RDTC Performance Evolution</title>
  <desc id="desc">Historical fixed RTL evidence separates the Stage16C3 to Stage16D2 single-Engine datapath improvement from measured two- and four-Engine scaling.</desc>
  <defs><marker id="arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="#374151"/></marker></defs>
  <style>{REPORT_STYLE}</style>
  <rect width="1600" height="1000" fill="#ffffff"/>
  <text x="48" y="58" class="title">RDTC Performance Evolution</text>
  <text x="48" y="92" class="subtitle">Single-Engine Datapath Optimization and Multi-Engine Scaling</text>
  <line x1="48" y1="116" x2="1552" y2="116" class="rule"/>
  <line x1="770" y1="142" x2="770" y2="900" class="thin"/>

  <text x="55" y="163" class="panel-title">(a) Single-Engine Datapath Optimization</text>
  <text x="58" y="218" class="section">Stage16C3 baseline</text>
  <text x="58" y="286" class="body">Input</text><text x="49" y="310" class="body">AXIS128</text>
  <line x1="122" y1="293" x2="165" y2="293" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="174" y="250" width="155" height="86" class="box"/><text x="252" y="286" text-anchor="middle" class="body">Sample</text><text x="252" y="310" text-anchor="middle" class="body">Serializer</text>
  <line x1="329" y1="293" x2="373" y2="293" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="382" y="250" width="220" height="86" class="box"/><text x="492" y="283" text-anchor="middle" class="body">Serial Cursor</text><text x="492" y="309" text-anchor="middle" class="body">+ OR Accumulation</text>
  <line x1="602" y1="293" x2="646" y2="293" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <text x="688" y="286" text-anchor="middle" class="body">Output</text><text x="688" y="310" text-anchor="middle" class="body">Packet</text>
  <text x="380" y="375" text-anchor="middle" class="metric">{format_fixed(block_baseline, 0)} cycles/block</text>

  <line x1="55" y1="411" x2="735" y2="411" class="grid"/>
  <text x="58" y="461" class="panel-title">Stage16D2 optimized</text>
  <text x="58" y="537" class="body">Input</text><text x="49" y="561" class="body">AXIS128</text>
  <line x1="122" y1="544" x2="165" y2="544" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="174" y="495" width="155" height="98" class="box-blue"/><text x="252" y="531" text-anchor="middle" class="body-bold">Lane4 Word</text><text x="252" y="557" text-anchor="middle" class="body-bold">Bitpacker</text>
  <line x1="329" y1="544" x2="373" y2="544" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="382" y="495" width="220" height="98" class="box-blue"/><text x="492" y="526" text-anchor="middle" class="body-bold">Suffix-Sum + Pipelined</text><text x="492" y="552" text-anchor="middle" class="body-bold">Shift / OR Tree</text>
  <line x1="602" y1="544" x2="646" y2="544" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <text x="688" y="537" text-anchor="middle" class="body">Output</text><text x="688" y="561" text-anchor="middle" class="body">Packet</text>
  <text x="380" y="636" text-anchor="middle" class="metric">{format_fixed(block_optimized, 0)} cycles/block</text>
  <rect x="55" y="676" width="330" height="120" class="box"/><text x="220" y="713" text-anchor="middle" class="body-bold">Service-rate improvement</text><text x="220" y="758" text-anchor="middle" class="metric">{format_fixed(service_speedup, 2)}&#215;</text>
  <rect x="405" y="676" width="330" height="120" class="box"/><text x="570" y="713" text-anchor="middle" class="body-bold">Separate payload interval</text><text x="570" y="750" text-anchor="middle" class="metric">{format_fixed(payload_baseline, 0)} -&gt; {format_fixed(payload_optimized, 0)} cycles</text><text x="570" y="777" text-anchor="middle" class="small">{format_fixed(payload_speedup, 2)}&#215;; bit-exact packet bytes</text>
  <text x="55" y="832" class="small">The 8220-&gt;785 block-spacing result and 7693-&gt;721 payload interval use</text>
  <text x="55" y="855" class="small">separate fixed historical RTL measurements. Packet bytes are bit-exact within each corresponding A/B.</text>

  <text x="802" y="163" class="panel-title">(b) Multi-Engine Scaling Efficiency</text>
  <text x="808" y="205" class="section">Normalized throughput (higher is better)</text>
  <line x1="850" y1="250" x2="850" y2="600" stroke="#374151" stroke-width="1.5"/><line x1="850" y1="600" x2="1510" y2="600" stroke="#374151" stroke-width="1.5"/>
  <g class="grid"><line x1="850" y1="575" x2="1510" y2="575"/><line x1="850" y1="467" x2="1510" y2="467"/><line x1="850" y1="358" x2="1510" y2="358"/><line x1="850" y1="250" x2="1510" y2="250"/></g>
  <g class="axis" text-anchor="end"><text x="838" y="581">1.0</text><text x="838" y="473">2.0</text><text x="838" y="364">3.0</text><text x="838" y="256">4.0</text></g>
  <polyline id="ideal-throughput-polyline" points="{ideal_points}" fill="none" stroke="#6b7280" stroke-width="2.5" stroke-dasharray="9 7"/>
  <polyline id="actual-throughput-polyline" points="{actual_points}" fill="none" stroke="#1456a0" stroke-width="4"/>
  <g id="actual-throughput-points" fill="#1456a0" stroke="#ffffff" stroke-width="2">{measured_circles}</g>
  <g id="actual-throughput-labels" class="metric" text-anchor="middle">{measured_labels}</g>
  <g class="body-bold" text-anchor="middle">{engine_labels}</g>
  <rect x="805" y="666" width="710" height="142" fill="#ffffff" stroke="#6b7280" stroke-width="1"/>
  <rect x="805" y="666" width="710" height="40" fill="#102f5e"/>
  <g class="table-head" text-anchor="middle"><text x="1000" y="692">1 Engine</text><text x="1200" y="692">2 Engines</text><text x="1405" y="692">4 Engines</text></g>
  <line x1="920" y1="666" x2="920" y2="808" class="thin"/><line x1="1090" y1="666" x2="1090" y2="808" class="thin"/><line x1="1300" y1="666" x2="1300" y2="808" class="thin"/><line x1="805" y1="754" x2="1515" y2="754" class="thin"/>
  <g class="table"><text x="820" y="736">cycles/block</text><text x="820" y="790">scaling efficiency</text></g>
  <g class="table-strong" text-anchor="middle"><text x="1000" y="736">{format_fixed(Decimal(scaling[1]['effective_cycles_per_block']), 0)}</text><text x="1200" y="736">{format_fixed(Decimal(scaling[2]['effective_cycles_per_block']), 2)}</text><text x="1405" y="736">{format_fixed(Decimal(scaling[4]['effective_cycles_per_block']), 2)}</text><text x="1000" y="790">baseline</text><text x="1200" y="790">{format_fixed(efficiency[2], 2)}%</text><text x="1405" y="790">{format_fixed(efficiency[4], 2)}%</text></g>
  <text x="805" y="837" class="body-bold">Packet-level atomic output</text>
  <text x="805" y="864" class="body">Packet beats do not interleave; Frame/Block identity is preserved;</text>
  <text x="805" y="889" class="body">completion order is not guaranteed.</text>
  <text x="805" y="914" class="small">785 cycles/block is the imported Stage16D2 reference, not a wrapper NUM_ENGINES=1 rerun.</text>

  <line x1="48" y1="923" x2="1552" y2="923" class="thin"/>
  <text x="48" y="952" class="foot">Historical fixed RTL workloads; cycle metrics are service/payload intervals, not one-block latency.</text>
  <text x="48" y="978" class="foot">Not Direct-AXIS sustained throughput, FPGA/ASIC timing, board bandwidth, or Fmax.</text>
</svg>
"""


def stage1_architecture_power_svg(metrics):
    rows = (
        ("Cell area", metrics["area_total_um2"], 2, True, "um2"),
        ("Cell count", metrics["cell_count"], 0, True, ""),
        ("Dynamic power", metrics["dynamic_mw"], 4, False, "mW"),
        ("Total power", metrics["total_mw"], 2, False, "mW"),
        ("Energy/block", metrics["energy_per_block_nj"], 4, False, "nJ"),
    )
    table_rows = []
    for index, (label, values, places, comma, unit) in enumerate(rows):
        y = 356 + index * 77
        baseline = format_fixed(values["baseline"], places, comma=comma)
        candidate = format_fixed(values["candidate"], places, comma=comma)
        percent = format_signed(values["percent"], 2) + "%"
        suffix = " " + unit if unit else ""
        table_rows.append(
            f'  <line x1="840" y1="{y + 28}" x2="1530" y2="{y + 28}" class="thin"/>'
            f'<text x="850" y="{y}" class="table">{label}</text>'
            f'<text x="1110" y="{y}" text-anchor="middle" class="table">{baseline}{suffix}</text>'
            f'<text x="1335" y="{y}" text-anchor="middle" class="table-strong">{candidate}{suffix}</text>'
            f'<text x="1505" y="{y}" text-anchor="end" class="table-strong">{percent}</text>'
        )

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" viewBox="0 0 1600 1000" role="img" aria-labelledby="title desc" preserveAspectRatio="xMidYMid meet">
  <title id="title">Stage 1 &#8212; Buffered to Direct-AXIS: Architecture PPA and Power Optimization</title>
  <desc id="desc">A controlled two-Engine mapped-DC study compares the Buffered wrapper against Direct-AXIS using RTL-SAIF-to-mapped activity at 315 MHz.</desc>
  <defs><marker id="arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="#374151"/></marker></defs>
  <style>{REPORT_STYLE}</style>
  <rect width="1600" height="1000" fill="#ffffff"/>
  <text x="48" y="58" class="title">Stage 1 &#8212; Buffered to Direct-AXIS: Architecture PPA and Power Optimization</text>
  <text x="48" y="92" class="subtitle">Two-Engine RDTC Wrapper, Nangate45 TT / 1.1 V / 25 C, 315 MHz, Activity-Driven Mapped-Netlist Estimate</text>
  <line x1="48" y1="116" x2="1552" y2="116" class="rule"/>

  <rect x="48" y="150" width="740" height="700" fill="#ffffff" stroke="#102f5e" stroke-width="1.4"/>
  <rect x="48" y="150" width="740" height="52" fill="#102f5e"/><text x="418" y="185" text-anchor="middle" class="table-head">Architecture Change</text>
  <g id="stage1-buffered-architecture">
  <text x="72" y="244" class="panel-title">Buffered</text>
  <rect x="72" y="285" width="70" height="76" class="box"/><text x="107" y="331" text-anchor="middle" class="body">Input</text>
  <line x1="142" y1="323" x2="154" y2="323" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="160" y="285" width="100" height="76" class="box"/><text x="210" y="331" text-anchor="middle" class="small">DDR Feeder</text>
  <line x1="260" y1="323" x2="272" y2="323" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="278" y="285" width="112" height="76" class="box-blue"/><text x="334" y="329" text-anchor="middle" class="small">Codec Engine</text>
  <line x1="390" y1="323" x2="402" y2="323" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="408" y="267" width="220" height="112" fill="#ffffff" stroke="#102f5e" stroke-width="1.3" stroke-dasharray="7 5"/><text x="518" y="302" text-anchor="middle" class="small">Per-Engine Payload-Commit</text><text x="518" y="332" text-anchor="middle" class="small">Storage</text>
  <line x1="628" y1="323" x2="640" y2="323" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="646" y="285" width="116" height="76" class="box"/><text x="704" y="331" text-anchor="middle" class="body">Output</text>
  <text x="418" y="414" text-anchor="middle" class="small">Storage-heavy wrapper responsibilities</text>
  </g>
  <line x1="72" y1="456" x2="764" y2="456" class="thin"/>

  <g id="stage1-direct-architecture">
  <text x="72" y="508" class="panel-title">Direct-AXIS</text>
  <rect x="72" y="550" width="70" height="76" class="box"/><text x="107" y="596" text-anchor="middle" class="body">Input</text>
  <line x1="142" y1="588" x2="154" y2="588" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="160" y="538" width="190" height="100" class="box-blue"/><text x="255" y="570" text-anchor="middle" class="small">Direct AXIS /</text><text x="255" y="600" text-anchor="middle" class="small">Four-Way Shallow Ring</text>
  <line x1="350" y1="588" x2="362" y2="588" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="368" y="550" width="117" height="76" class="box-blue"/><text x="426" y="594" text-anchor="middle" class="small">Codec Engine</text>
  <line x1="485" y1="588" x2="497" y2="588" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <g aria-label="Shared Output FIFO"><rect x="503" y="550" width="132" height="76" class="box-blue"/><text x="569" y="578" text-anchor="middle" class="small">Shared Output</text><text x="569" y="605" text-anchor="middle" class="small">FIFO</text></g>
  <line x1="635" y1="588" x2="647" y2="588" stroke="#374151" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="653" y="550" width="109" height="76" class="box"/><text x="707" y="596" text-anchor="middle" class="body">Output</text>
  </g>
  <text x="418" y="680" text-anchor="middle" class="metric">Removed DDR feeder and per-Engine payload-commit storage.</text>
  <text x="72" y="735" class="small">Both profiles contain the Codec Engine; Direct retains its bounded Ring and shared FIFO.</text>
  <text x="72" y="770" class="small">The wrapper interfaces and storage responsibilities are intentionally different.</text>

  <rect x="812" y="150" width="740" height="540" fill="#ffffff" stroke="#102f5e" stroke-width="1.4"/>
  <rect x="812" y="150" width="740" height="52" fill="#102f5e"/><text x="1182" y="185" text-anchor="middle" class="table-head">Measured Impact &#8212; BURST_IDLE Workload</text>
  <rect x="812" y="218" width="740" height="55" fill="#eef3f8"/>
  <g class="table-header"><text x="850" y="252">Metric</text><text x="1110" y="241" text-anchor="middle">Buffered</text><text x="1110" y="263" text-anchor="middle">reference</text><text x="1315" y="252" text-anchor="middle">Direct-AXIS</text><text x="1505" y="241" text-anchor="end">Delta</text><text x="1505" y="263" text-anchor="end">Direct vs Buffered</text></g>
{''.join(table_rows)}
  <rect x="812" y="720" width="740" height="130" fill="#f7f9fc" stroke="#1456a0" stroke-width="1.4"/>
  <text x="850" y="761" class="panel-title">Measured cause</text>
  <text x="850" y="797" class="body">Main savings come from wrapper storage and data-movement changes,</text>
  <text x="850" y="827" class="body">not removal of codec computation; Codec-Engine power remains at a similar level.</text>

  <line x1="48" y1="886" x2="1552" y2="886" class="thin"/>
  <text x="48" y="923" class="foot">Controlled A/B under normalized Codec work and Packet-output contract; the Buffered and Direct wrapper architectures differ.</text>
  <text x="48" y="953" class="foot">Same library/corner and 315 MHz point; RTL-SAIF-to-mapped power estimate, not post-route or silicon power.</text>
</svg>
"""


def stage2_clock_gating_power_svg(data):
    points = data["points"]
    comparisons = data["comparisons"]
    clock = data["clock"]
    g0 = points["G0_BURST_IDLE"]
    g1 = points["G1_BURST_IDLE"]
    area = comparisons[("IMPLEMENTATION", "area_total_um2")]
    energy = comparisons[("BURST_IDLE", "energy_per_block_nj")]
    icg_count = clock[("G1", "icg_count")]
    gated_bits = clock[("G1", "gated_bits")]
    ring_gated_bits = clock[("G1", "ring_gated_bits")]
    ring_total_bits = clock[("G1", "ring_total_bits")]
    ring_coverage = clock[("G1", "ring_coverage_pct")]
    idle_cycles = Decimal(points["G0_IDLE"]["window_cycles"])
    burst_blocks = Decimal(points["G0_BURST_IDLE"]["blocks_completed"])
    active_blocks = Decimal(points["G0_ACTIVE_LEGAL"]["blocks_completed"])
    chart_left = 740
    chart_right = 1530
    plot_top = 275
    plot_bottom = 690
    plot_height = plot_bottom - plot_top
    axis_max = Decimal("120")
    centers = {"IDLE": 830, "BURST_IDLE": 1110, "ACTIVE_LEGAL": 1390}
    bars = []
    for workload in CLOCK_GATING_WORKLOADS:
        center = centers[workload]
        for variant, x, color in (("G0", center - 75, "#8b9199"), ("G1", center + 5, "#1456a0")):
            value = data["dynamic"][workload][variant]
            height = rounded_int(value * Decimal(plot_height) / axis_max)
            y = plot_bottom - height
            bars.append(f'<rect x="{x}" y="{y}" width="62" height="{height}" fill="{color}"/>')
            bars.append(f'<text x="{x + 31}" y="{y - 12}" text-anchor="middle" class="body-bold">{format_fixed(value, 4)}</text>')
        change = Decimal(comparisons[(workload, "dynamic_mw")]["percent_change"])
        bars.append(f'<text x="{center}" y="225" text-anchor="middle" class="metric">{format_signed(change, 2)}%</text>')

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" viewBox="0 0 1600 1000" role="img" aria-labelledby="title desc" preserveAspectRatio="xMidYMid meet">
  <title id="title">Stage 2 &#8212; Automatic Clock Gating on the Direct Profile</title>
  <desc id="desc">Direct G0 ungated and Direct G1 clock-gated mapped-netlist dynamic power are compared for IDLE, BURST_IDLE, and ACTIVE_LEGAL at 315 MHz in functional mode.</desc>
  <style>{REPORT_STYLE}</style>
  <rect width="1600" height="1000" fill="#ffffff"/>
  <text x="48" y="58" class="title">Stage 2 &#8212; Automatic Clock Gating on the Direct Profile</text>
  <text x="48" y="92" class="subtitle">Direct Register-Expanded Profile, Nangate45 TT / 1.1 V / 25 C, 315 MHz, Activity-Driven Mapped-Netlist Estimate</text>
  <line x1="48" y1="116" x2="1552" y2="116" class="rule"/>

  <rect x="48" y="150" width="560" height="430" fill="#ffffff" stroke="#102f5e" stroke-width="1.4"/>
  <rect x="48" y="150" width="560" height="52" fill="#102f5e"/><text x="328" y="185" text-anchor="middle" class="table-head">Clock-Gating Summary</text>
  <g class="body"><text x="78" y="245">{format_fixed(icg_count, 0)} x CLKGATETST_X1 inserted</text><text x="78" y="285">{format_fixed(gated_bits, 0, comma=True)} gated bits</text><text x="78" y="325">Ring: {format_fixed(ring_gated_bits, 0, comma=True)} / {format_fixed(ring_total_bits, 0, comma=True)} bits ({format_fixed(ring_coverage, 0)}% Ring-data coverage)</text><text x="78" y="365" class="small">Cell area: {format_fixed(Decimal(area['baseline']), 2, comma=True)} -&gt; {format_fixed(Decimal(area['candidate']), 2, comma=True)} um2</text><text x="548" y="365" text-anchor="end" class="metric">{format_signed(Decimal(area['percent_change']), 2)}%</text><text x="78" y="405">Setup WNS: {format_signed(Decimal(g0['setup_wns_ns']), 6)} -&gt; {format_signed(Decimal(g1['setup_wns_ns']), 7)} ns</text><text x="78" y="445">Electrical violations: {g0['electrical_violations']} -&gt; {g1['electrical_violations']}</text><text x="78" y="485">Gating setup / hold WNS: +{compact_decimal(clock[('G1', 'gating_setup_wns')])} / +{compact_decimal(clock[('G1', 'gating_hold_wns')])} ns</text><text x="78" y="525" class="small">BURST_IDLE energy/block: {format_fixed(Decimal(energy['baseline']), 2)} -&gt; {format_fixed(Decimal(energy['candidate']), 2)} nJ</text><text x="548" y="525" text-anchor="end" class="metric">{format_signed(Decimal(energy['percent_change']), 2)}%</text></g>

  <rect x="48" y="610" width="560" height="245" fill="#ffffff" stroke="#102f5e" stroke-width="1.4"/>
  <rect x="48" y="610" width="560" height="52" fill="#102f5e"/><text x="328" y="645" text-anchor="middle" class="table-head">Workloads</text>
  <text x="78" y="703" class="body-bold">IDLE</text><text x="230" y="703" class="body">{format_fixed(idle_cycles, 0)} measured cycles; no traffic</text>
  <text x="78" y="751" class="body-bold">BURST_IDLE</text><text x="230" y="751" class="body">{format_fixed(burst_blocks, 0)} blocks; four groups of eight blocks</text><text x="230" y="777" class="small">drain + 1024 idle cycles after each group</text>
  <text x="78" y="825" class="body-bold">ACTIVE_LEGAL</text><text x="230" y="825" class="body">{format_fixed(active_blocks, 0)} blocks; 320-cycle block-start interval</text><text x="230" y="848" class="small">no artificial long idle gap</text>

  <rect x="650" y="150" width="902" height="705" fill="#ffffff" stroke="#102f5e" stroke-width="1.4"/>
  <text x="1101" y="192" text-anchor="middle" class="panel-title">Dynamic Power Across Workloads</text>
  <g class="grid"><line x1="{chart_left}" y1="{plot_bottom}" x2="{chart_right}" y2="{plot_bottom}"/><line x1="{chart_left}" y1="586" x2="{chart_right}" y2="586"/><line x1="{chart_left}" y1="483" x2="{chart_right}" y2="483"/><line x1="{chart_left}" y1="379" x2="{chart_right}" y2="379"/><line x1="{chart_left}" y1="{plot_top}" x2="{chart_right}" y2="{plot_top}"/></g>
  <line x1="{chart_left}" y1="{plot_top}" x2="{chart_left}" y2="{plot_bottom}" stroke="#374151" stroke-width="1.5"/><line x1="{chart_left}" y1="{plot_bottom}" x2="{chart_right}" y2="{plot_bottom}" stroke="#374151" stroke-width="1.5"/>
  <g class="axis" text-anchor="end"><text x="725" y="696">0</text><text x="725" y="592">30</text><text x="725" y="489">60</text><text x="725" y="385">90</text><text x="725" y="281">120</text></g>
  <text x="680" y="485" text-anchor="middle" class="section" transform="rotate(-90 680 485)">Dynamic power (mW)</text>
  {''.join(bars)}
  <g class="body-bold" text-anchor="middle"><text x="830" y="730">IDLE</text><text x="1110" y="730">BURST_IDLE</text><text x="1390" y="730">ACTIVE_LEGAL</text></g>
  <rect x="945" y="775" width="22" height="22" fill="#8b9199"/><text x="978" y="792" class="body">G0 ungated</text><rect x="1165" y="775" width="22" height="22" fill="#1456a0"/><text x="1198" y="792" class="body">G1 clock-gated</text>
  <text x="1101" y="828" text-anchor="middle" class="small">ACTIVE_LEGAL is a high-duty legal compression workload, not maximum throughput.</text>

  <line x1="48" y1="890" x2="1552" y2="890" class="thin"/>
  <text x="48" y="927" class="foot">Independent Stage-2 A/B on the Direct Profile; Functional mode SE=0.</text>
  <text x="48" y="957" class="foot">Gate-level regression equivalence evidence; Formality, DFT signoff, CTS/post-route/PTPX, and silicon results are not claimed.</text>
</svg>
"""


def validate_xml(name, content):
    try:
        root = ET.fromstring(content)
    except ET.ParseError as error:
        raise ValueError("invalid SVG {}: {}".format(name, error))
    if "viewBox" not in root.attrib:
        raise ValueError("{} is missing viewBox".format(name))
    child_names = {child.tag.rsplit("}", 1)[-1] for child in root}
    for required_child in ("title", "desc"):
        if required_child not in child_names:
            raise ValueError("{} is missing {}".format(name, required_child))
    for element in root.iter():
        local_name = element.tag.rsplit("}", 1)[-1]
        if local_name == "image":
            raise ValueError("{} embeds raster image data".format(name))
        for attribute, value in element.attrib.items():
            if attribute.rsplit("}", 1)[-1] == "href" and re.match(r"(?i)^(?:https?:|data:)", value):
                raise ValueError("{} contains an external or embedded image reference".format(name))


def validate_authored_asset_semantics(name, content):
    rules = AUTHORED_ASSET_RULES.get(name)
    if not rules:
        return
    for fragment in rules["required"]:
        if fragment not in content:
            raise ValueError("{} is missing required text: {}".format(name, fragment))
    for fragment in rules["forbidden"]:
        if fragment in content:
            raise ValueError("{} contains obsolete text: {}".format(name, fragment))


def validate_generated_asset_semantics(name, content):
    rules = GENERATED_ASSET_RULES.get(name)
    if not rules:
        return
    for fragment in rules["required"]:
        if fragment not in content:
            raise ValueError("{} is missing required text: {}".format(name, fragment))
    for fragment in rules["forbidden"]:
        if fragment in content:
            raise ValueError("{} contains forbidden text: {}".format(name, fragment))
    content_without_namespace = content.replace('xmlns="http://www.w3.org/2000/svg"', "")
    for fragment in PURE_SVG_FORBIDDEN:
        if fragment in content_without_namespace:
            raise ValueError("{} contains non-portable SVG content: {}".format(name, fragment))
    if name == "rdtc_stage2_clock_gating_power.svg" and re.search(
        r"\bis\s+(?:the\s+)?maximum throughput\b", content, re.IGNORECASE
    ):
        raise ValueError("{} promotes ACTIVE_LEGAL to maximum throughput".format(name))
    if name.startswith("rdtc_") and name in GENERATED_ASSETS:
        if 'width="1600" height="1000" viewBox="0 0 1600 1000"' not in content:
            if name in (
                "rdtc_performance_evolution.svg",
                "rdtc_stage1_architecture_ppa_power.svg",
                "rdtc_stage2_clock_gating_power.svg",
            ):
                raise ValueError("{} does not use the coordinated 1600x1000 canvas".format(name))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[2]),
        help="repository root",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write generated charts")
    mode.add_argument("--check", action="store_true", help="fail when charts are stale")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    data_dir = root / "evidence" / "data"
    assets_dir = root / "docs" / "assets"

    snr_values, compression_data = load_compression_data(
        data_dir / "rdtc_v1_matlab_lossless_snr.csv"
    )
    scaling_data = load_scaling_data(data_dir / "rdtc_v1_multiengine_scaling.csv")
    bitpacker_data = load_bitpacker_data(data_dir / "rdtc_v1_bitpacker_pipeline_ab.csv")
    direct_timing_data = load_direct_timing_data(
        data_dir / "rdtc_v1_direct_stream_timing_nominal.csv",
        data_dir / "rdtc_v1_direct_stream_timing_backpressure.csv",
    )
    clock_gating_data = load_clock_gating_power_data(
        root / "evidence" / "rdtc_v1_clock_gating_mapped_dc" / "points.csv"
    )
    performance_report_data = load_performance_report_data(root)
    architecture_power_report_data = load_architecture_power_report_data(root)
    clock_gating_report_data = load_clock_gating_report_data(root)
    expected = {
        "bitpacker_pipeline_ab.svg": bitpacker_svg(bitpacker_data),
        "clock_gating_power_ab.svg": clock_gating_power_svg(clock_gating_data),
        "compression_vs_snr.svg": compression_svg(snr_values, compression_data),
        "engine_scaling.svg": scaling_svg(scaling_data, bitpacker_data),
        "rdtc_multiengine_packet_timing.svg": direct_multiengine_packet_timing_svg(direct_timing_data),
        "rdtc_performance_evolution.svg": performance_evolution_svg(performance_report_data),
        "rdtc_stage1_architecture_ppa_power.svg": stage1_architecture_power_svg(architecture_power_report_data),
        "rdtc_stage2_clock_gating_power.svg": stage2_clock_gating_power_svg(clock_gating_report_data),
        "rdtc_stream_timing.svg": direct_stream_timing_svg(direct_timing_data),
    }

    for name, content in expected.items():
        validate_xml(name, content)
        validate_generated_asset_semantics(name, content)

    if args.write:
        assets_dir.mkdir(parents=True, exist_ok=True)
        for name, content in expected.items():
            (assets_dir / name).write_text(content, encoding="utf-8", newline="\n")
            print("showcase-assets: wrote {}".format(assets_dir / name))
        for name in OBSOLETE_ASSETS:
            path = assets_dir / name
            if path.exists():
                path.unlink()
                print("showcase-assets: removed obsolete {}".format(path))
    else:
        stale = []
        for name, content in expected.items():
            path = assets_dir / name
            if not path.is_file() or path.read_text(encoding="utf-8") != content:
                stale.append(name)
        stale.extend(name for name in OBSOLETE_ASSETS if (assets_dir / name).exists())
        if stale:
            print(
                "showcase-assets: stale generated assets: {}".format(", ".join(stale)),
                file=sys.stderr,
            )
            print(
                "run: python flows/scripts/generate_showcase_assets.py --write",
                file=sys.stderr,
            )
            return 1

    for name in GENERATED_ASSETS + AUTHORED_ASSETS:
        path = assets_dir / name
        if not path.is_file():
            print("showcase-assets: missing {}".format(path), file=sys.stderr)
            return 1
        content = path.read_text(encoding="utf-8")
        validate_xml(name, content)
        validate_authored_asset_semantics(name, content)
        validate_generated_asset_semantics(name, content)

    for name, expected in BINARY_ASSETS.items():
        path = assets_dir / name
        if not path.is_file():
            print("showcase-assets: missing {}".format(path), file=sys.stderr)
            return 1
        payload = path.read_bytes()
        actual_sha256 = hashlib.sha256(payload).hexdigest()
        if actual_sha256 != expected["sha256"]:
            print(
                "showcase-assets: hash mismatch {} expected={} actual={}".format(
                    path, expected["sha256"], actual_sha256
                ),
                file=sys.stderr,
            )
            return 1
        if len(payload) != expected["size_bytes"]:
            print("showcase-assets: size mismatch {}".format(path), file=sys.stderr)
            return 1
        if payload[:8] != b"\x89PNG\r\n\x1a\n" or payload[12:16] != b"IHDR":
            print("showcase-assets: invalid PNG {}".format(path), file=sys.stderr)
            return 1
        dimensions = (
            int.from_bytes(payload[16:20], byteorder="big"),
            int.from_bytes(payload[20:24], byteorder="big"),
        )
        if dimensions != expected["dimensions_px"]:
            print("showcase-assets: dimensions mismatch {}".format(path), file=sys.stderr)
            return 1

    print(
        "showcase-assets: PASS generated={} authored={} binary={}".format(
            len(GENERATED_ASSETS), len(AUTHORED_ASSETS), len(BINARY_ASSETS)
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
