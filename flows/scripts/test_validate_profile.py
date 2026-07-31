#!/usr/bin/env python3
"""Unit tests for profile and claim/evidence schema validation."""

import shutil
import tempfile
import unittest
from pathlib import Path

import yaml

from flows.scripts.validate_profile import (
    parse_config,
    validate_repository,
    validate_selected_config,
)


SOURCE_ROOT = Path(__file__).resolve().parents[2]


class ProfileValidationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        shutil.copytree(SOURCE_ROOT / "flows/profiles", self.root / "flows/profiles")
        (self.root / "provenance").mkdir(parents=True)
        shutil.copy2(SOURCE_ROOT / "provenance/claims.yaml", self.root / "provenance/claims.yaml")
        shutil.copy2(SOURCE_ROOT / "provenance/evidence.yaml", self.root / "provenance/evidence.yaml")
        shutil.copytree(SOURCE_ROOT / "evidence", self.root / "evidence")

    def tearDown(self):
        self.temp.cleanup()

    def load(self, relative):
        return yaml.safe_load((self.root / relative).read_text(encoding="utf-8"))

    def save(self, relative, data):
        (self.root / relative).write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")

    def test_current_repository_schema_passes(self):
        summary = validate_repository(self.root)
        self.assertGreaterEqual(summary["profiles"], 3)

    def test_unknown_maturity_fails(self):
        path = "flows/profiles/rdtc_v1_register_nangate45_550.yaml"
        data = self.load(path)
        data["maturity"] = "mystery"
        self.save(path, data)
        with self.assertRaisesRegex(RuntimeError, "unknown maturity"):
            validate_repository(self.root)

    def test_claim_to_missing_evidence_fails(self):
        data = self.load("provenance/claims.yaml")
        data["claims"][0]["evidence"] = ["missing_evidence"]
        self.save("provenance/claims.yaml", data)
        with self.assertRaisesRegex(RuntimeError, "nonexistent evidence"):
            validate_repository(self.root)

    def test_evidence_to_missing_claim_fails(self):
        data = self.load("provenance/evidence.yaml")
        data["evidence"][0]["claims"].append("missing_claim")
        self.save("provenance/evidence.yaml", data)
        with self.assertRaisesRegex(RuntimeError, "nonexistent claim"):
            validate_repository(self.root)

    def test_verified_claim_with_only_experimental_evidence_fails(self):
        data = self.load("provenance/evidence.yaml")
        data["evidence"][0]["maturity"] = "experimental"
        self.save("provenance/evidence.yaml", data)
        with self.assertRaisesRegex(RuntimeError, "linked only to experimental evidence"):
            validate_repository(self.root)

    def test_physical_claim_without_caveat_fails(self):
        data = self.load("provenance/claims.yaml")
        claim = next(item for item in data["claims"] if item["id"].endswith("pnr550_pt"))
        claim["caveat"] = ""
        self.save("provenance/claims.yaml", data)
        with self.assertRaisesRegex(RuntimeError, "missing a caveat"):
            validate_repository(self.root)

    def test_missing_required_provenance_fields_fail(self):
        claims = self.load("provenance/claims.yaml")
        del claims["claims"][0]["source_ref"]
        self.save("provenance/claims.yaml", claims)
        evidence = self.load("provenance/evidence.yaml")
        del evidence["evidence"][0]["tool"]
        del evidence["evidence"][0]["public"]
        self.save("provenance/evidence.yaml", evidence)
        with self.assertRaisesRegex(RuntimeError, "missing fields"):
            validate_repository(self.root)

    def test_bounded_dc_ab_validator_enforces_complete_contract(self):
        path = SOURCE_ROOT / "configs/rdtc_v1_bounded_ab_direct_dc315_defconfig"
        original = parse_config(path)
        validate_selected_config(SOURCE_ROOT, original, config_path=path)
        mutations = (
            ("CONFIG_FLOW_PRODUCT_PROFILE", "bounded-register-expanded"),
            ("CONFIG_FLOW_SDC_TIME_SCALE", "1000.0"),
            ("CONFIG_FLOW_DC_HANDOFF_BUILD_TAG", "wrong-handoff"),
            ("CONFIG_FLOW_BOUNDED_DIRECT_ASIC_SRAM", "y"),
        )
        for field, value in mutations:
            changed = dict(original)
            changed[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(
                RuntimeError, "bounded DC A/B"
            ):
                validate_selected_config(SOURCE_ROOT, changed, config_path=path)

    def test_bounded_dc_ab_defconfig_identity_rejects_corrupt_build_tag(self):
        configs = self.root / "configs"
        configs.mkdir()
        source = SOURCE_ROOT / "configs/rdtc_v1_bounded_ab_direct_dc315_defconfig"
        target = configs / source.name
        original = source.read_text(encoding="utf-8")
        corrupted = original.replace(
            'CONFIG_FLOW_BUILD_TAG="rdtc_v1_bounded_ab_direct_dc315"',
            'CONFIG_FLOW_BUILD_TAG="rdtc_v1_bounded_ab_direct_typo"',
        )
        self.assertNotEqual(original, corrupted)
        target.write_text(corrupted, encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "match defconfig identity"):
            validate_repository(self.root, all_defconfigs=True)

    def test_bounded_dc_ab_validator_rejects_nonfinite_periods(self):
        path = SOURCE_ROOT / "configs/rdtc_v1_bounded_ab_direct_dc315_defconfig"
        original = parse_config(path)
        for field in (
            "CONFIG_FLOW_CLOCK_PERIOD_NS",
            "CONFIG_FLOW_DC_CLOCK_PERIOD_NS",
            "CONFIG_FLOW_PNR_CLOCK_PERIOD_NS",
            "CONFIG_FLOW_STA_CLOCK_PERIOD_NS",
        ):
            changed = dict(original)
            changed[field] = "nan"
            with self.subTest(field=field), self.assertRaisesRegex(
                RuntimeError, "bounded DC A/B"
            ):
                validate_selected_config(SOURCE_ROOT, changed, config_path=path)


if __name__ == "__main__":
    unittest.main()
