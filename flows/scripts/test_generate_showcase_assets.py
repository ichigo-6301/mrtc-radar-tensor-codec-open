import csv
from decimal import Decimal
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET


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


if __name__ == "__main__":
    unittest.main()
