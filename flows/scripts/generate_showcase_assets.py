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
    "compression_vs_snr.svg",
    "engine_scaling.svg",
)

AUTHORED_ASSETS = (
    "rdtc_overview.svg",
    "system_context.svg",
    "single_engine_pipeline.svg",
    "multi_engine_wrapper.svg",
    "zynq_emulation_path.svg",
)

BINARY_ASSETS = {
    "matlab/rdb_before_after_rdtc_zero_rice.png": {
        "sha256": "005d1e9e03784faa9655633b203f6c4917bb84e9aaf02a7a47ae866a2f857d8b",
        "size_bytes": 56847,
        "dimensions_px": (875, 656),
    },
}

AUTHORED_ASSET_RULES = {
    "rdtc_overview.svg": {
        "required": (
            "MRTC-RDTC: sensing tensor to bit-exact reconstruction",
            "N x independent Engine",
            "Packet-locked AXI",
            "no software reorder PASS claimed",
        ),
        "forbidden": (),
    },
    "single_engine_pipeline.svg": {
        "required": (
            "configured ZERO / DELTA",
            "Internal k-select",
            "RAW fallback only on supporting encoder paths",
        ),
        "forbidden": ("RAW / ZERO / DELTA",),
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
            "Round-Robin",
            "dispatcher",
            "Packet-locked",
            "arbiter",
            "completion order may vary",
            "no software reorder PASS claimed",
        ),
        "forbidden": (),
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


def scaling_svg(by_engine):
    cycles = {
        engine: Decimal(by_engine[engine]["effective_cycles_per_block"])
        for engine in (1, 2, 4)
    }
    y_positions = {
        engine: rounded_int(Decimal(500) - cycles[engine] * Decimal(412) / Decimal(800))
        for engine in (1, 2, 4)
    }
    heights = {engine: 500 - y_positions[engine] for engine in (1, 2, 4)}
    labels = {engine: compact_decimal(cycles[engine]) for engine in (1, 2, 4)}
    eff2 = by_engine[2]["scaling_efficiency_vs_single_engine"]
    eff4 = by_engine[4]["scaling_efficiency_vs_single_engine"]
    beam2 = by_engine[2]["beam_s_at_assumed_200mhz"]
    beam4 = by_engine[4]["beam_s_at_assumed_200mhz"]

    return """<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="620" viewBox="0 0 1000 620" role="img" aria-labelledby="title desc">
  <title id="title">Multi-Engine RTL simulation scaling</title>
  <desc id="desc">Cycles per block decrease from {label1} for one engine to {label2} for two engines and {label4} for four engines, with near-linear efficiency on the fixed 256-block RTL workload.</desc>
  <style>.title{{font:700 31px Arial,sans-serif;fill:#0f172a}}.sub{{font:400 17px Arial,sans-serif;fill:#475569}}.axis{{font:400 16px Arial,sans-serif;fill:#334155}}.label{{font:700 18px Arial,sans-serif;fill:#0f172a}}.value{{font:700 21px Arial,sans-serif;fill:#0f172a}}.light{{fill:#fff}}.grid{{stroke:#cbd5e1;stroke-width:1}}</style>
  <rect width="1000" height="620" fill="#f8fafc"/>
  <text x="55" y="48" class="title">Multi-Engine RTL simulation scaling</text>
  <text x="55" y="75" class="sub">Fixed 256-block workload with a simulated DDR feeder. Lower cycles/block is better.</text>

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
  <g class="label" text-anchor="middle"><text x="270" y="528">1 Engine</text><text x="515" y="528">2 Engines</text><text x="760" y="528">4 Engines</text></g>
  <g class="axis" text-anchor="middle">
    <text x="270" y="552">baseline</text>
    <text x="515" y="552">efficiency {eff2}</text>
    <text x="760" y="552">efficiency {eff4}</text>
    <text x="515" y="576">{beam2} beam/s at assumed 200 MHz</text>
    <text x="760" y="596">{beam4} beam/s at assumed 200 MHz</text>
  </g>
  <rect x="695" y="105" width="225" height="70" rx="6" fill="#fff7ed" stroke="#f59e0b"/>
  <text x="807" y="132" text-anchor="middle" class="label">RTL projection only</text>
  <text x="807" y="155" text-anchor="middle" class="axis">not FPGA timing or board throughput</text>
</svg>
""".format(
        y1=y_positions[1], h1=heights[1], t1=y_positions[1] + 28, label1=labels[1],
        y2=y_positions[2], h2=heights[2], t2=y_positions[2] - 10, label2=labels[2],
        y4=y_positions[4], h4=heights[4], t4=y_positions[4] - 10, label4=labels[4],
        eff2=eff2, eff4=eff4, beam2=beam2, beam4=beam4,
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
    expected = {
        "compression_vs_snr.svg": compression_svg(snr_values, compression_data),
        "engine_scaling.svg": scaling_svg(scaling_data),
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

    print("showcase-assets: PASS generated=2 authored=5 binary=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
