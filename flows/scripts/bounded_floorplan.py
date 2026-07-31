#!/usr/bin/env python3
"""Build a deterministic bounded-ASIC floorplan contract from DC area."""

import argparse
import hashlib
import json
import math
import os
import re
from pathlib import Path


TOTAL_CELL_AREA_RE = re.compile(
    r"^\s*Total cell area:\s*([0-9]+(?:\.[0-9]+)?)\s*$", re.MULTILINE
)
MACRO_BLACK_BOX_AREA_RE = re.compile(
    r"^\s*Macro/Black Box area:\s*([0-9]+(?:\.[0-9]+)?)\s*$",
    re.MULTILINE,
)
LEF_MACRO_RE = re.compile(r"^\s*MACRO\s+(\S+)\s*$", re.MULTILINE)
LEF_SIZE_RE = re.compile(
    r"^\s*SIZE\s+([0-9]+(?:\.[0-9]+)?)\s+BY\s+"
    r"([0-9]+(?:\.[0-9]+)?)\s*;\s*$",
    re.MULTILINE,
)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_total_cell_area(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing DC area report: {}".format(path))
    matches = TOTAL_CELL_AREA_RE.findall(
        path.read_text(encoding="utf-8", errors="replace")
    )
    if len(matches) != 1:
        raise RuntimeError(
            "DC area report must contain exactly one Total cell area value"
        )
    value = float(matches[0])
    if not math.isfinite(value) or value <= 0.0:
        raise RuntimeError("DC Total cell area must be finite and positive")
    return value


def parse_area_summary(path):
    total_cell_area = parse_total_cell_area(path)
    text = path.read_text(encoding="utf-8", errors="replace")
    matches = MACRO_BLACK_BOX_AREA_RE.findall(text)
    if len(matches) > 1:
        raise RuntimeError(
            "DC area report must contain at most one Macro/Black Box area value"
        )
    macro_black_box_area = float(matches[0]) if matches else 0.0
    if (
        not math.isfinite(macro_black_box_area)
        or macro_black_box_area < 0.0
        or macro_black_box_area >= total_cell_area
    ):
        raise RuntimeError("DC Macro/Black Box area is invalid")
    return {
        "total_cell_area_um2": total_cell_area,
        "macro_black_box_area_um2": macro_black_box_area,
        "standard_cell_area_um2": total_cell_area - macro_black_box_area,
    }


def snap_up(value, quantum):
    return math.ceil((value - 1.0e-12) / quantum) * quantum


def snap_down(value, quantum):
    return math.floor((value + 1.0e-12) / quantum) * quantum


def format_number(value):
    text = "{:.6f}".format(value).rstrip("0").rstrip(".")
    return text if text else "0"


def register_floorplan(
    total_cell_area,
    target_core_utilization=0.45,
    place_density=0.55,
    minimum_die_side=1200.0,
    die_grid=10.0,
    horizontal_margin=20.14,
    vertical_margin=22.4,
):
    for label, value in (
        ("target_core_utilization", target_core_utilization),
        ("place_density", place_density),
    ):
        if not 0.0 < value < 1.0:
            raise RuntimeError("{} must be between zero and one".format(label))
    if target_core_utilization >= place_density:
        raise RuntimeError("target core utilization must be below place density")
    for label, value in (
        ("total_cell_area", total_cell_area),
        ("minimum_die_side", minimum_die_side),
        ("die_grid", die_grid),
        ("horizontal_margin", horizontal_margin),
        ("vertical_margin", vertical_margin),
    ):
        if not math.isfinite(value) or value <= 0.0:
            raise RuntimeError("{} must be finite and positive".format(label))

    required_core_area = total_cell_area / target_core_utilization
    required_core_side = math.sqrt(required_core_area)
    die_side = snap_up(
        max(
            minimum_die_side,
            required_core_side + 2.0 * max(horizontal_margin, vertical_margin),
        ),
        die_grid,
    )
    while True:
        core_width = die_side - 2.0 * horizontal_margin
        core_height = die_side - 2.0 * vertical_margin
        core_area = core_width * core_height
        actual_utilization = total_cell_area / core_area
        if actual_utilization <= target_core_utilization + 1.0e-12:
            break
        die_side += die_grid

    return {
        "die_area": "0 0 {0} {0}".format(format_number(die_side)),
        "core_area": "{} {} {} {}".format(
            format_number(horizontal_margin),
            format_number(vertical_margin),
            format_number(die_side - horizontal_margin),
            format_number(die_side - vertical_margin),
        ),
        "die_side_um": die_side,
        "core_width_um": core_width,
        "core_height_um": core_height,
        "core_area_um2": core_area,
        "initial_core_utilization": actual_utilization,
        "place_density": place_density,
    }


def parse_lef_macro_size(path, expected_macro):
    path = path.resolve()
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing macro LEF: {}".format(path))
    text = path.read_text(encoding="utf-8", errors="replace")
    macros = LEF_MACRO_RE.findall(text)
    sizes = LEF_SIZE_RE.findall(text)
    if macros != [expected_macro] or len(sizes) != 1:
        raise RuntimeError(
            "macro LEF must contain exactly one {} definition and size".format(
                expected_macro
            )
        )
    width, height = (float(value) for value in sizes[0])
    if not all(math.isfinite(value) and value > 0.0 for value in (width, height)):
        raise RuntimeError("macro LEF dimensions must be finite and positive")
    return width, height


def direct_sram_floorplan(
    total_cell_area,
    macro_width,
    macro_height,
    dc_macro_black_box_area=0.0,
    macro_count=8,
    target_core_utilization=0.45,
    place_density=0.55,
    minimum_die_side=100.0,
    die_grid=10.0,
    horizontal_margin=20.14,
    vertical_margin=22.4,
    macro_halo=20.0,
    macro_channel=60.0,
    minimum_local_buffer_channel=20.0,
    placement_grid=0.005,
    core_site_width=0.19,
    core_row_height=1.4,
):
    if macro_count != 8:
        raise RuntimeError("direct SRAM floorplan requires exactly eight macros")
    for label, value in (
        ("total_cell_area", total_cell_area),
        ("macro_width", macro_width),
        ("macro_height", macro_height),
        ("dc_macro_black_box_area", dc_macro_black_box_area),
        ("macro_halo", macro_halo),
        ("macro_channel", macro_channel),
        ("minimum_local_buffer_channel", minimum_local_buffer_channel),
        ("placement_grid", placement_grid),
        ("core_site_width", core_site_width),
        ("core_row_height", core_row_height),
    ):
        if not math.isfinite(value):
            raise RuntimeError("{} must be finite".format(label))
        if label == "dc_macro_black_box_area":
            if value < 0.0:
                raise RuntimeError("{} must be nonnegative".format(label))
        elif value <= 0.0:
            raise RuntimeError("{} must be positive".format(label))
    if not 0.0 < target_core_utilization < place_density < 1.0:
        raise RuntimeError("direct SRAM utilization must leave placement headroom")

    local_buffer_channel = macro_channel - 2.0 * macro_halo
    if local_buffer_channel < minimum_local_buffer_channel - 1.0e-12:
        raise RuntimeError(
            "direct SRAM channel leaves insufficient local-buffer space"
        )

    if dc_macro_black_box_area >= total_cell_area:
        raise RuntimeError("DC macro area must be below total cell area")
    standard_cell_area = total_cell_area - dc_macro_black_box_area
    macro_area = macro_width * macro_height
    required_core_area = (
        standard_cell_area / target_core_utilization + macro_count * macro_area
    )
    island_stack_height = 4.0 * macro_height + 3.0 * macro_channel
    minimum_core_width = 2.0 * (macro_width + macro_halo) + macro_channel
    minimum_core_height = island_stack_height + 2.0 * macro_halo
    required_core_side = max(
        math.sqrt(required_core_area), minimum_core_width, minimum_core_height
    )
    die_side = snap_up(
        max(
            minimum_die_side,
            required_core_side + 2.0 * max(horizontal_margin, vertical_margin),
        ),
        die_grid,
    )
    while True:
        # ORFS creates whole sites and rows from the lower-left core origin.
        # Model that upper-right snap here so the contract matches OpenDB.
        core_width = snap_down(
            die_side - 2.0 * horizontal_margin, core_site_width
        )
        core_height = snap_down(
            die_side - 2.0 * vertical_margin, core_row_height
        )
        core_area = core_width * core_height
        center_channel = core_width - 2.0 * (macro_width + macro_halo)
        vertical_clearance = core_height - island_stack_height
        placeable_core_area = core_area - macro_count * macro_area
        standard_cell_utilization = standard_cell_area / placeable_core_area
        total_footprint_occupancy = (
            standard_cell_area + macro_count * macro_area
        ) / core_area
        if (
            standard_cell_utilization <= target_core_utilization + 1.0e-12
            and center_channel >= macro_channel - 1.0e-12
            and vertical_clearance >= 2.0 * macro_halo - 1.0e-12
        ):
            break
        die_side += die_grid

    core_x_min = horizontal_margin
    core_y_min = vertical_margin
    core_x_max = core_x_min + core_width
    core_y_max = core_y_min + core_height
    left_x = snap_up(core_x_min + macro_halo, placement_grid)
    right_x = snap_down(
        core_x_max - macro_halo - macro_width, placement_grid
    )
    stack_y_min = snap_up(
        core_y_min + (core_height - island_stack_height) / 2.0,
        placement_grid,
    )
    placements = []
    for engine in range(2):
        x = left_x if engine == 0 else right_x
        orientation = "R0" if engine == 0 else "MY"
        for way in range(4):
            placements.append(
                {
                    "engine": engine,
                    "way": way,
                    "x_um": x,
                    "y_um": stack_y_min
                    + way * (macro_height + macro_channel),
                    "orientation": orientation,
                }
            )

    tolerance = 1.0e-9
    for placement in placements:
        x = placement["x_um"]
        y = placement["y_um"]
        if (
            x < core_x_min + macro_halo - tolerance
            or y < core_y_min + macro_halo - tolerance
            or x + macro_width > core_x_max - macro_halo + tolerance
            or y + macro_height > core_y_max - macro_halo + tolerance
        ):
            raise RuntimeError("direct SRAM macro placement escapes core halo")

    for left_index, left in enumerate(placements):
        for right in placements[left_index + 1 :]:
            horizontal_gap = max(
                right["x_um"] - (left["x_um"] + macro_width),
                left["x_um"] - (right["x_um"] + macro_width),
            )
            vertical_gap = max(
                right["y_um"] - (left["y_um"] + macro_height),
                left["y_um"] - (right["y_um"] + macro_height),
            )
            horizontal_overlap = horizontal_gap < -tolerance
            vertical_overlap = vertical_gap < -tolerance
            if horizontal_overlap and vertical_overlap:
                raise RuntimeError("direct SRAM macro placements overlap")
            if left["engine"] == right["engine"]:
                if horizontal_overlap and vertical_gap < macro_channel - tolerance:
                    raise RuntimeError(
                        "direct SRAM island channel is below policy"
                    )
            elif vertical_overlap and horizontal_gap < macro_channel - tolerance:
                raise RuntimeError("direct SRAM center channel is below policy")

    actual_center_channel = right_x - (left_x + macro_width)
    if actual_center_channel < macro_channel - tolerance:
        raise RuntimeError("direct SRAM center channel is below policy")

    return {
        "die_area": "0 0 {0} {0}".format(format_number(die_side)),
        "core_area": "{} {} {} {}".format(
            format_number(core_x_min),
            format_number(core_y_min),
            format_number(core_x_max),
            format_number(core_y_max),
        ),
        "die_side_um": die_side,
        "core_width_um": core_width,
        "core_height_um": core_height,
        "core_area_um2": core_area,
        "standard_cell_area_um2": standard_cell_area,
        "dc_macro_black_box_area_um2": dc_macro_black_box_area,
        "fixed_macro_footprint_um2": macro_count * macro_area,
        "placeable_core_area_um2": placeable_core_area,
        "standard_cell_utilization": standard_cell_utilization,
        "total_footprint_occupancy": total_footprint_occupancy,
        "place_density": place_density,
        "macro_count": macro_count,
        "macro_width_um": macro_width,
        "macro_height_um": macro_height,
        "macro_area_um2": macro_area,
        "macro_halo_um": macro_halo,
        "macro_channel_um": macro_channel,
        "local_buffer_channel_um": local_buffer_channel,
        "minimum_local_buffer_channel_um": minimum_local_buffer_channel,
        "placement_grid_um": placement_grid,
        "core_site_width_um": core_site_width,
        "core_row_height_um": core_row_height,
        "engine_islands": 2,
        "macros_per_island": 4,
        "island_stack_height_um": island_stack_height,
        "center_channel_um": actual_center_channel,
        "macro_placements": placements,
    }


def write_text_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(str(temporary), str(path))


def build_contract(
    area_report,
    output_json,
    output_env,
    profile="register",
    macro_lef=None,
    macro_name=None,
):
    area_report = area_report.resolve()
    output_json = output_json.resolve()
    output_env = output_env.resolve()
    area_summary = parse_area_summary(area_report)
    total_cell_area = area_summary["total_cell_area_um2"]
    if profile == "register":
        floorplan = register_floorplan(total_cell_area)
        policy = {
            "target_core_utilization": 0.45,
            "place_density": 0.55,
            "minimum_die_side_um": 1200.0,
            "die_grid_um": 10.0,
            "horizontal_margin_um": 20.14,
            "vertical_margin_um": 22.4,
        }
        macro = None
    elif profile == "direct-register":
        if area_summary["macro_black_box_area_um2"] != 0.0:
            raise RuntimeError(
                "direct register floorplan requires zero Macro/Black Box area"
            )
        floorplan = register_floorplan(
            total_cell_area, minimum_die_side=100.0
        )
        policy = {
            "target_core_utilization": 0.45,
            "place_density": 0.55,
            "minimum_die_side_um": 100.0,
            "die_grid_um": 10.0,
            "horizontal_margin_um": 20.14,
            "vertical_margin_um": 22.4,
        }
        macro = None
    elif profile == "direct-sram":
        if macro_lef is None or not macro_name:
            raise RuntimeError("direct-sram floorplan requires macro LEF and name")
        macro_lef = macro_lef.resolve()
        macro_width, macro_height = parse_lef_macro_size(
            macro_lef, macro_name
        )
        floorplan = direct_sram_floorplan(
            total_cell_area,
            macro_width,
            macro_height,
            dc_macro_black_box_area=area_summary[
                "macro_black_box_area_um2"
            ],
        )
        policy = {
            "target_core_utilization": 0.45,
            "place_density": 0.55,
            "minimum_die_side_um": 100.0,
            "die_grid_um": 10.0,
            "horizontal_margin_um": 20.14,
            "vertical_margin_um": 22.4,
            "macro_halo_um": 20.0,
            "macro_channel_um": 60.0,
            "minimum_local_buffer_channel_um": 20.0,
            "core_site_width_um": 0.19,
            "core_row_height_um": 1.4,
        }
        macro = {
            "name": macro_name,
            "lef": str(macro_lef),
            "lef_sha256": sha256_file(macro_lef),
            "width_um": macro_width,
            "height_um": macro_height,
            "count": 8,
        }
    else:
        raise RuntimeError("unsupported bounded floorplan profile: {}".format(profile))
    contract = {
        "schema_version": 1,
        "profile": profile,
        "source": {
            "dc_area_report": str(area_report),
            "dc_area_report_sha256": sha256_file(area_report),
            "total_cell_area_um2": total_cell_area,
            "macro_black_box_area_um2": area_summary[
                "macro_black_box_area_um2"
            ],
            "standard_cell_area_um2": area_summary[
                "standard_cell_area_um2"
            ],
        },
        "policy": policy,
        "floorplan": floorplan,
    }
    if macro is not None:
        contract["macro"] = macro
    write_text_atomic(
        output_json, json.dumps(contract, indent=2, sort_keys=True) + "\n"
    )
    contract_sha256 = sha256_file(output_json)
    shell = (
        "export RDTC_DIE_AREA='{die}'\n"
        "export RDTC_CORE_AREA='{core}'\n"
        "export RDTC_PLACE_DENSITY='{density}'\n"
        "export RDTC_FLOORPLAN_CONTRACT='{contract}'\n"
        "export RDTC_FLOORPLAN_CONTRACT_SHA256='{sha256}'\n"
    ).format(
        die=floorplan["die_area"],
        core=floorplan["core_area"],
        density=floorplan["place_density"],
        contract=output_json,
        sha256=contract_sha256,
    )
    if profile == "direct-sram":
        placement_list = " ".join(
            "{{{} {} {}}}".format(
                format_number(placement["x_um"]),
                format_number(placement["y_um"]),
                placement["orientation"],
            )
            for placement in floorplan["macro_placements"]
        )
        shell += (
            "export RDTC_DIRECT_MACRO_COUNT='8'\n"
            "export RDTC_DIRECT_MACRO_PLACEMENTS='{}'\n".format(
                placement_list
            )
        )
    write_text_atomic(output_env, shell)
    return contract, contract_sha256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dc-area-report", required=True, type=Path)
    parser.add_argument("--output-json", required=True, type=Path)
    parser.add_argument("--output-env", required=True, type=Path)
    parser.add_argument(
        "--profile",
        choices=("register", "direct-register", "direct-sram"),
        default="register",
    )
    parser.add_argument("--macro-lef", type=Path)
    parser.add_argument("--macro-name")
    args = parser.parse_args()
    contract, contract_sha256 = build_contract(
        args.dc_area_report,
        args.output_json,
        args.output_env,
        profile=args.profile,
        macro_lef=args.macro_lef,
        macro_name=args.macro_name,
    )
    print(
        "bounded-floorplan: PASS total_cell_area_um2={} die_side_um={} "
        "placement_utilization={:.6f} sha256={}".format(
            contract["source"]["total_cell_area_um2"],
            contract["floorplan"]["die_side_um"],
            contract["floorplan"].get(
                "initial_core_utilization",
                contract["floorplan"].get("standard_cell_utilization"),
            ),
            contract_sha256,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print("bounded-floorplan: error: {}".format(error))
        raise SystemExit(2)
