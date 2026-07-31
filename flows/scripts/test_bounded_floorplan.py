#!/usr/bin/env python3

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import bounded_floorplan


class BoundedFloorplanTest(unittest.TestCase):
    def test_register_floorplan_meets_utilization_and_grid(self):
        result = bounded_floorplan.register_floorplan(3_000_000.0)
        self.assertEqual(result["die_side_um"] % 10.0, 0.0)
        self.assertLessEqual(result["initial_core_utilization"], 0.45)
        self.assertLess(0.45, result["place_density"])

    def test_minimum_die_is_preserved_for_small_design(self):
        result = bounded_floorplan.register_floorplan(100_000.0)
        self.assertEqual(result["die_side_um"], 1200.0)

    def test_target_must_leave_placement_headroom(self):
        with self.assertRaisesRegex(RuntimeError, "below place density"):
            bounded_floorplan.register_floorplan(
                100_000.0, target_core_utilization=0.55, place_density=0.55
            )

    def test_contract_is_deterministic_and_hash_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            area = root / "area.rpt"
            area.write_text("Total cell area: 3000000.000000\n", encoding="utf-8")
            first_json = root / "first.json"
            first_env = root / "first.env"
            second_json = root / "second.json"
            second_env = root / "second.env"
            first, first_hash = bounded_floorplan.build_contract(
                area, first_json, first_env
            )
            second, second_hash = bounded_floorplan.build_contract(
                area, second_json, second_env
            )
            self.assertEqual(first, second)
            self.assertEqual(first_hash, second_hash)
            self.assertEqual(first_json.read_bytes(), second_json.read_bytes())
            parsed = json.loads(first_json.read_text(encoding="utf-8"))
            self.assertEqual(parsed["source"]["total_cell_area_um2"], 3000000.0)
            self.assertIn(first_hash, first_env.read_text(encoding="utf-8"))

    def test_duplicate_area_value_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            area = Path(temporary) / "area.rpt"
            area.write_text(
                "Total cell area: 1.0\nTotal cell area: 2.0\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(RuntimeError, "exactly one"):
                bounded_floorplan.parse_total_cell_area(area)


if __name__ == "__main__":
    unittest.main()
