import csv
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


if __name__ == "__main__":
    unittest.main()
