#!/usr/bin/env python3

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_public_docs.py")
SPEC = importlib.util.spec_from_file_location("check_public_docs", SCRIPT)
DOCS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCS)
REPO = SCRIPT.parents[2]


def write_text_lf(path, text):
    with path.open("w", encoding="utf-8", newline="") as stream:
        stream.write(text)


class Stage1DocumentBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        package = self.root / "evidence/rdtc_v1_power_architecture_ab"
        package.mkdir(parents=True)
        shutil.copy2(
            REPO / "evidence/rdtc_v1_power_architecture_ab/comparisons.csv",
            package / "comparisons.csv",
        )
        for relative in (
            "docs/en/asic_power_experiment.md",
            "docs/zh-CN/asic_power_experiment.md",
        ):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / relative, target)

    def tearDown(self):
        self.temp.cleanup()

    def test_canonical_stage1_documents_are_bound(self):
        self.assertEqual([], DOCS.validate_stage1_document_values(self.root))

    def test_stage1_endpoint_drift_is_rejected(self):
        path = self.root / "docs/en/asic_power_experiment.md"
        text = path.read_text(encoding="utf-8").replace("436.4352 mW", "999.0000 mW", 1)
        write_text_lf(path, text)
        errors = DOCS.validate_stage1_document_values(self.root)
        self.assertTrue(any("architecture-315mhz:bursty:dynamic_mw" in error for error in errors))

    def test_stage1_endpoint_columns_cannot_be_swapped(self):
        path = self.root / "docs/en/asic_power_experiment.md"
        text = path.read_text(encoding="utf-8")
        text = text.replace(
            "| BURST_IDLE dynamic power | 436.4352 mW | 109.8717 mW | -74.83% |",
            "| BURST_IDLE dynamic power | 109.8717 mW | 436.4352 mW | -74.83% |",
        )
        write_text_lf(path, text)
        errors = DOCS.validate_stage1_document_values(self.root)
        self.assertTrue(any("architecture-315mhz:bursty:dynamic_mw" in error for error in errors))

    def test_stage1_coverage_boundary_is_required(self):
        path = self.root / "docs/en/asic_power_experiment.md"
        text = path.read_text(encoding="utf-8").replace(
            "Activity Annotation Coverage is not verification test coverage",
            "Coverage",
        )
        write_text_lf(path, text)
        errors = DOCS.validate_stage1_document_values(self.root)
        self.assertTrue(any("verification coverage" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
