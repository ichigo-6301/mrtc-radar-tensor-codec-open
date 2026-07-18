#!/usr/bin/env python3
"""Generate an academic FreePDK45 ITF and optionally compile it to TLUPlus."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


TECHNOLOGY = "FreePDK45_RCtyp"
METALS = ["metal{}".format(index) for index in range(1, 11)]
VIAS = ["via{}".format(index) for index in range(1, 10)]


def require_file(path, label):
    if not path.is_file():
        raise RuntimeError("Missing {}: {}".format(label, path))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_geometry(rules_text, xrc_text):
    geometry = {}
    for index in range(1, 11):
        layer = "metal{}".format(index)
        width_match = re.search(
            r"^Metal{}\.1\s+.*?\s({number})\s+<".format(
                index, number=r"[0-9.]+"
            ),
            rules_text,
            re.MULTILINE,
        )
        space_match = re.search(
            r"^Metal{}\.2\s+.*?\s({number})\s+<".format(
                index, number=r"[0-9.]+"
            ),
            rules_text,
            re.MULTILINE,
        )
        if not width_match or not space_match:
            raise RuntimeError("Cannot parse width/spacing for {}".format(layer))
        geometry[layer] = {
            "width": float(width_match.group(1)),
            "space": float(space_match.group(1)),
        }

    poly_match = re.search(
        r"^//\s*\|\s+poly\s+C\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)",
        xrc_text,
        re.MULTILINE,
    )
    if not poly_match:
        raise RuntimeError("Cannot parse poly geometry from Calibre xRC profile")
    geometry["poly"] = {
        "thickness": float(poly_match.group(1)),
        "width": float(poly_match.group(2)),
        "space": float(poly_match.group(3)),
    }
    return geometry


def parse_thickness_and_resistance(xrc_text, geometry):
    thicknesses = {
        name: float(value)
        for name, value in re.findall(
            r"^PEX THICKNESS\s+(poly|metal\d+)\s+NOMINAL\s+([0-9.]+)",
            xrc_text,
            re.MULTILINE,
        )
    }
    resistances = {
        name: float(value)
        for name, value in re.findall(
            r"^RESISTANCE SHEET\s+(poly|metal\d+)\s+\[\s*([0-9.]+)",
            xrc_text,
            re.MULTILINE,
        )
    }
    for layer in ["poly"] + METALS:
        if layer not in thicknesses or layer not in resistances:
            raise RuntimeError("Cannot parse thickness/resistance for {}".format(layer))
        geometry[layer]["thickness"] = thicknesses[layer]
        geometry[layer]["rpsq"] = resistances[layer]


def parse_dielectrics(xrc_text):
    dielectrics = {}
    pattern = re.compile(
        r"^//\s*\|\s+(field_base_diel|poly_diel|metal\d+_diel)"
        r"\s+D\s+([0-9.]+)\s+([0-9.]+)",
        re.MULTILINE,
    )
    for name, thickness, permittivity in pattern.findall(xrc_text):
        dielectrics[name] = {
            "thickness": float(thickness),
            "er": float(permittivity),
        }
    required = ["field_base_diel", "poly_diel"] + [
        "metal{}_diel".format(index) for index in range(1, 10)
    ]
    missing = [name for name in required if name not in dielectrics]
    if missing:
        raise RuntimeError("Cannot parse dielectric layers: {}".format(", ".join(missing)))
    return dielectrics


def parse_vias(tech_text):
    resistance = {
        name: float(value)
        for name, value in re.findall(
            r"\(\s*contactResistance\s+(contact|via\d+)\s+([0-9.]+)\s*\)",
            tech_text,
        )
    }
    shapes = {}
    pattern = re.compile(
        r"\(\s*\S+\s+(poly|metal\d+)\s+(metal\d+)\s+"
        r"\(\"(contact|via\d+)\"\s+([0-9.]+)\s+([0-9.]+)\)",
        re.MULTILINE,
    )
    for lower, upper, name, width, height in pattern.findall(tech_text):
        if name not in shapes:
            shapes[name] = {
                "lower": lower,
                "upper": upper,
                "width": float(width),
                "height": float(height),
            }
    vias = {}
    for name in ["contact"] + VIAS:
        if name not in resistance or name not in shapes:
            raise RuntimeError("Cannot parse via definition for {}".format(name))
        vias[name] = shapes[name]
        vias[name]["resistance"] = resistance[name]
    return vias


def render_conductor(name, data):
    return (
        "CONDUCTOR {name} {{ THICKNESS={thickness:.6f} WMIN={width:.6f} "
        "SMIN={space:.6f} RPSQ={rpsq:.6f} }}"
    ).format(name=name, **data)


def render_dielectric(name, data):
    return "DIELECTRIC {name} {{ THICKNESS={thickness:.6f} ER={er:.6f} }}".format(
        name=name, **data
    )


def render_itf(geometry, dielectrics, vias, source_hashes):
    lines = [
        "$ Academic FreePDK45 interconnect model generated from local FreePDK45 v1.4 files.",
        "$ Not a foundry-calibrated or signoff extraction model.",
        "$ source_calibrexrc_sha256={}".format(source_hashes["calibrexRC.rul"]),
        "$ source_rules_sha256={}".format(source_hashes["rules.txt"]),
        "$ source_techfile_sha256={}".format(source_hashes["FreePDK45.tf"]),
        "",
        "TECHNOLOGY = {}".format(TECHNOLOGY),
        "",
        render_conductor("metal10", geometry["metal10"]),
    ]
    for index in range(9, 0, -1):
        dielectric = "metal{}_diel".format(index)
        metal = "metal{}".format(index)
        lines.append(render_dielectric(dielectric, dielectrics[dielectric]))
        lines.append(render_conductor(metal, geometry[metal]))
    lines.append(render_dielectric("poly_diel", dielectrics["poly_diel"]))
    lines.append(render_conductor("poly", geometry["poly"]))
    lines.append(render_dielectric("field_base_diel", dielectrics["field_base_diel"]))
    lines.append("")
    lines.append("$ Via RPV values use FreePDK45 Cadence contactResistance as an academic estimate.")
    for name in ["contact"] + VIAS:
        via = vias[name]
        area = via["width"] * via["height"]
        lines.append(
            "VIA {name} {{ FROM={lower} TO={upper} AREA={area:.8f} RPV={resistance:.6f} }}".format(
                name=name, area=area, **via
            )
        )
    lines.append("")
    return "\n".join(lines)


def render_layer_map():
    lines = ["conducting_layers", "poly poly"]
    lines.extend("{0} {0}".format(layer) for layer in METALS)
    lines.append("via_layers")
    lines.append("contact contact")
    lines.extend("{0} {0}".format(via) for via in VIAS)
    lines.append("")
    return "\n".join(lines)


def run_grdgenxo(tool, output_dir, itf_path):
    executable = shutil.which(tool) if not Path(tool).is_file() else tool
    if not executable:
        raise RuntimeError(
            "grdgenxo is not installed or not on PATH; install licensed Synopsys "
            "StarRC/StarRCXT and set RDTC_TOOL_GRDGENXO to its bin/grdgenxo path. "
            "ITF generation completed, but TLUPlus generation cannot run"
        )
    process = subprocess.run(
        [str(executable), itf_path.name],
        cwd=str(output_dir),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
    )
    log_path = output_dir / "grdgenxo.log"
    log_path.write_text(process.stdout, encoding="utf-8")
    if process.returncode != 0:
        raise RuntimeError("grdgenxo failed; see {}".format(log_path))
    tluplus = output_dir / (TECHNOLOGY + ".TLUPlus")
    if not tluplus.exists():
        raise RuntimeError("grdgenxo did not create {}".format(tluplus))
    return tluplus


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--freepdk45-root", default=os.environ.get("RDTC_FREEPDK45_ROOT", ""))
    parser.add_argument("--output-dir", default=os.environ.get("RDTC_RC_OUTPUT_DIR", ""))
    parser.add_argument("--grdgenxo", default=os.environ.get("RDTC_TOOL_GRDGENXO", "grdgenxo"))
    parser.add_argument("--itf-only", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.freepdk45_root or not args.output_dir:
        raise RuntimeError("RDTC_FREEPDK45_ROOT and RDTC_RC_OUTPUT_DIR are required")
    pdk_root = Path(args.freepdk45_root).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    tech_root = pdk_root / "ncsu_basekit" / "techfile"
    paths = {
        "calibrexRC.rul": tech_root / "calibre" / "calibrexRC.rul",
        "rules.txt": tech_root / "rules.txt",
        "FreePDK45.tf": tech_root / "FreePDK45.tf",
    }
    for name, path in paths.items():
        require_file(path, name)

    itf_path = output_dir / (TECHNOLOGY + ".itf")
    map_path = output_dir / "freepdk45.tluplus.map"
    print("freepdk45_root: {}".format(pdk_root))
    print("itf: {}".format(itf_path))
    print("layer_map: {}".format(map_path))
    print("grdgenxo: {}".format(args.grdgenxo))
    if args.dry_run:
        return 0

    texts = {name: path.read_text(encoding="utf-8", errors="replace") for name, path in paths.items()}
    geometry = parse_geometry(texts["rules.txt"], texts["calibrexRC.rul"])
    parse_thickness_and_resistance(texts["calibrexRC.rul"], geometry)
    dielectrics = parse_dielectrics(texts["calibrexRC.rul"])
    vias = parse_vias(texts["FreePDK45.tf"])
    source_hashes = {name: sha256(path) for name, path in paths.items()}

    output_dir.mkdir(parents=True, exist_ok=True)
    itf_path.write_text(render_itf(geometry, dielectrics, vias, source_hashes), encoding="ascii")
    map_path.write_text(render_layer_map(), encoding="ascii")
    tluplus = None
    if not args.itf_only:
        tluplus = run_grdgenxo(args.grdgenxo, output_dir, itf_path)

    manifest = {
        "status": "academic_estimate",
        "technology": TECHNOLOGY,
        "source_files": {name: {"path": str(path), "sha256": source_hashes[name]} for name, path in paths.items()},
        "itf": {"path": str(itf_path), "sha256": sha256(itf_path)},
        "layer_map": {"path": str(map_path), "sha256": sha256(map_path)},
        "tluplus": str(tluplus) if tluplus else None,
        "caveats": [
            "Derived from public FreePDK45 v1.4 data; not foundry calibrated.",
            "Via RPV uses Cadence contactResistance as an academic estimate.",
            "No process variation or silicon correlation is claimed.",
        ],
    }
    manifest_path = output_dir / "freepdk45_rc_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("manifest: {}".format(manifest_path))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        print("freepdk45_rc_prepare: error: {}".format(error), file=sys.stderr)
        sys.exit(2)
