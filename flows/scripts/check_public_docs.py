#!/usr/bin/env python3
"""Check public Markdown links and required bilingual release documentation."""

from __future__ import print_function

import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote


LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

PRIMARY_SHOWCASE_DOCS = (
    "README.md",
    "README.en.md",
    "docs/zh-CN/results.md",
    "docs/en/results.md",
    "docs/zh-CN/asic_implementation.md",
    "docs/en/asic_implementation.md",
    "docs/zh-CN/limitations.md",
    "docs/en/limitations.md",
    "docs/zh-CN/roadmap.md",
    "docs/en/roadmap.md",
)

README_MARKERS = {
    "README.md": (
        "rdtc_overview.svg",
        "选择集成入口",
        "RDTC_CODEC_DEMO_PASS",
        "FPGA emulation verified",
        "single-`s0`",
        "公开 Icarus-compatible",
        "软件 reorder 程序 PASS",
        "synthetic",
        "academic PDK/OpenRAM 实现范围",
        "fixed verified closure point",
        "mrtc_rdtc_bounded_axis_multiengine_wrapper",
        "277 cycles/block",
        "fixed closure point",
    ),
    "README.en.md": (
        "rdtc_overview.svg",
        "Choose an integration entrypoint",
        "RDTC_CODEC_DEMO_PASS",
        "FPGA emulation verified",
        "single-`s0`",
        "public Icarus-compatible",
        "software reorder program PASS",
        "synthetic",
        "academic PDK/OpenRAM implementation scope",
        "fixed verified closure point",
        "mrtc_rdtc_bounded_axis_multiengine_wrapper",
        "277 cycles/block",
        "fixed closure point",
    ),
}

REVIEW_README_MARKERS = {
    "README.md": (
        '<a id="resume-results"></a>',
        '<a id="rtl-reading-path"></a>',
        '<a id="technical-review-path"></a>',
        '<a id="public-scope-provenance"></a>',
        "7693 -> 721 cycles",
        "10.67×",
        "8220 -> 785 cycles/block",
        "10.47×",
        "785 / 397.52 / 197.41 cycles/block",
        "~277 > 256 cycles/block",
        "72.53% / 71.98%",
        "600/300 MHz",
        "make bitpacker-pipeline-ab-validate",
        "make bounded-dc-ab-validate",
        "make direct-stream-timing-validate",
        "不会重新执行 ModelSim、Design Compiler、P&R 或 PrimeTime",
        "docs/assets/bitpacker_pipeline_ab.svg",
        "docs/assets/engine_scaling.svg",
        'width="760"',
        "PUBLIC_SCOPE.md",
        "provenance/claims.yaml",
        "provenance/evidence.yaml",
        "provenance/nonclaims.yaml",
    ),
    "README.en.md": (
        '<a id="resume-results"></a>',
        '<a id="rtl-reading-path"></a>',
        '<a id="technical-review-path"></a>',
        '<a id="public-scope-provenance"></a>',
        "7693 -> 721 cycles",
        "10.67×",
        "8220 -> 785 cycles/block",
        "10.47×",
        "785 / 397.52 / 197.41 cycles/block",
        "~277 > 256 cycles/block",
        "72.53% / 71.98%",
        "600/300 MHz",
        "make bitpacker-pipeline-ab-validate",
        "make bounded-dc-ab-validate",
        "make direct-stream-timing-validate",
        "do not rerun ModelSim, Design Compiler, P&R, or PrimeTime",
        "docs/assets/bitpacker_pipeline_ab.svg",
        "docs/assets/engine_scaling.svg",
        'width="760"',
        "PUBLIC_SCOPE.md",
        "provenance/claims.yaml",
        "provenance/evidence.yaml",
        "provenance/nonclaims.yaml",
    ),
}

REVIEW_EVIDENCE_LINKS = {
    "README.md": (
        "evidence/rdtc_v1_reference_validation.yaml",
        "evidence/rdtc_v1_bitpacker_pipeline_ab.yaml",
        "evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv",
        "evidence/rdtc_v1_multiengine_rtl.yaml",
        "evidence/data/rdtc_v1_multiengine_scaling.csv",
        "evidence/rdtc_v1_bounded_direct_rtl.yaml",
        "evidence/rdtc_v1_direct_stream_timing_trace.yaml",
        "evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml",
        "evidence/rdtc_v1_bounded_direct_asic.yaml",
        "docs/zh-CN/results.md",
        "evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml",
    ),
    "README.en.md": (
        "evidence/rdtc_v1_reference_validation.yaml",
        "evidence/rdtc_v1_bitpacker_pipeline_ab.yaml",
        "evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv",
        "evidence/rdtc_v1_multiengine_rtl.yaml",
        "evidence/data/rdtc_v1_multiengine_scaling.csv",
        "evidence/rdtc_v1_bounded_direct_rtl.yaml",
        "evidence/rdtc_v1_direct_stream_timing_trace.yaml",
        "evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml",
        "evidence/rdtc_v1_bounded_direct_asic.yaml",
        "docs/en/results.md",
        "evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml",
    ),
}

DIRECT_DOC_MARKERS = {
    "docs/en/limitations.md": (
        "277 cycles/block",
        "MRTC_ERR_OUTPUT_CREDIT",
        "MACRO_MODEL_BLOCKED",
        "1 ps setup margin",
    ),
    "docs/zh-CN/limitations.md": (
        "277 cycles/block",
        "MRTC_ERR_OUTPUT_CREDIT",
        "MACRO_MODEL_BLOCKED",
        "1 ps setup",
    ),
    "docs/en/release_model.md": (
        "rdtc-v1-pre-bounded-direct-20260731",
        "277 cycles/block > 256 cycles/block",
    ),
    "docs/zh-CN/release_model.md": (
        "rdtc-v1-pre-bounded-direct-20260731",
        "277 cycles/block > 256 cycles/block",
    ),
    "docs/en/results.md": (
        "rdtc_v1_bounded_direct_rtl.yaml",
        "rdtc_v1_bounded_direct_fpga_ooc200.yaml",
        "rdtc_v1_bounded_direct_asic.yaml",
    ),
    "docs/zh-CN/results.md": (
        "rdtc_v1_bounded_direct_rtl.yaml",
        "rdtc_v1_bounded_direct_fpga_ooc200.yaml",
        "rdtc_v1_bounded_direct_asic.yaml",
    ),
}

DIRECT_EVIDENCE = (
    "evidence/rdtc_v1_bounded_direct_rtl.yaml",
    "evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml",
    "evidence/rdtc_v1_bounded_direct_asic.yaml",
    "evidence/data/rdtc_v1_bounded_direct_rtl_identity.csv",
    "evidence/rdtc_v1_direct_stream_timing_trace.yaml",
    "evidence/data/rdtc_v1_direct_stream_timing_nominal.csv",
    "evidence/data/rdtc_v1_direct_stream_timing_backpressure.csv",
)

DATA_CONTRACT_MARKERS = {
    "README.md": (
        '<a id="data-contract"></a>',
        "4096B 原始 Block 如何变成变长 Packet",
        "FFT backend output: S[beam][doppler][range]  (range fastest)",
        "1 block = 1 beam x 64 Doppler x 16 Range",
        "1024 I16Q16 complex samples = 4096 B",
        "256 AXIS128 beats",
        "4 complex samples / beat",
        "Predictor",
        "Signed map",
        "Adaptive k",
        "Rice bitpacker",
        "64 B header",
        "Variable-length payload",
        "final TLAST/TUSER",
        "PC/C decoder (header-length packet)",
        "RTL decoder",
        "STREAM_LENGTH_BY_TLAST",
        "仍需接收侧长度适配",
        "docs/zh-CN/bitstream_format.md#raw-axis-layout",
        "docs/zh-CN/bitstream_format.md#header-layout",
        "docs/zh-CN/architecture.md#four-way-shallow-input-ring",
        "docs/zh-CN/stream_timing.md#direct-engine0-trace",
    ),
    "README.en.md": (
        '<a id="data-contract"></a>',
        "From A 4096-Byte Raw Block To A Variable-Length Packet",
        "FFT backend output: S[beam][doppler][range]  (range fastest)",
        "1 block = 1 beam x 64 Doppler x 16 Range",
        "1024 I16Q16 complex samples = 4096 B",
        "256 AXIS128 beats",
        "4 complex samples / beat",
        "Predictor",
        "Signed map",
        "Adaptive k",
        "Rice bitpacker",
        "64 B header",
        "Variable-length payload",
        "final TLAST/TUSER",
        "PC/C decoder (header-length packet)",
        "RTL decoder",
        "STREAM_LENGTH_BY_TLAST",
        "require receive-side length adaptation",
        "docs/en/bitstream_format.md#raw-axis-layout",
        "docs/en/bitstream_format.md#header-layout",
        "docs/en/architecture.md#four-way-shallow-input-ring",
        "docs/en/stream_timing.md#direct-engine0-trace",
    ),
    "docs/zh-CN/bitstream_format.md": (
        '<a id="raw-axis-layout"></a>',
        '<a id="packet-wire-layout"></a>',
        '<a id="header-layout"></a>',
        '<a id="payload-order"></a>',
        '<a id="packet-length-contracts"></a>',
        "sample[31:0] = {Q[15:0], I[15:0]}",
        "Rice(map(rI0)), Rice(map(rQ0))",
        "MRTC_FLAG_STREAM_LENGTH_BY_TLAST",
        "physical packet beats = 4 + ceil(observed_payload_bytes / 16)",
        "C decoder | 支持 | **不支持**",
        "260/256 = 101.5625%",
        "不是测得的 duty cycle",
    ),
    "docs/en/bitstream_format.md": (
        '<a id="raw-axis-layout"></a>',
        '<a id="packet-wire-layout"></a>',
        '<a id="header-layout"></a>',
        '<a id="payload-order"></a>',
        '<a id="packet-length-contracts"></a>',
        "sample[31:0] = {Q[15:0], I[15:0]}",
        "Rice(map(rI0)), Rice(map(rQ0))",
        "MRTC_FLAG_STREAM_LENGTH_BY_TLAST",
        "physical packet beats = 4 + ceil(observed_payload_bytes / 16)",
        "C decoder | supported | **not supported**",
        "260/256 = 101.5625%",
        "not a measured duty cycle",
    ),
    "docs/zh-CN/architecture.md": (
        '<a id="four-way-shallow-input-ring"></a>',
        '<a id="stream-timing-contract"></a>',
        "rdtc_way_ring.svg",
        "prefix-128",
        "stream_timing.md#protocol-timing-contract",
        "合法、非 fatal capture",
        "MRTC_ERR_SRAM_WAY_CONFLICT",
    ),
    "docs/en/architecture.md": (
        '<a id="four-way-shallow-input-ring"></a>',
        '<a id="stream-timing-contract"></a>',
        "rdtc_way_ring.svg",
        "prefix-128",
        "stream_timing.md#protocol-timing-contract",
        "legal, non-fatal capture",
        "MRTC_ERR_SRAM_WAY_CONFLICT",
    ),
    "docs/zh-CN/interfaces.md": (
        "beat 255（第 256 拍）",
        "不导出 TKEEP",
        "低有效异步 datapath reset",
        "不清 sticky fatal status",
        "MRTC_ERR_BLOCK_NOT_READY",
    ),
    "docs/en/interfaces.md": (
        "beat 255, the 256th AXIS128 beat",
        "has no TKEEP",
        "active-low asynchronous datapath reset",
        "does not clear sticky fatal status",
        "MRTC_ERR_BLOCK_NOT_READY",
    ),
}

STREAM_TIMING_MARKERS = {
    "docs/zh-CN/stream_timing.md": (
        '<a id="protocol-timing-contract"></a>',
        '<a id="ii1-vs-output-tvalid"></a>',
        '<a id="direct-engine0-trace"></a>',
        '<a id="backpressure-hold"></a>',
        '<a id="multi-engine-packet-service"></a>',
        '<a id="measurement-boundaries"></a>',
        "rdtc_stream_timing.svg",
        "rdtc_multiengine_packet_timing.svg",
        "rdtc_v1_direct_stream_timing_trace.yaml",
        "rdtc_v1_direct_stream_timing_nominal.csv",
        "rdtc_v1_direct_stream_timing_backpressure.csv",
        "99dbd4b",
        "6..603",
        "51-52",
        "86-87",
        "20/72",
        "320/1151",
        "output data  : cycle 86 + 16*n, n = 0..15",
        "packet lock      owner changes only after accepted TLAST",
        "presented beat         H0  H1  H1  H1  H2  H3",
    ),
    "docs/en/stream_timing.md": (
        '<a id="protocol-timing-contract"></a>',
        '<a id="ii1-vs-output-tvalid"></a>',
        '<a id="direct-engine0-trace"></a>',
        '<a id="backpressure-hold"></a>',
        '<a id="multi-engine-packet-service"></a>',
        '<a id="measurement-boundaries"></a>',
        "rdtc_stream_timing.svg",
        "rdtc_multiengine_packet_timing.svg",
        "rdtc_v1_direct_stream_timing_trace.yaml",
        "rdtc_v1_direct_stream_timing_nominal.csv",
        "rdtc_v1_direct_stream_timing_backpressure.csv",
        "99dbd4b",
        "6..603",
        "51-52",
        "86-87",
        "20/72",
        "320/1151",
        "output data  : cycle 86 + 16*n, n = 0..15",
        "packet lock      owner changes only after accepted TLAST",
        "presented beat         H0  H1  H1  H1  H2  H3",
    ),
}


def tracked_markdown(root):
    output = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "--", "*.md"])
    return [root / item.decode("utf-8") for item in output.split(b"\0") if item]


def check(root):
    errors = []
    required = [root / "docs/zh-CN/release_model.md", root / "docs/en/release_model.md"]
    for path in required:
        if not path.is_file():
            errors.append("missing required release document: {}".format(path.relative_to(root)))
    for path in tracked_markdown(root):
        text = path.read_text(encoding="utf-8")
        for match in LINK.finditer(text):
            target = match.group(1).strip().split()[0].strip("<>")
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            relative = unquote(target.split("#", 1)[0])
            if relative and not (path.parent / relative).resolve().is_file():
                errors.append("broken link: {} -> {}".format(path.relative_to(root), target))
    for name in ("README.md", "README.en.md"):
        text = (root / name).read_text(encoding="utf-8")
        for marker in ("register550-rc3", "rdtc_v1_register_nangate45_550", "rdtc_v1_sram_nangate45_333"):
            if marker not in text:
                errors.append("{} missing release marker {}".format(name, marker))
        for marker in README_MARKERS[name]:
            if marker not in text:
                errors.append("{} missing showcase boundary {}".format(name, marker))
        for marker in REVIEW_README_MARKERS[name]:
            if marker not in text:
                errors.append("{} missing reviewer entrypoint {}".format(name, marker))
        for target in REVIEW_EVIDENCE_LINKS[name]:
            if "]({})".format(target) not in text and 'href="{}"'.format(target) not in text:
                errors.append("{} missing direct reviewer link {}".format(name, target))
    for name, markers in DIRECT_DOC_MARKERS.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing bounded Direct boundary {}".format(name, marker))
    for name, markers in DATA_CONTRACT_MARKERS.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing data-contract marker {}".format(name, marker))
    for name, markers in STREAM_TIMING_MARKERS.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing stream-timing marker {}".format(name, marker))
    legacy_data_contract = root / "docs/assets/rdtc_data_contract.svg"
    if legacy_data_contract.exists():
        errors.append("obsolete README data-contract SVG is still present")
    for name in ("README.md", "README.en.md"):
        readme_text = (root / name).read_text(encoding="utf-8")
        if "rdtc_data_contract.svg" in readme_text:
            errors.append("{} still references the obsolete data-contract SVG".format(name))
        if "Raw Tensor Block\n1 beam x 64 Doppler" in readme_text:
            errors.append("{} still contains the obsolete minimal data-contract diagram".format(name))
    for name in DIRECT_EVIDENCE:
        if not (root / name).is_file():
            errors.append("missing bounded Direct evidence: {}".format(name))
    for name in PRIMARY_SHOWCASE_DOCS:
        text = (root / name).read_text(encoding="utf-8")
        if re.search(r"ICS55|ICsprout55|ECOS", text, flags=re.IGNORECASE):
            errors.append("{} contains archived ICS55/ECOS material".format(name))
    for name in ("docs/zh-CN/algorithm.md", "docs/en/algorithm.md"):
        text = (root / name).read_text(encoding="utf-8")
        marker = "../assets/matlab/rdb_before_after_rdtc_zero_rice.png"
        if marker not in text:
            errors.append("{} missing original MATLAB figure".format(name))
    interface_markers = {
        "docs/zh-CN/interfaces.md": ("应该实例化哪个模块", "OUTPUT_IN_ORDER=1", "make codec-demo"),
        "docs/en/interfaces.md": ("Which module should I instantiate?", "OUTPUT_IN_ORDER=1", "make codec-demo"),
    }
    for name, markers in interface_markers.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing integration marker {}".format(name, marker))
    integration_path = root / "provenance/integration.json"
    try:
        integration = json.loads(integration_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        errors.append("cannot load integration manifest: {}".format(exc))
        integration = {"entries": []}
    readmes = (root / "README.md").read_text(encoding="utf-8") + (root / "README.en.md").read_text(encoding="utf-8")
    entries = integration.get("entries", [])
    if not entries or entries[0].get("top_module") != "mrtc_top":
        errors.append("mrtc_top is not the first canonical integration entry")
    direct_entries = [entry for entry in entries if entry.get("id") == "bounded_direct_axis_dual_engine"]
    if len(direct_entries) != 1:
        errors.append("expected exactly one bounded Direct integration entry")
    elif direct_entries[0].get("top_module") != "mrtc_rdtc_bounded_axis_multiengine_wrapper":
        errors.append("bounded Direct integration top mismatch")
    for entry in entries:
        for field in ("id", "top_module", "top_path", "filelist", "smoke_command", "pass_marker"):
            if not entry.get(field):
                errors.append("integration entry missing {}: {}".format(field, entry.get("id", "<unknown>")))
        for field in ("top_path", "filelist"):
            if entry.get(field) and not (root / entry[field]).is_file():
                errors.append("integration entry references missing {}".format(entry[field]))
        if entry.get("top_module") and entry["top_module"] not in readmes:
            errors.append("integration top is absent from bilingual README: {}".format(entry["top_module"]))
    return errors


def main():
    root = Path(__file__).resolve().parents[2]
    errors = check(root)
    if errors:
        print("documentation check: FAIL", file=sys.stderr)
        for error in errors:
            print("  " + error, file=sys.stderr)
        return 2
    print("documentation check: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
