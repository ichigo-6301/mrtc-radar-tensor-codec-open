#!/usr/bin/env python3
"""Generate and check deterministic showcase charts from public evidence CSVs."""

import argparse
import csv
import hashlib
import sys
import xml.etree.ElementTree as ET
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path


GENERATED_ASSETS = (
    "bitpacker_pipeline_ab.svg",
    "compression_vs_snr.svg",
    "engine_scaling.svg",
)

AUTHORED_ASSETS = (
    "bounded_direct_dual_engine.svg",
    "rdtc_data_contract.svg",
    "rdtc_overview.svg",
    "rdtc_stream_timing.svg",
    "rdtc_way_ring.svg",
    "system_context.svg",
    "single_engine_pipeline.svg",
    "multi_engine_wrapper.svg",
    "zynq_emulation_path.svg",
)

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
            "N x independent Engine",
            "Packet-locked AXI",
            "no software reorder PASS claimed",
        ),
        "forbidden": (),
    },
    "rdtc_data_contract.svg": {
        "required": (
            "RDTC encoder-centric data contract",
            "Range-Doppler-Beam",
            "256 AXIS128 input beats",
            "4 header beats +",
            "variable payload beats",
            "Hardware RDTC",
            "PC/C decoder",
            "RTL decoder",
            "verification path",
            "bit-exact recovered I/Q",
            "does not implement FFT",
        ),
        "forbidden": ("TKEEP", "measured duty"),
    },
    "rdtc_stream_timing.svg": {
        "required": (
            "protocol schematic, not a measured waveform",
            "first 32 beats",
            "total input block = 256 accepted beats",
            "fixed four-beat header",
            "fixed two-clock request-to-response contract",
            "Legal capture",
            "TVALID burst",
            "TLAST",
            "TREADY",
            "Normal:",
            "Source II=1 does not imply continuous output TVALID.",
        ),
        "forbidden": ("277", "measured duty", "Every accepted beat"),
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


def read_csv(path):
    with path.open("r", encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream))


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
    expected = {
        "bitpacker_pipeline_ab.svg": bitpacker_svg(bitpacker_data),
        "compression_vs_snr.svg": compression_svg(snr_values, compression_data),
        "engine_scaling.svg": scaling_svg(scaling_data, bitpacker_data),
    }

    for name, content in expected.items():
        validate_xml(name, content)

    if args.write:
        assets_dir.mkdir(parents=True, exist_ok=True)
        for name, content in expected.items():
            (assets_dir / name).write_text(content, encoding="utf-8", newline="\n")
            print("showcase-assets: wrote {}".format(assets_dir / name))
    else:
        stale = []
        for name, content in expected.items():
            path = assets_dir / name
            if not path.is_file() or path.read_text(encoding="utf-8") != content:
                stale.append(name)
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
