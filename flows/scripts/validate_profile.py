#!/usr/bin/env python3
"""Validate RDTC profile, claim, evidence, and selected-flow consistency."""

from __future__ import print_function

import argparse
import hashlib
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required; install requirements-public.txt")


CLAIM_FIELDS = {
    "id", "profile", "statement", "metric", "value", "unit", "benchmark",
    "configuration", "source_ref", "tool", "evidence", "status", "caveat",
    "public",
}
EVIDENCE_FIELDS = {
    "id", "path", "type", "source_ref", "tool", "claims", "sha256",
    "public", "maturity",
}
PHYSICAL_KEYWORDS = ("pnr", "post-route", "postroute", "primeTime", "physical")
BOUNDED_DC_AB_DB_SHA256 = (
    "c6da1f0e7a7f445c0476d1e6bf6860c9815fe4f50c9ce138264a581af59e4cb5"
)
BOUNDED_DC_AB_POINTS = {
    "rdtc_v1_bounded_ab_buffered_dc315": ("buffered", 3.174603),
    "rdtc_v1_bounded_ab_direct_dc315": ("direct", 3.174603),
    "rdtc_v1_bounded_ab_buffered_dc630": ("buffered", 1.587302),
    "rdtc_v1_bounded_ab_direct_dc630": ("direct", 1.587302),
}


def load_yaml(path):
    if not path.is_file():
        raise RuntimeError("missing YAML file: {}".format(path))
    with path.open("r", encoding="utf-8") as stream:
        data = yaml.safe_load(stream)
    if not isinstance(data, dict):
        raise RuntimeError("YAML root must be a mapping: {}".format(path))
    return data


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_config(path):
    values = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("# CONFIG_") and line.endswith(" is not set"):
            values[line[2:-11]] = "n"
        elif line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip().strip('"')
    return values


def config_value(config, key, default=""):
    return config.get("CONFIG_" + key, default)


def validate_selected_config(root, config, stage=None):
    errors = []
    product = config_value(config, "FLOW_PRODUCT_PROFILE")
    memory = config_value(config, "FLOW_MEMORY_MODE")
    technology = config_value(config, "FLOW_TECHNOLOGY")
    waiver = config_value(config, "FLOW_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER", "n") == "y"
    policy = config_value(config, "FLOW_STA_WAIVER_POLICY")
    backend = config_value(config, "FLOW_PNR_BACKEND", "openroad")
    platform = config_value(config, "FLOW_OPENROAD_PLATFORM")
    build_tag = config_value(config, "FLOW_BUILD_TAG")

    if not product:
        product = "register-expanded" if memory == "registers" else "sram-macro"
    if not memory:
        memory = "registers" if product == "register-expanded" else "macro"

    if product == "sram-macro" and (memory == "registers" or "register" in technology.lower()):
        errors.append("sram-macro cannot use a register-only technology or memory mode")
    if product == "register-expanded" and memory == "macro":
        errors.append("register-expanded cannot select macro memory mode")
    if product == "register-expanded" and waiver:
        errors.append("register-expanded cannot enable an SRAM waiver")
    if waiver and not policy:
        errors.append("an enabled STA waiver requires CONFIG_FLOW_STA_WAIVER_POLICY")
    if policy and not waiver:
        errors.append("an STA waiver policy requires the waiver enable symbol")
    if policy and product != "sram-macro":
        errors.append("a non-SRAM profile cannot load an SRAM waiver policy")
    if policy and not (root / policy).is_file():
        errors.append("STA waiver policy does not exist: {}".format(policy))
    if config_value(config, "FLOW_PNR", "n") == "y" and backend not in ("openroad", "icc2"):
        errors.append("unsupported P&R backend: {}".format(backend))
    if config_value(config, "FLOW_PNR", "n") == "y" and backend == "openroad" and not platform:
        errors.append("OpenROAD requires CONFIG_FLOW_OPENROAD_PLATFORM")
    if stage == "sta" and config_value(config, "FLOW_STA", "n") != "y":
        errors.append("PrimeTime stage is not enabled")
    if stage == "pnr" and config_value(config, "FLOW_PNR", "n") != "y":
        errors.append("P&R stage is not enabled")

    ab_point = BOUNDED_DC_AB_POINTS.get(build_tag)
    if ab_point:
        family, period_ns = ab_point
        buffered = config_value(
            config, "FLOW_BOUNDED_ASIC_REGISTER_EXPANDED", "n"
        ) == "y"
        direct = config_value(
            config, "FLOW_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED", "n"
        ) == "y"
        direct_sram = config_value(
            config, "FLOW_BOUNDED_DIRECT_ASIC_SRAM", "n"
        ) == "y"
        if direct_sram or buffered == direct or (family == "buffered") != buffered:
            errors.append("bounded DC A/B family selection does not match its build tag")
        expected_top = (
            "mrtc_rdtc_ddr_multiengine_wrapper"
            if buffered
            else "mrtc_rdtc_bounded_axis_multiengine_wrapper"
        )
        exact_values = {
            "RDTC_TOP": expected_top,
            "FLOW_PRODUCT_PROFILE": (
                "bounded-register-expanded"
                if buffered
                else "bounded-direct-register-expanded"
            ),
            "FLOW_MEMORY_MODE": "registers",
            "FLOW_TECHNOLOGY": "nangate45_registers",
            "FLOW_SDC_FILE": "flows/constraints/rdtc_v1_bounded_sync_boundary_10pct.sdc",
            "FLOW_SDC_TIME_SCALE": "1.0",
            "FLOW_EXPECTED_STDCELL_DB_SHA256": BOUNDED_DC_AB_DB_SHA256,
            "FLOW_DC_MAX_CORES": "4",
            "FLOW_DC_HANDOFF_BUILD_TAG": build_tag,
            "FLOW_BOUNDED_ASIC_REGISTER_EXPANDED": "y" if buffered else "n",
            "FLOW_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED": "n" if buffered else "y",
            "FLOW_BOUNDED_DIRECT_ASIC_SRAM": "n",
            "FLOW_DC_FORBID_RETIME": "y",
            "FLOW_DC_BASELINE": "y",
            "FLOW_PNR": "n",
            "FLOW_STA": "n",
        }
        for key, expected in exact_values.items():
            if config_value(config, key, "n") != expected:
                errors.append("bounded DC A/B requires CONFIG_{}={}".format(key, expected))
        for key in (
            "FLOW_CLOCK_PERIOD_NS",
            "FLOW_DC_CLOCK_PERIOD_NS",
            "FLOW_PNR_CLOCK_PERIOD_NS",
            "FLOW_STA_CLOCK_PERIOD_NS",
        ):
            try:
                actual = float(config_value(config, key))
            except ValueError:
                errors.append("bounded DC A/B CONFIG_{} is malformed".format(key))
                continue
            if abs(actual - period_ns) > 1.0e-6:
                errors.append(
                    "bounded DC A/B CONFIG_{} must equal {:.6f}".format(
                        key, period_ns
                    )
                )
    if errors:
        raise RuntimeError("invalid flow profile: " + "; ".join(errors))


def validate_repository(root, config_path=None, all_defconfigs=False):
    schema = load_yaml(root / "flows/profiles/schema.yaml")
    allowed_maturity = set(schema.get("allowed_maturity", []))
    required = set(schema.get("required_fields", []))
    errors = []

    profiles = []
    for path in sorted((root / "flows/profiles").glob("*.yaml")):
        if path.name == "schema.yaml":
            continue
        data = load_yaml(path)
        missing = sorted(required - set(data))
        if missing:
            errors.append("{} missing fields: {}".format(path, ", ".join(missing)))
        if data.get("maturity") not in allowed_maturity:
            errors.append("{} has unknown maturity {}".format(path, data.get("maturity")))
        if data.get("claim_level") == "verified" and data.get("maturity") == "experimental":
            errors.append("{} gives verified claim level to an experimental profile".format(path))
        evidence_path = root / str(data.get("evidence", ""))
        if not evidence_path.is_file():
            errors.append("{} references missing evidence {}".format(path, data.get("evidence")))
        profiles.append(data)

    claim_doc = load_yaml(root / "provenance/claims.yaml")
    evidence_doc = load_yaml(root / "provenance/evidence.yaml")
    claims = {item.get("id"): item for item in claim_doc.get("claims", [])}
    evidence = {item.get("id"): item for item in evidence_doc.get("evidence", [])}
    if None in claims or len(claims) != len(claim_doc.get("claims", [])):
        errors.append("claim IDs must be present and unique")
    if None in evidence or len(evidence) != len(evidence_doc.get("evidence", [])):
        errors.append("evidence IDs must be present and unique")

    for claim_id, claim in claims.items():
        missing = sorted(CLAIM_FIELDS - set(claim))
        if missing:
            errors.append("claim {} missing fields: {}".format(claim_id, ", ".join(missing)))
        if claim.get("status") not in allowed_maturity:
            errors.append("claim {} has unknown maturity {}".format(claim_id, claim.get("status")))
        if not isinstance(claim.get("public"), bool):
            errors.append("claim {} public must be boolean".format(claim_id))
        linked = [evidence.get(item) for item in claim.get("evidence", [])]
        if not linked or any(item is None for item in linked):
            errors.append("claim {} references nonexistent evidence".format(claim_id))
        elif claim.get("status") == "verified" and all(item.get("maturity") == "experimental" for item in linked):
            errors.append("verified claim {} is linked only to experimental evidence".format(claim_id))
        text = "{} {} {}".format(claim.get("statement", ""), claim.get("benchmark", ""), claim.get("tool", "")).lower()
        if any(word.lower() in text for word in PHYSICAL_KEYWORDS) and not claim.get("caveat"):
            errors.append("physical timing claim {} is missing a caveat".format(claim_id))

    for evidence_id, item in evidence.items():
        missing = sorted(EVIDENCE_FIELDS - set(item))
        if missing:
            errors.append("evidence {} missing fields: {}".format(evidence_id, ", ".join(missing)))
        if item.get("maturity") not in allowed_maturity:
            errors.append("evidence {} has unknown maturity {}".format(evidence_id, item.get("maturity")))
        if not isinstance(item.get("public"), bool):
            errors.append("evidence {} public must be boolean".format(evidence_id))
        path = root / str(item.get("path", ""))
        if not path.is_file():
            errors.append("evidence {} path is missing".format(evidence_id))
        for claim_id in item.get("claims", []):
            if claim_id not in claims:
                errors.append("evidence {} references nonexistent claim {}".format(evidence_id, claim_id))
            elif evidence_id not in claims[claim_id].get("evidence", []):
                errors.append("evidence {} and claim {} are not bidirectionally linked".format(evidence_id, claim_id))
        if path.is_file() and item.get("sha256") and sha256(path) != item.get("sha256"):
            errors.append("evidence {} SHA256 does not match {}".format(evidence_id, item.get("path")))

    configs = []
    if all_defconfigs:
        configs.extend(sorted((root / "configs").glob("*_defconfig")))
    if config_path and config_path.is_file():
        configs.append(config_path)
    for path in configs:
        try:
            validate_selected_config(root, parse_config(path))
        except RuntimeError as error:
            errors.append("{}: {}".format(path, error))

    if errors:
        raise RuntimeError("\n".join(errors))
    return {"profiles": len(profiles), "claims": len(claims), "evidence": len(evidence), "configs": len(configs)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2])
    parser.add_argument("--config", default=".config")
    parser.add_argument("--all-defconfigs", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    config = root / args.config
    try:
        summary = validate_repository(root, config, args.all_defconfigs)
    except RuntimeError as error:
        print("profile validation: FAIL: {}".format(error), file=sys.stderr)
        return 2
    print("profile validation: PASS profiles={profiles} claims={claims} evidence={evidence} configs={configs}".format(**summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
