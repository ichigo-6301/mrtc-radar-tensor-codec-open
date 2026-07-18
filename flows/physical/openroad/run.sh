#!/usr/bin/env bash
set -euo pipefail

: "${RDTC_FLOW_ROOT:?Missing RDTC_FLOW_ROOT}"
: "${RDTC_BUILD_ROOT:?Missing RDTC_BUILD_ROOT}"
: "${RDTC_DC_HANDOFF_ROOT:=$RDTC_BUILD_ROOT}"
: "${RDTC_TOP:?Missing RDTC_TOP}"
: "${RDTC_ORFS_IMAGE:?Missing RDTC_ORFS_IMAGE}"
: "${RDTC_ORFS_PLATFORM:?Missing RDTC_ORFS_PLATFORM}"
: "${RDTC_MEMORY_MODE:?Missing RDTC_MEMORY_MODE}"
: "${RDTC_SDC:?Missing RDTC_SDC}"
: "${RDTC_CLOCK_PERIOD_NS:?Missing RDTC_CLOCK_PERIOD_NS}"

case "$RDTC_ORFS_IMAGE" in
  *@sha256:*) ;;
  *) echo "RDTC_ORFS_IMAGE must be pinned by digest" >&2; exit 2 ;;
esac

if [[ -n "${RDTC_EXPECTED_DC_NETLIST_SHA256:-}" ]]; then
  expected_dc_netlist="$RDTC_DC_HANDOFF_ROOT/dc_baseline/${RDTC_TOP}_baseline.v"
  test -s "$expected_dc_netlist" || {
    echo "Missing expected DC netlist: $expected_dc_netlist" >&2
    exit 2
  }
  actual_dc_netlist=$(sha256sum "$expected_dc_netlist" | awk '{print $1}')
  [[ "$actual_dc_netlist" == "$RDTC_EXPECTED_DC_NETLIST_SHA256" ]] || {
    echo "DC netlist hash mismatch" >&2
    echo "expected: $RDTC_EXPECTED_DC_NETLIST_SHA256" >&2
    echo "actual:   $actual_dc_netlist" >&2
    exit 2
  }
fi

if [[ "${RDTC_TARGETED_DRC_ECO:-}" == "rdtc333_spice_eco1" ]]; then
  eco_netlist="$RDTC_BUILD_ROOT/dc_baseline/${RDTC_TOP}_baseline.v"
  expected_netlist_sha256=5b5c7a7d6f600e4a816e6e248cc21dc129bdbb3693306dec07dc453806cc5be2
  test -s "$eco_netlist" || {
    echo "Missing mapped netlist for rdtc333_spice_eco1: $eco_netlist" >&2
    exit 2
  }
  actual_netlist_sha256=$(sha256sum "$eco_netlist" | awk '{print $1}')
  [[ "$actual_netlist_sha256" == "$expected_netlist_sha256" ]] || {
    echo "rdtc333_spice_eco1 mapped-netlist hash mismatch" >&2
    echo "expected: $expected_netlist_sha256" >&2
    echo "actual:   $actual_netlist_sha256" >&2
    exit 2
  }
  [[ "${CONFIG_FLOW_TECHNOLOGY:-}" == "nangate45_openram_spice" &&
     "$RDTC_CLOCK_PERIOD_NS" == "3.000" &&
     "${RDTC_HOLD_SLACK_MARGIN_NS:-}" == "0.06" &&
     "${RDTC_CAP_MARGIN_PERCENT:-}" == "60" &&
     "${RDTC_SLEW_MARGIN_PERCENT:-}" == "65" ]] || {
    echo "rdtc333_spice_eco1 requires its pinned 3.000 ns guardband profile" >&2
    exit 2
  }
fi

docker_tool=${RDTC_DOCKER:-docker}
output_root="$RDTC_BUILD_ROOT/openroad"
work_home="$output_root/orfs"
handoff="$output_root/handoff"
local_views="$output_root/local_views"
mkdir -p "$work_home" "$handoff" "$local_views"

container_path() {
  case "$1" in
    "$RDTC_FLOW_ROOT"/*)
      printf '/rdtc/%s' "${1#"$RDTC_FLOW_ROOT"/}"
      ;;
    *)
      echo "OpenROAD input is outside RDTC_FLOW_ROOT: $1" >&2
      return 2
      ;;
  esac
}

if [[ "$RDTC_MEMORY_MODE" == "macro" ]]; then
  if [[ "$RDTC_ORFS_PLATFORM" == "sky130hd" ]]; then
    export RDTC_SRAM_MACRO=sky130_sram_1kbyte_1rw1r_32x256_8
    python3 "$RDTC_FLOW_ROOT/flows/scripts/normalize_openram_lef.py" \
      --input "$RDTC_BUILD_ROOT/sram_openram/views/${RDTC_SRAM_MACRO}.lef" \
      --output "$local_views/${RDTC_SRAM_MACRO}_dbu1000.lef" \
      --grid-microns 0.001 \
      --database-microns 1000
    export RDTC_SRAM_LEF="$local_views/${RDTC_SRAM_MACRO}_dbu1000.lef"
    export RDTC_SRAM_LIB="$RDTC_BUILD_ROOT/sram_openram/views/${RDTC_SRAM_MACRO}_TT_1p8V_25C.lib"
    export RDTC_SRAM_GDS="$RDTC_BUILD_ROOT/sram_openram/views/${RDTC_SRAM_MACRO}.gds"
  else
    if [[ "${CONFIG_FLOW_TECHNOLOGY:-}" == "nangate45_openram_spice" ]]; then
      export RDTC_SRAM_MACRO=mrtc_rdtc_prefix_1rw1r_64x128
    else
      export RDTC_SRAM_MACRO=mrtc_rdtc_prefix_1r1w_64x128
    fi
    python3 "$RDTC_FLOW_ROOT/flows/scripts/normalize_openram_lef.py" \
      --input "$RDTC_BUILD_ROOT/sram_openram/views/${RDTC_SRAM_MACRO}.lef" \
      --output "$local_views/${RDTC_SRAM_MACRO}_grid5nm.lef" \
      --grid-microns 0.005
    export RDTC_SRAM_LEF="$local_views/${RDTC_SRAM_MACRO}_grid5nm.lef"
    if [[ "${CONFIG_FLOW_TECHNOLOGY:-}" == "nangate45_openram_spice" ]]; then
      sram_voltage=1p1
    else
      sram_voltage=1p0
    fi
    export RDTC_SRAM_LIB="$RDTC_BUILD_ROOT/sram_openram/views/${RDTC_SRAM_MACRO}_TT_${sram_voltage}V_25C.lib"
    export RDTC_SRAM_GDS="$RDTC_BUILD_ROOT/sram_openram/views/${RDTC_SRAM_MACRO}.gds"
  fi
else
  export RDTC_SRAM_MACRO=""
  export RDTC_SRAM_LEF=""
  export RDTC_SRAM_LIB=""
  export RDTC_SRAM_GDS=""
fi

container_sram_lef=""
container_sram_lib=""
container_sram_gds=""
container_sdc=$(container_path "$RDTC_SDC")
container_dc_handoff_root=$(container_path "$RDTC_DC_HANDOFF_ROOT")
if [[ "$RDTC_MEMORY_MODE" == "macro" ]]; then
  container_sram_lef=$(container_path "$RDTC_SRAM_LEF")
  container_sram_lib=$(container_path "$RDTC_SRAM_LIB")
  container_sram_gds=$(container_path "$RDTC_SRAM_GDS")
fi

uid=$(id -u)
gid=$(id -g)
results_dir="$work_home/results/$RDTC_ORFS_PLATFORM/rdtc_v1/base"

if ! { test -s "$results_dir/6_final.odb" && \
       test -s "$results_dir/6_final.v" && \
       test -s "$results_dir/6_final.sdc" && \
       test -s "$results_dir/6_final.spef"; }; then
  "$docker_tool" run --rm \
    -u "$uid:$gid" \
    -v "$RDTC_FLOW_ROOT:/rdtc" \
    -e RDTC_FLOW_ROOT=/rdtc \
	-e RDTC_BUILD_ROOT="/rdtc/${RDTC_BUILD_ROOT#"$RDTC_FLOW_ROOT"/}" \
	-e RDTC_DC_HANDOFF_ROOT="$container_dc_handoff_root" \
	-e RDTC_TOP="$RDTC_TOP" \
	-e RDTC_ORFS_PLATFORM="$RDTC_ORFS_PLATFORM" \
	-e RDTC_SDC="$container_sdc" \
	-e RDTC_CLOCK_PERIOD_NS="$RDTC_CLOCK_PERIOD_NS" \
	-e RDTC_SETUP_SLACK_MARGIN_NS="${RDTC_SETUP_SLACK_MARGIN_NS:-0.00}" \
	-e RDTC_HOLD_SLACK_MARGIN_NS="${RDTC_HOLD_SLACK_MARGIN_NS:--0.05}" \
	-e RDTC_CAP_MARGIN_PERCENT="${RDTC_CAP_MARGIN_PERCENT:-}" \
	-e RDTC_SLEW_MARGIN_PERCENT="${RDTC_SLEW_MARGIN_PERCENT:-}" \
	-e RDTC_GRT_HOLD_SLACK_MARGIN_NS="${RDTC_GRT_HOLD_SLACK_MARGIN_NS:-}" \
	-e RDTC_POST_GRT_HOLD_REPAIR_PASSES="${RDTC_POST_GRT_HOLD_REPAIR_PASSES:-0}" \
	-e RDTC_POST_GRT_HOLD_SLACK_MARGIN_NS="${RDTC_POST_GRT_HOLD_SLACK_MARGIN_NS:-0.00}" \
	-e RDTC_TARGETED_DRC_ECO="${RDTC_TARGETED_DRC_ECO:-}" \
	-e RDTC_EXPECTED_DC_NETLIST_SHA256="${RDTC_EXPECTED_DC_NETLIST_SHA256:-}" \
	-e RDTC_MEMORY_MODE="$RDTC_MEMORY_MODE" \
    -e RDTC_SRAM_MACRO="$RDTC_SRAM_MACRO" \
    -e RDTC_SRAM_LEF="$container_sram_lef" \
    -e RDTC_SRAM_LIB="$container_sram_lib" \
    -e RDTC_SRAM_GDS="$container_sram_gds" \
    -w /OpenROAD-flow-scripts/flow \
    "$RDTC_ORFS_IMAGE" \
    bash -lc 'source /OpenROAD-flow-scripts/env.sh && make DESIGN_CONFIG=/rdtc/flows/physical/openroad/config.mk WORK_HOME="$RDTC_BUILD_ROOT/openroad/orfs"'
fi

final_odb="$results_dir/6_final.odb"
test -f "$final_odb" || { echo "Missing ORFS final database: $final_odb" >&2; exit 2; }

cp "$results_dir/6_final.v" "$handoff/${RDTC_TOP}_postroute.v"
python3 "$RDTC_FLOW_ROOT/flows/scripts/sanitize_openroad_sdc.py" \
  --input "$results_dir/6_final.sdc" \
  --output "$handoff/${RDTC_TOP}_postroute.sdc"
cp "$results_dir/6_final.spef" "$handoff/${RDTC_TOP}_postroute.spef"
for artifact in odb def gds; do
  if [[ -s "$results_dir/6_final.$artifact" ]]; then
    cp "$results_dir/6_final.$artifact" "$handoff/${RDTC_TOP}_postroute.$artifact"
  fi
done

for suffix in v sdc spef; do
  test -s "$handoff/${RDTC_TOP}_postroute.$suffix" || {
    echo "Missing OpenROAD handoff: $handoff/${RDTC_TOP}_postroute.$suffix" >&2
    exit 2
  }
done

echo "INFO: OpenROAD/OpenRCX post-route handoff completed"
