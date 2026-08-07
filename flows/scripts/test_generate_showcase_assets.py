import csv
from decimal import Decimal
import importlib.util
from pathlib import Path
import re
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

import yaml


SCRIPT = Path(__file__).with_name("generate_showcase_assets.py")
ROOT = SCRIPT.parents[2]
SPEC = importlib.util.spec_from_file_location("generate_showcase_assets", SCRIPT)
ASSETS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASSETS)


class DirectTimingAssetTests(unittest.TestCase):
    def setUp(self):
        data = ROOT / "evidence" / "data"
        self.nominal = data / "rdtc_v1_direct_stream_timing_nominal.csv"
        self.backpressure = data / "rdtc_v1_direct_stream_timing_backpressure.csv"
        self.trace = ASSETS.load_direct_timing_data(self.nominal, self.backpressure)

    def test_trace_extracts_the_fixed_engine_zero_slice(self):
        self.assertEqual(self.trace["e0_input"], list(range(6, 262)))
        self.assertEqual(self.trace["e1_input"], list(range(262, 518)))
        self.assertEqual(self.trace["prefix_cycle"], 47)
        self.assertEqual(self.trace["selected_k_cycle"], 48)
        self.assertEqual(self.trace["requests"], list(range(56, 312)))
        self.assertEqual(self.trace["responses"], list(range(58, 314)))
        self.assertEqual(len(self.trace["e0_output"]), 20)
        self.assertEqual(self.trace["e0_output"][-1]["cycle"], 326)
        self.assertEqual(self.trace["stalls"], [51, 52, 86, 87])

    def test_generated_svg_is_deterministic_and_semantically_guarded(self):
        stream = ASSETS.direct_stream_timing_svg(self.trace)
        packet = ASSETS.direct_multiengine_packet_timing_svg(self.trace)
        self.assertEqual(stream, ASSETS.direct_stream_timing_svg(self.trace))
        self.assertEqual(packet, ASSETS.direct_multiengine_packet_timing_svg(self.trace))
        for name, content in (
            ("rdtc_stream_timing.svg", stream),
            ("rdtc_multiengine_packet_timing.svg", packet),
        ):
            ASSETS.validate_xml(name, content)
            ASSETS.validate_generated_asset_semantics(name, content)
        self.assertIn(self.trace["nominal_sha256"][:32], stream)
        self.assertIn(self.trace["nominal_sha256"][32:], stream)
        self.assertIn(self.trace["backpressure_sha256"][:32], stream)
        self.assertIn(self.trace["backpressure_sha256"][32:], stream)
        self.assertIn("B0 -&gt; E0", packet)
        self.assertIn("B1 -&gt; E1", packet)
        for content in (stream, packet):
            font_sizes = [int(value) for value in re.findall(r"font:[^;{}]*?(\d+)px", content)]
            self.assertTrue(font_sizes)
            self.assertGreaterEqual(min(font_sizes), 28)

        root = ET.fromstring(stream)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        headers = root.findall(".//svg:rect[@class='header']", namespace)
        payload = root.findall(".//svg:rect[@class='payload']", namespace)
        self.assertEqual(len(headers), 4)
        self.assertTrue(payload)
        header_end = max(float(item.attrib["x"]) + float(item.attrib["width"]) for item in headers)
        payload_start = min(float(item.attrib["x"]) for item in payload)
        self.assertLessEqual(header_end, payload_start)

        self.assertIn('height="1020" viewBox="0 0 1000 1020"', stream)
        self.assertIn('x="950" y="468" class="tiny" text-anchor="end"', stream)
        self.assertIn('<rect x="244" y="608" width="602"', stream)
        self.assertIn('<text x="58" y="928" class="tiny">backpressure CSV SHA256</text>', stream)
        self.assertRegex(stream, r'<text x="[0-9.]+" y="132" class="tiny" text-anchor="middle">c38</text>')
        self.assertRegex(stream, r'<text x="[0-9.]+" y="132" class="tiny" text-anchor="middle">c56</text>')
        self.assertGreaterEqual(float(re.search(r'<rect x="([0-9.]+)" y="145"', packet).group(1)), 250.0)
        self.assertIn('y="215" width=', packet)
        self.assertIn('y="269" text-anchor="middle" class="tiny">accepted beats + bubbles</text>', packet)

    def test_rejects_a_trace_with_noncontiguous_cycles(self):
        with tempfile.TemporaryDirectory() as directory:
            broken = Path(directory) / "nominal.csv"
            with self.nominal.open("r", encoding="utf-8", newline="") as source:
                rows = list(csv.DictReader(source))
            rows[1]["cycle"] = "9"
            with broken.open("w", encoding="utf-8", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=rows[0].keys(), lineterminator="\n")
                writer.writeheader()
                writer.writerows(rows)
            with self.assertRaisesRegex(ValueError, "not contiguous"):
                ASSETS.load_direct_timing_data(broken, self.backpressure)


class ClockGatingPowerAssetTests(unittest.TestCase):
    def setUp(self):
        self.points = ROOT / "evidence" / "rdtc_v1_clock_gating_mapped_dc" / "points.csv"
        self.data = ASSETS.load_clock_gating_power_data(self.points)

    def test_loads_exact_six_point_dynamic_power_pairs(self):
        self.assertEqual(tuple(self.data), ("IDLE", "BURST_IDLE", "ACTIVE_LEGAL"))
        self.assertEqual(self.data["IDLE"], {"G0": Decimal("66.9676"), "G1": Decimal("27.7229")})
        self.assertEqual(
            self.data["BURST_IDLE"],
            {"G0": Decimal("107.3535"), "G1": Decimal("41.1522")},
        )
        self.assertEqual(
            self.data["ACTIVE_LEGAL"],
            {"G0": Decimal("107.2775"), "G1": Decimal("43.4293")},
        )

    def test_generated_svg_is_deterministic_scalable_and_stage_two_only(self):
        content = ASSETS.clock_gating_power_svg(self.data)
        self.assertEqual(content, ASSETS.clock_gating_power_svg(self.data))
        ASSETS.validate_xml("clock_gating_power_ab.svg", content)
        ASSETS.validate_generated_asset_semantics("clock_gating_power_ab.svg", content)
        self.assertIn('width="1000" height="650" viewBox="0 0 1000 650"', content)
        self.assertIn('preserveAspectRatio="xMidYMid meet"', content)
        self.assertNotIn("Stage 1 + Stage 2", content)

        root = ET.fromstring(content)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        self.assertEqual(len(root.findall(".//svg:rect[@class='g0-bar']", namespace)), 3)
        self.assertEqual(len(root.findall(".//svg:rect[@class='g1-bar']", namespace)), 3)
        texts = ["".join(node.itertext()) for node in root.findall(".//svg:text", namespace)]
        for expected in ("66.9676", "27.7229", "107.3535", "41.1522", "107.2775", "43.4293"):
            self.assertIn(expected, texts)

    def test_rejects_duplicate_or_reordered_points(self):
        with tempfile.TemporaryDirectory() as directory:
            broken = Path(directory) / "points.csv"
            with self.points.open("r", encoding="utf-8", newline="") as source:
                rows = list(csv.DictReader(source))
            rows[1]["point_id"] = rows[0]["point_id"]
            with broken.open("w", encoding="utf-8", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=rows[0].keys(), lineterminator="\n")
                writer.writeheader()
                writer.writerows(rows)
            with self.assertRaisesRegex(ValueError, "canonical six-point order"):
                ASSETS.load_clock_gating_power_data(broken)


class CoordinatedReportAssetTests(unittest.TestCase):
    def setUp(self):
        self.performance = ASSETS.load_performance_report_data(ROOT)
        self.stage1 = ASSETS.load_architecture_power_report_data(ROOT)
        self.stage2 = ASSETS.load_clock_gating_report_data(ROOT)

    def test_loaders_bind_exact_public_evidence(self):
        self.assertEqual(
            Decimal(self.performance["bitpacker"]["baseline"]["steady_state_cycles_per_block"]),
            Decimal("8220"),
        )
        self.assertEqual(
            Decimal(self.performance["scaling"][4]["effective_cycles_per_block"]),
            Decimal("197.41"),
        )
        self.assertEqual(self.stage1["total_mw"]["baseline"], Decimal("462.7"))
        self.assertEqual(
            self.stage1["total_mw"]["percent"],
            Decimal("-74.599092284417549167927382753403933434190620272314674735249621785173978819969743"),
        )
        self.assertEqual(self.stage2["clock"][("G1", "icg_count")], Decimal("272"))
        self.assertEqual(self.stage2["clock"][("G1", "ring_coverage_pct")], Decimal("100"))

    def test_coordinated_assets_are_deterministic_and_pure_svg(self):
        generated = {
            "rdtc_performance_evolution.svg": ASSETS.performance_evolution_svg(self.performance),
            "rdtc_stage1_architecture_ppa_power.svg": ASSETS.stage1_architecture_power_svg(self.stage1),
            "rdtc_stage2_clock_gating_power.svg": ASSETS.stage2_clock_gating_power_svg(self.stage2),
        }
        for name, content in generated.items():
            self.assertEqual(
                content,
                {
                    "rdtc_performance_evolution.svg": ASSETS.performance_evolution_svg(self.performance),
                    "rdtc_stage1_architecture_ppa_power.svg": ASSETS.stage1_architecture_power_svg(self.stage1),
                    "rdtc_stage2_clock_gating_power.svg": ASSETS.stage2_clock_gating_power_svg(self.stage2),
                }[name],
            )
            ASSETS.validate_xml(name, content)
            ASSETS.validate_generated_asset_semantics(name, content)
            self.assertIn('width="1600" height="1000" viewBox="0 0 1600 1000"', content)
            self.assertNotIn("<image", content)
            self.assertNotIn("data:image", content)
            self.assertNotIn("@font-face", content)
            self.assertNotIn("linearGradient", content)

        self.assertIn("10.47&#215;", generated["rdtc_performance_evolution.svg"])
        self.assertIn("98.74%", generated["rdtc_performance_evolution.svg"])
        self.assertIn("-74.60%", generated["rdtc_stage1_architecture_ppa_power.svg"])
        self.assertIn("-61.67%", generated["rdtc_stage2_clock_gating_power.svg"])

    def test_performance_plot_uses_one_evidence_derived_point_set(self):
        content = ASSETS.performance_evolution_svg(self.performance)
        root = ET.fromstring(content)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        actual_polyline = root.find(".//svg:polyline[@id='actual-throughput-polyline']", namespace)
        ideal_polyline = root.find(".//svg:polyline[@id='ideal-throughput-polyline']", namespace)
        self.assertIsNotNone(actual_polyline)
        self.assertIsNotNone(ideal_polyline)

        actual_coordinates = [tuple(map(int, point.split(","))) for point in actual_polyline.attrib["points"].split()]
        ideal_coordinates = [tuple(map(int, point.split(","))) for point in ideal_polyline.attrib["points"].split()]
        circles = root.findall(".//svg:g[@id='actual-throughput-points']/svg:circle", namespace)
        circle_coordinates = [(int(circle.attrib["cx"]), int(circle.attrib["cy"])) for circle in circles]
        self.assertEqual(actual_coordinates, circle_coordinates)
        self.assertEqual([circle.attrib["data-engine"] for circle in circles], ["1", "2", "4"])

        for index in (1, 2):
            self.assertGreater(actual_coordinates[index][1], ideal_coordinates[index][1])
        labels = root.findall(".//svg:g[@id='actual-throughput-labels']/svg:text", namespace)
        self.assertEqual(len(labels), 3)
        for label in labels:
            self.assertGreaterEqual(int(label.attrib["y"]), 250)
            self.assertLess(int(label.attrib["y"]), 600)

        expected = ASSETS.performance_scaling_points(
            self.performance["scaling"],
            Decimal(self.performance["bitpacker"]["optimized"]["steady_state_cycles_per_block"]),
        )
        self.assertEqual(
            [circle.attrib["data-normalized-throughput"] for circle in circles],
            [ASSETS.compact_decimal(point["actual"]) for point in expected],
        )
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotRegex(source, r'<circle\s+cx="(?:885|1120|1420)"')

    def test_stage1_diagram_shows_codec_and_profile_specific_storage(self):
        content = ASSETS.stage1_architecture_power_svg(self.stage1)
        root = ET.fromstring(content)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        buffered = root.find(".//svg:g[@id='stage1-buffered-architecture']", namespace)
        direct = root.find(".//svg:g[@id='stage1-direct-architecture']", namespace)
        self.assertIsNotNone(buffered)
        self.assertIsNotNone(direct)
        buffered_text = " ".join(" ".join(buffered.itertext()).split())
        direct_text = " ".join(" ".join(direct.itertext()).split())
        self.assertEqual(buffered_text.count("Codec Engine"), 1)
        self.assertEqual(direct_text.count("Codec Engine"), 1)
        self.assertIn("DDR Feeder", buffered_text)
        self.assertNotIn("DDR Feeder", direct_text)
        self.assertIn("Per-Engine Payload-Commit Storage", buffered_text)
        self.assertNotIn("Per-Engine Payload-Commit Storage", direct_text)
        self.assertIn("Four-Way Shallow Ring", direct_text)
        self.assertIn("Shared Output FIFO", direct_text)

    def test_performance_loader_rejects_yaml_hash_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "evidence" / "data").mkdir(parents=True)
            for relative in (
                "evidence/rdtc_v1_bitpacker_pipeline_ab.yaml",
                "evidence/rdtc_v1_multiengine_rtl.yaml",
                "evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv",
                "evidence/data/rdtc_v1_multiengine_scaling.csv",
            ):
                source = ROOT / relative
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
            path = root / "evidence" / "rdtc_v1_bitpacker_pipeline_ab.yaml"
            document = yaml.safe_load(path.read_text(encoding="utf-8"))
            document["curated_data_sha256"] = "0" * 64
            path.write_text(yaml.safe_dump(document, sort_keys=False), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "curated-data hash mismatch"):
                ASSETS.load_performance_report_data(root)

    def test_stage1_loader_rejects_comparison_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "evidence" / "rdtc_v1_power_architecture_ab"
            shutil.copytree(ROOT / "evidence" / "rdtc_v1_power_architecture_ab", package)
            path = package / "comparisons.csv"
            with path.open("r", encoding="utf-8", newline="") as stream:
                rows = list(csv.DictReader(stream))
            for row in rows:
                if row["comparison_id"] == "architecture-315mhz:bursty:total_mw":
                    row["candidate"] = "118.53"
            with path.open("w", encoding="utf-8", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=rows[0].keys(), lineterminator="\n")
                writer.writeheader()
                writer.writerows(rows)
            with self.assertRaisesRegex(ValueError, "percentage mismatch"):
                ASSETS.load_architecture_power_report_data(root)

    def test_stage2_loader_rejects_wrong_activity_method(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "evidence" / "rdtc_v1_clock_gating_mapped_dc"
            shutil.copytree(ROOT / "evidence" / "rdtc_v1_clock_gating_mapped_dc", package)
            path = package / "points.csv"
            with path.open("r", encoding="utf-8", newline="") as stream:
                rows = list(csv.DictReader(stream))
            rows[0]["activity_method"] = "rtl_saif_mapped"
            with path.open("w", encoding="utf-8", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=rows[0].keys(), lineterminator="\n")
                writer.writeheader()
                writer.writerows(rows)
            with self.assertRaisesRegex(ValueError, "activity contract mismatch"):
                ASSETS.load_clock_gating_report_data(root)

    def test_semantic_checks_reject_embedded_raster_and_positive_overclaim(self):
        content = ASSETS.stage2_clock_gating_power_svg(self.stage2)
        raster = content.replace("</svg>", '<image href="data:image/png;base64,AA=="/></svg>')
        with self.assertRaisesRegex(ValueError, "raster image"):
            ASSETS.validate_xml("rdtc_stage2_clock_gating_power.svg", raster)
        overclaim = content.replace("not maximum throughput", "is maximum throughput")
        with self.assertRaisesRegex(ValueError, "maximum throughput"):
            ASSETS.validate_generated_asset_semantics("rdtc_stage2_clock_gating_power.svg", overclaim)

    def test_overview_uses_coordinated_report_style(self):
        path = ROOT / "docs" / "assets" / "rdtc_overview.svg"
        content = path.read_text(encoding="utf-8")
        ASSETS.validate_xml(path.name, content)
        ASSETS.validate_authored_asset_semantics(path.name, content)
        self.assertIn('width="1600" height="1000" viewBox="0 0 1600 1000"', content)
        self.assertIn("#102f5e", content)
        self.assertIn("#1456a0", content)
        self.assertNotIn(" rx=", content)
        self.assertNotIn("linearGradient", content)
        self.assertNotIn("<image", content)
        for required in (
            "N independent Engines",
            "Explicit mode and selected k",
            "Length from header or TLAST/TUSER",
            "FFT backend boundary",
        ):
            self.assertIn(required, content)
        for obsolete in (
            "N x independent Engine",
            "Explicit mode, payload length, and selected k",
            "ADC / FFT pipeline boundary",
        ):
            self.assertNotIn(obsolete, content)


if __name__ == "__main__":
    unittest.main()
