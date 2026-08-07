#!/usr/bin/env python3
"""Check public Markdown links and required bilingual release documentation."""

from __future__ import print_function

import json
import re
import subprocess
import sys
from decimal import Decimal
from pathlib import Path
from urllib.parse import unquote

import yaml


LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

PRIMARY_SHOWCASE_DOCS = (
    "README.md",
    "README.en.md",
    "docs/zh-CN/results.md",
    "docs/en/results.md",
    "docs/zh-CN/asic_implementation.md",
    "docs/en/asic_implementation.md",
    "docs/zh-CN/asic_clock_gating_experiment.md",
    "docs/en/asic_clock_gating_experiment.md",
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
        "make power-architecture-ab-validate",
        "make rdtc-clock-gating-power-validate",
        "make rdtc-two-stage-power-validate",
        "436.4352 -> 109.8717 mW",
        "107.3535 -> 41.1522 mW",
        "不会重新执行 ModelSim、Design Compiler、P&R 或 PrimeTime",
        "性能、PPA 与低功耗演进",
        "docs/assets/rdtc_performance_evolution.svg",
        "docs/assets/rdtc_stage1_architecture_ppa_power.svg",
        "docs/assets/rdtc_stage2_clock_gating_power.svg",
        'width="1000"',
        "Activity Annotation Coverage 不是验证 test coverage",
        "不用于跨 FPGA、register-expanded ASIC 与 SRAM-macro ASIC 排名",
        "PrimeTime-PX",
        "Formality",
        "DFT/scan",
        "workload-universal saving",
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
        "make power-architecture-ab-validate",
        "make rdtc-clock-gating-power-validate",
        "make rdtc-two-stage-power-validate",
        "436.4352 -> 109.8717 mW",
        "107.3535 -> 41.1522 mW",
        "do not rerun ModelSim, Design Compiler, P&R, or PrimeTime",
        "Performance, PPA and Power Evolution",
        "docs/assets/rdtc_performance_evolution.svg",
        "docs/assets/rdtc_stage1_architecture_ppa_power.svg",
        "docs/assets/rdtc_stage2_clock_gating_power.svg",
        'width="1000"',
        "Activity Annotation Coverage is not verification test coverage",
        "do not rank FPGA, register-expanded ASIC, and SRAM-macro ASIC profiles",
        "PrimeTime-PX",
        "Formality",
        "DFT/scan",
        "workload-universal savings",
        "PUBLIC_SCOPE.md",
        "provenance/claims.yaml",
        "provenance/evidence.yaml",
        "provenance/nonclaims.yaml",
    ),
}

OVERVIEW_SECTIONS = {
    "README.md": ("## 60 秒总览", "## 性能、PPA 与低功耗演进"),
    "README.en.md": ("## 60-Second Overview", "## Performance, PPA and Power Evolution"),
}

COORDINATED_FIGURES = (
    "docs/assets/rdtc_performance_evolution.svg",
    "docs/assets/rdtc_stage1_architecture_ppa_power.svg",
    "docs/assets/rdtc_stage2_clock_gating_power.svg",
)

CLOSURE_MATRIX_MARKERS = {
    "README.md": (
        "### FPGA / ASIC 实现闭环",
        "| Direct FPGA OOC | 200 MHz；setup/hold WNS `+0.001/+0.062 ns`；`32,672 LUT / 18,519 FF / 0 BRAM`",
        "| Direct register-expanded ASIC | 600 MHz；0 memory macro；standard-cell area `476,320 um2`；PT setup/hold WNS `+0.03/+0.02 ns`",
        "| Direct 8-macro OpenRAM ASIC | 300 MHz；8 个 `32x128 1RW` 宏；PT setup/hold WNS `+0.16/+0.02 ns`",
        "[FPGA 200 MHz evidence](evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml)",
        "[Register-expanded ASIC 600 MHz evidence](evidence/rdtc_v1_bounded_direct_asic.yaml)",
        "[8-macro OpenRAM ASIC 300 MHz evidence](evidence/rdtc_v1_bounded_direct_asic.yaml)",
    ),
    "README.en.md": (
        "### FPGA / ASIC Implementation Closure",
        "| Direct FPGA OOC | 200 MHz; setup/hold WNS `+0.001/+0.062 ns`; `32,672 LUT / 18,519 FF / 0 BRAM`",
        "| Direct register-expanded ASIC | 600 MHz; 0 memory macros; standard-cell area `476,320 um2`; PT setup/hold WNS `+0.03/+0.02 ns`",
        "| Direct eight-macro OpenRAM ASIC | 300 MHz; 8 x `32x128 1RW` macros; PT setup/hold WNS `+0.16/+0.02 ns`",
        "[FPGA 200 MHz evidence](evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml)",
        "[Register-expanded ASIC 600 MHz evidence](evidence/rdtc_v1_bounded_direct_asic.yaml)",
        "[Eight-macro OpenRAM ASIC 300 MHz evidence](evidence/rdtc_v1_bounded_direct_asic.yaml)",
    ),
}

PRESENTATION_DOC_MARKERS = {
    "docs/zh-CN/results.md": (
        "[性能演进](#performance-evolution) · [实现闭合](#implementation-closure) · [Stage 1 架构功耗](asic_power_experiment.md) · [Stage 2 时钟门控](asic_clock_gating_experiment.md)",
        '<a id="performance-evolution"></a>',
        '<a id="implementation-closure"></a>',
        "RTL-SAIF-to-mapped",
        "mapped zero-delay GLS activity",
    ),
    "docs/en/results.md": (
        "[Performance evolution](#performance-evolution) · [Implementation closure](#implementation-closure) · [Stage 1 architecture power](asic_power_experiment.md) · [Stage 2 clock gating](asic_clock_gating_experiment.md)",
        '<a id="performance-evolution"></a>',
        '<a id="implementation-closure"></a>',
        "RTL-SAIF-to-mapped",
        "mapped zero-delay GLS activity",
    ),
    "docs/zh-CN/asic_power_experiment.md": (
        "../assets/rdtc_stage1_architecture_ppa_power.svg",
        'width="1000"',
        "RTL SAIF 映射到 mapped design",
    ),
    "docs/en/asic_power_experiment.md": (
        "../assets/rdtc_stage1_architecture_ppa_power.svg",
        'width="1000"',
        "RTL SAIF applied to mapped design",
    ),
    "docs/zh-CN/asic_clock_gating_experiment.md": (
        "../assets/rdtc_stage2_clock_gating_power.svg",
        'width="1000"',
        "mapped_zero_delay",
        "Activity Annotation Coverage 不是验证 test coverage",
    ),
    "docs/en/asic_clock_gating_experiment.md": (
        "../assets/rdtc_stage2_clock_gating_power.svg",
        'width="1000"',
        "mapped_zero_delay",
        "Activity Annotation Coverage is not verification test coverage",
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
        "evidence/rdtc_v1_power_architecture_ab/README.md",
        "evidence/rdtc_v1_clock_gating_mapped_dc/README.md",
        "docs/zh-CN/asic_power_experiment.md",
        "docs/zh-CN/asic_clock_gating_experiment.md",
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
        "evidence/rdtc_v1_power_architecture_ab/README.md",
        "evidence/rdtc_v1_clock_gating_mapped_dc/README.md",
        "docs/en/asic_power_experiment.md",
        "docs/en/asic_clock_gating_experiment.md",
        "docs/en/results.md",
        "evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml",
    ),
}

POWER_DOC_MARKERS = {
    "docs/en/asic_power_experiment.md": (
        "ARCH_POWER_POSITIVE",
        "436.4352 mW",
        "109.8717 mW",
        "74.819%",
        "clock_mw = 0",
        "../../evidence/rdtc_v1_power_architecture_ab/README.md",
    ),
    "docs/zh-CN/asic_power_experiment.md": (
        "ARCH_POWER_POSITIVE",
        "436.4352 mW",
        "109.8717 mW",
        "74.819%",
        "clock_mw = 0",
        "../../evidence/rdtc_v1_power_architecture_ab/README.md",
    ),
}

CLOCK_GATING_POWER_DOC_MARKERS = {
    "docs/en/asic_clock_gating_experiment.md": (
        "MRTC_CLOCK_GATING_MAPPED_POSITIVE_PRIVATE",
        "Direct G0",
        "Direct G1",
        "272 `CLKGATETST_X1`",
        "34,816",
        "50,988",
        "55,929",
        "61.67%",
        "58.46%",
        "59.52%",
        "15.58%",
        "Activity Annotation Coverage is not verification test coverage",
        "gate-level regression equivalence evidence",
        "8,136",
        "MAPPED_SDC_VECTOR_REPLAY_ERRORS_DDC_CONSTRAINTS_PRESERVED",
        "FULL_RELEASED",
        "../../evidence/rdtc_v1_clock_gating_mapped_dc/README.md",
    ),
    "docs/zh-CN/asic_clock_gating_experiment.md": (
        "MRTC_CLOCK_GATING_MAPPED_POSITIVE_PRIVATE",
        "Direct G0",
        "Direct G1",
        "272 个",
        "34,816",
        "50,988",
        "55,929",
        "61.67%",
        "58.46%",
        "59.52%",
        "15.58%",
        "Activity Annotation Coverage 不是验证 test coverage",
        "gate-level regression equivalence evidence",
        "8,136",
        "MAPPED_SDC_VECTOR_REPLAY_ERRORS_DDC_CONSTRAINTS_PRESERVED",
        "FULL_RELEASED",
        "../../evidence/rdtc_v1_clock_gating_mapped_dc/README.md",
    ),
    "docs/en/results.md": (
        "Two-Stage Mapped Power Study",
        "Buffered -> Direct-AXIS",
        "Direct G0 -> Direct G1",
        "percentages are not added",
    ),
    "docs/zh-CN/results.md": (
        "两阶段 mapped 功耗研究",
        "Buffered -> Direct-AXIS",
        "Direct G0 -> Direct G1",
        "百分比不得相加",
    ),
    "docs/en/asic_implementation.md": (
        "Direct Automatic Clock Gating (Mapped DC)",
        "+0.093015/+0.0151572 ns",
        "+1.4645/+0.18546 ns",
    ),
    "docs/zh-CN/asic_implementation.md": (
        "Direct 自动时钟门控（Mapped DC）",
        "+0.093015/+0.0151572 ns",
        "+1.4645/+0.18546 ns",
    ),
    "provenance/claims.yaml": (
        "rdtc_v1_direct_clock_gating_dc315_burst_dynamic_power_reduction",
        "rdtc_v1_direct_clock_gating_dc315_burst_energy_per_block_reduction",
        "rdtc_v1_direct_clock_gating_dc315_active_dynamic_power_reduction",
    ),
    "provenance/evidence.yaml": ("rdtc_v1_clock_gating_mapped_dc_public",),
    "provenance/nonclaims.yaml": (
        "rdtc_v1_clock_gating_mapped_no_physical_power",
        "rdtc_v1_clock_gating_no_formal_or_dft_closure",
        "rdtc_v1_clock_gating_no_portable_mapped_sdc_replay",
        "rdtc_v1_clock_gating_activity_annotation_not_test_coverage",
        "rdtc_v1_two_stage_power_no_arithmetic_accumulation",
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

RICE_DATAPATH_MARKERS = {
    "README.md": (
        "one AXIS128 beat -> one variable-length fragment",
        "8 x signed 16-bit components",
        "cost for k=0..15",
        "selected k*",
        "q = m >> k*",
        "Rice = 1^q | 0 | rem",
        "word_bits = sum(q+1+k*) <= 128",
        "bit reservoir -> AXIS128 payload",
        "MRTC_ERR_BOUNDED_RICE_WORD",
    ),
    "README.en.md": (
        "one AXIS128 beat -> one variable-length fragment",
        "8 x signed 16-bit components",
        "cost for k=0..15",
        "selected k*",
        "q = m >> k*",
        "Rice = 1^q | 0 | rem",
        "word_bits = sum(q+1+k*) <= 128",
        "bit reservoir -> AXIS128 payload",
        "MRTC_ERR_BOUNDED_RICE_WORD",
    ),
    "docs/zh-CN/architecture.md": (
        '<a id="beat-to-rice-fragment"></a>',
        "P1R",
        "P2S",
        "P3A/P3P/P3B",
        "balanced OR",
        "width packer bit reservoir",
    ),
    "docs/en/architecture.md": (
        '<a id="beat-to-rice-fragment"></a>',
        "P1R",
        "P2S",
        "P3A/P3P/P3B",
        "balanced OR",
        "width packer bit reservoir",
    ),
    "docs/zh-CN/algorithm.md": (
        "residual r = -3",
        "mapped",
        "1001",
        "4 bits",
    ),
    "docs/en/algorithm.md": (
        "residual r = -3",
        "mapped",
        "1001",
        "4 bits",
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


def section_text(text, start_marker, end_marker):
    start = text.find(start_marker)
    if start < 0:
        return ""
    end = text.find(end_marker, start + len(start_marker))
    if end < 0:
        return ""
    return text[start:end]


def table_data_rows(text, header_prefix):
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.startswith(header_prefix):
            table = []
            for candidate in lines[index:]:
                if not candidate.startswith("|"):
                    break
                table.append(candidate)
            return max(0, len(table) - 2)
    return -1


def nested_value(document, path):
    value = document
    for key in path:
        value = value[key]
    return value


def validate_closure_evidence(root):
    errors = []
    paths = {
        "fpga": root / "evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml",
        "asic": root / "evidence/rdtc_v1_bounded_direct_asic.yaml",
    }
    documents = {}
    for name, path in paths.items():
        try:
            documents[name] = yaml.safe_load(path.read_text(encoding="utf-8"))
        except (OSError, ValueError, yaml.YAMLError) as exc:
            errors.append("cannot load {} closure evidence: {}".format(name, exc))
    if len(documents) != len(paths):
        return errors

    expected = (
        ("fpga", ("clock", "frequency_mhz"), Decimal("200")),
        ("fpga", ("timing", "setup_wns_ns"), Decimal("0.001")),
        ("fpga", ("timing", "hold_wns_ns"), Decimal("0.062")),
        ("fpga", ("structure", "slice_lut"), Decimal("32672")),
        ("fpga", ("structure", "slice_registers"), Decimal("18519")),
        ("fpga", ("structure", "ramb18"), Decimal("0")),
        ("fpga", ("structure", "ramb36"), Decimal("0")),
        ("asic", ("register_expanded_600mhz", "physical_target_mhz"), Decimal("600")),
        ("asic", ("register_expanded_600mhz", "memory_macro_count"), Decimal("0")),
        ("asic", ("register_expanded_600mhz", "final_standard_cell_area_um2"), Decimal("476320")),
        ("asic", ("register_expanded_600mhz", "setup_wns_ns"), Decimal("0.03")),
        ("asic", ("register_expanded_600mhz", "hold_wns_ns"), Decimal("0.02")),
        ("asic", ("sram_macro_300mhz", "physical_target_mhz"), Decimal("300")),
        ("asic", ("sram_macro_300mhz", "memory_macro_count"), Decimal("8")),
        ("asic", ("sram_macro_300mhz", "setup_wns_ns"), Decimal("0.16")),
        ("asic", ("sram_macro_300mhz", "hold_wns_ns"), Decimal("0.02")),
    )
    for document_name, path, expected_value in expected:
        try:
            actual = Decimal(str(nested_value(documents[document_name], path)))
        except (KeyError, TypeError, ValueError):
            errors.append("{} closure evidence missing {}".format(document_name, ".".join(path)))
            continue
        if actual != expected_value:
            errors.append(
                "{} closure evidence {} mismatch: {} != {}".format(
                    document_name, ".".join(path), actual, expected_value
                )
            )

    exact_expected = (
        ("fpga", ("result",), "MRTC_BOUNDED_DIRECT_AXIS_ROUTE200_CLOSED"),
        ("asic", ("register_expanded_600mhz", "status"), "verified"),
        (
            "asic",
            ("register_expanded_600mhz", "classification"),
            "MRTC_BOUNDED_DIRECT_REGISTER_PNR600_PT_CLOSED",
        ),
        ("asic", ("sram_macro_300mhz", "status"), "verified"),
        (
            "asic",
            ("sram_macro_300mhz", "classification"),
            "MRTC_BOUNDED_DIRECT_SRAM_PNR300_PT_CLOSED",
        ),
        ("asic", ("sram_macro_300mhz", "macro_organization"), "32x128 1RW, words_per_row=2"),
        ("asic", ("sram_600mhz", "classification"), "MACRO_MODEL_BLOCKED"),
    )
    for document_name, path, expected_value in exact_expected:
        try:
            actual = nested_value(documents[document_name], path)
        except (KeyError, TypeError):
            errors.append("{} closure evidence missing {}".format(document_name, ".".join(path)))
            continue
        if actual != expected_value:
            errors.append(
                "{} closure evidence {} mismatch: {} != {}".format(
                    document_name, ".".join(path), actual, expected_value
                )
            )
    return errors


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
        overview_start, overview_end = OVERVIEW_SECTIONS[name]
        overview = section_text(text, overview_start, overview_end)
        if not overview:
            errors.append("{} missing bounded overview section".format(name))
        overview_rows = table_data_rows(
            overview, "| 贡献 |" if name == "README.md" else "| Contribution |"
        )
        if overview_rows != 5:
            errors.append("{} overview must contain exactly five route-level rows, found {}".format(name, overview_rows))

        evolution = section_text(text, overview_end, '<a id="data-contract"></a>')
        if not evolution:
            errors.append("{} missing coordinated performance/PPA/power section".format(name))
            continue
        last_position = -1
        for figure in COORDINATED_FIGURES:
            marker = 'src="{}" width="1000"'.format(figure)
            position = evolution.find(marker)
            if position < 0:
                errors.append("{} missing full-width coordinated figure {}".format(name, figure))
            elif position <= last_position:
                errors.append("{} coordinated figures are out of order".format(name))
            last_position = max(last_position, position)
        closure_header = "| 固定 closure profile |" if name == "README.md" else "| Fixed closure profile |"
        closure_heading = (
            "### FPGA / ASIC 实现闭环"
            if name == "README.md"
            else "### FPGA / ASIC Implementation Closure"
        )
        if "{}\n\n{}".format(closure_heading, closure_header) not in evolution:
            errors.append("{} closure heading must immediately precede the matrix".format(name))
        closure_rows = table_data_rows(evolution, closure_header)
        if closure_rows != 3:
            errors.append("{} closure matrix must contain exactly three profile rows, found {}".format(name, closure_rows))
        for marker in CLOSURE_MATRIX_MARKERS[name]:
            if marker not in evolution:
                errors.append("{} missing closure-matrix contract {}".format(name, marker))
        if evolution.count("evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml") != 1:
            errors.append("{} closure matrix must link FPGA evidence exactly once".format(name))
        if evolution.count("evidence/rdtc_v1_bounded_direct_asic.yaml") != 2:
            errors.append("{} closure matrix must link ASIC evidence once per ASIC profile".format(name))
    errors.extend(validate_closure_evidence(root))
    for name, markers in PRESENTATION_DOC_MARKERS.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing coordinated-presentation marker {}".format(name, marker))
    cumulative_patterns = (
        re.compile(r"(?im)^(?!.*\b(?:not|never|must not)\b).*\b(?:cumulative|combined)\s+(?:power\s+)?(?:saving|reduction)[^\n]*%"),
        re.compile(r"(?m)^(?!.*(?:不|不得|禁止)).*(?:累计|合并|叠加)(?:节省|降幅|降低|减少)[^\n]*%"),
        re.compile(r"(?i)(?:74\.8[0-9]%|stage\s*1)[^\n]{0,80}\+[^\n]{0,80}(?:61\.6[0-9]%|stage\s*2)"),
    )
    for name in (
        "README.md",
        "README.en.md",
        "docs/zh-CN/results.md",
        "docs/en/results.md",
        "docs/zh-CN/asic_power_experiment.md",
        "docs/en/asic_power_experiment.md",
        "docs/zh-CN/asic_clock_gating_experiment.md",
        "docs/en/asic_clock_gating_experiment.md",
    ):
        text = (root / name).read_text(encoding="utf-8")
        for pattern in cumulative_patterns:
            if pattern.search(text):
                errors.append("{} contains a cumulative Stage-1/Stage-2 percentage claim".format(name))
                break
    for name, markers in DIRECT_DOC_MARKERS.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing bounded Direct boundary {}".format(name, marker))
    for name, markers in POWER_DOC_MARKERS.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing architecture-power marker {}".format(name, marker))
    for name, markers in CLOCK_GATING_POWER_DOC_MARKERS.items():
        path = root / name
        if not path.is_file():
            errors.append("missing clock-gating power document: {}".format(name))
            continue
        text = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing clock-gating power marker {}".format(name, marker))
    for name, markers in DATA_CONTRACT_MARKERS.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing data-contract marker {}".format(name, marker))
    for name, markers in RICE_DATAPATH_MARKERS.items():
        text = (root / name).read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                errors.append("{} missing Rice-datapath marker {}".format(name, marker))
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
