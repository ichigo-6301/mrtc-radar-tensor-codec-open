ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CONFIG ?= .config
DEFCONFIG ?= configs/rdtc_v1_public_preflight_defconfig
LOCAL_CONFIG ?= flows/local/toolchain.mk
PYTHON ?= python3
RELEASE_REF ?= rdtc-v1-register550-rc3
KCONFIG_MCONF ?= mconf
FLOWCTL := $(PYTHON) flows/scripts/flowctl.py --root "$(ROOT)" --config "$(CONFIG)"
PROFILE_VALIDATOR := $(PYTHON) flows/scripts/validate_profile.py --root "$(ROOT)" --config "$(CONFIG)"
CHECKSUM_GENERATOR := $(PYTHON) provenance/generate_checksums.py --root "$(ROOT)"
RELEASE_VERIFIER := $(PYTHON) provenance/verify_release.py --root "$(ROOT)"
unquote = $(subst ",,$(1))

-include $(CONFIG)
-include $(LOCAL_CONFIG)

export RDTC_FLOW_ROOT := $(ROOT)
export RDTC_FLOW_CONFIG := $(abspath $(CONFIG))
export RDTC_FILELIST ?= $(ROOT)/flows/manifests/rdtc_v1.f
export RDTC_SDC ?= $(ROOT)/flows/constraints/rdtc_v1_internal_400m.sdc
export RDTC_TOP ?= $(call unquote,$(CONFIG_RDTC_TOP))
export RDTC_BUILD_ROOT ?= $(ROOT)/build/$(call unquote,$(CONFIG_FLOW_BUILD_TAG))
RDTC_DC_HANDOFF_ROOT ?= $(RDTC_BUILD_ROOT)
ifneq ($(strip $(CONFIG_FLOW_DC_HANDOFF_BUILD_TAG)),)
RDTC_DC_HANDOFF_ROOT := $(ROOT)/build/$(call unquote,$(CONFIG_FLOW_DC_HANDOFF_BUILD_TAG))
endif
export RDTC_CLOCK_PERIOD_NS ?= $(call unquote,$(CONFIG_FLOW_CLOCK_PERIOD_NS))
export RDTC_DC_CLOCK_PERIOD_NS ?= $(call unquote,$(CONFIG_FLOW_DC_CLOCK_PERIOD_NS))
export RDTC_PNR_CLOCK_PERIOD_NS ?= $(call unquote,$(CONFIG_FLOW_PNR_CLOCK_PERIOD_NS))
export RDTC_STA_CLOCK_PERIOD_NS ?= $(call unquote,$(CONFIG_FLOW_STA_CLOCK_PERIOD_NS))
export RDTC_SETUP_SLACK_MARGIN_NS ?= $(call unquote,$(CONFIG_FLOW_SETUP_SLACK_MARGIN_NS))
export RDTC_HOLD_SLACK_MARGIN_NS ?= $(call unquote,$(CONFIG_FLOW_HOLD_SLACK_MARGIN_NS))
export RDTC_CAP_MARGIN_PERCENT ?= $(call unquote,$(CONFIG_FLOW_CAP_MARGIN_PERCENT))
export RDTC_SLEW_MARGIN_PERCENT ?= $(call unquote,$(CONFIG_FLOW_SLEW_MARGIN_PERCENT))
export RDTC_GRT_HOLD_SLACK_MARGIN_NS ?= $(call unquote,$(CONFIG_FLOW_GRT_HOLD_SLACK_MARGIN_NS))
export RDTC_POST_GRT_HOLD_REPAIR_PASSES ?= $(call unquote,$(CONFIG_FLOW_POST_GRT_HOLD_REPAIR_PASSES))
export RDTC_POST_GRT_HOLD_SLACK_MARGIN_NS ?= $(call unquote,$(CONFIG_FLOW_POST_GRT_HOLD_SLACK_MARGIN_NS))
export RDTC_TARGETED_DRC_ECO ?= $(call unquote,$(CONFIG_FLOW_TARGETED_DRC_ECO))
export RDTC_EXPECTED_DC_NETLIST_SHA256 ?= $(call unquote,$(CONFIG_FLOW_EXPECTED_DC_NETLIST_SHA256))
export RDTC_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER ?= $(CONFIG_FLOW_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER)
export RDTC_STA_WAIVER_POLICY ?= $(call unquote,$(CONFIG_FLOW_STA_WAIVER_POLICY))
export RDTC_PRODUCT_PROFILE ?= $(call unquote,$(CONFIG_FLOW_PRODUCT_PROFILE))
export RDTC_MEMORY_MODE ?= $(call unquote,$(CONFIG_FLOW_MEMORY_MODE))
export RDTC_TSMC90_MEMORY_VARIANT ?= $(call unquote,$(CONFIG_FLOW_TSMC90_MEMORY_VARIANT))
export RDTC_ORFS_PLATFORM ?= $(call unquote,$(CONFIG_FLOW_OPENROAD_PLATFORM))
export RDTC_TECHNOLOGY ?= $(call unquote,$(CONFIG_FLOW_TECHNOLOGY))

RDTC_REGISTER_DC_SETUP ?= $(ROOT)/flows/local/dc_setup_registers.tcl
RDTC_REGISTER_PRIMETIME_SETUP ?= $(ROOT)/flows/local/primetime_setup_registers.tcl
ifeq ($(RDTC_MEMORY_MODE),registers)
RDTC_DC_SETUP := $(RDTC_REGISTER_DC_SETUP)
RDTC_PRIMETIME_SETUP := $(RDTC_REGISTER_PRIMETIME_SETUP)
ifeq ($(RDTC_TECHNOLOGY),nangate15_registers)
RDTC_STDCELL_DB ?= $(RDTC_NANGATE15_DB)
endif
ifeq ($(RDTC_TECHNOLOGY),nangate45_registers)
RDTC_STDCELL_DB ?= $(RDTC_NANGATE45_DB)
endif
ifeq ($(RDTC_TECHNOLOGY),icsprout55_registers)
RDTC_STDCELL_DB ?= $(RDTC_ICSPROUT55_DB)
endif
endif
RDTC_TOOL_SPYGLASS ?= spyglass
RDTC_TOOL_PYTHON ?= $(PYTHON)
RDTC_TOOL_VLIB ?= vlib
RDTC_TOOL_VLOG ?= vlog
RDTC_TOOL_VSIM ?= vsim
RDTC_TOOL_VCS ?= vcs
RDTC_TOOL_DC ?= dc_shell
RDTC_TOOL_LC ?= lc_shell
RDTC_SYNOPSYS_LC_ROOT ?=
RDTC_TOOL_OPENRAM_PYTHON ?= python3
RDTC_TSMC90_RF_GENERATOR ?= rf_2p_adv
RDTC_TSMC90_SRAM_GENERATOR ?= sram_dp_adv
RDTC_TOOL_GRDGENXO ?= grdgenxo
RDTC_TOOL_DFT ?= dc_shell
RDTC_TOOL_LEC ?= fm_shell
RDTC_TOOL_ICC2_LM ?= icc2_lm_shell
RDTC_TOOL_ICC2 ?= icc2_shell
RDTC_TOOL_OPENROAD ?= bash
RDTC_TOOL_PRIMETIME ?= pt_shell
export RDTC_TOOL_PYTHON RDTC_TOOL_VLIB RDTC_TOOL_VLOG RDTC_TOOL_VSIM
export RDTC_TOOL_VCS
export RDTC_TOOL_SPYGLASS RDTC_TOOL_DC RDTC_TOOL_DFT RDTC_TOOL_LEC
export RDTC_TOOL_LC RDTC_TOOL_OPENRAM_PYTHON RDTC_OPENRAM_HOME
export RDTC_OPENRAM_REUSE_DIR
export RDTC_NGSPICE_REAL RDTC_NGSPICE_SOURCE_ARCHIVE
export RDTC_SKY130_PDK_ROOT RDTC_SKY130_SRAM_CELL_ROOT
export RDTC_CLOCK_PERIOD_NS RDTC_DC_CLOCK_PERIOD_NS RDTC_PNR_CLOCK_PERIOD_NS RDTC_STA_CLOCK_PERIOD_NS
export RDTC_SETUP_SLACK_MARGIN_NS RDTC_HOLD_SLACK_MARGIN_NS RDTC_GRT_HOLD_SLACK_MARGIN_NS
export RDTC_CAP_MARGIN_PERCENT RDTC_SLEW_MARGIN_PERCENT
export RDTC_POST_GRT_HOLD_REPAIR_PASSES
export RDTC_POST_GRT_HOLD_SLACK_MARGIN_NS
export RDTC_TARGETED_DRC_ECO RDTC_EXPECTED_DC_NETLIST_SHA256 RDTC_DC_HANDOFF_ROOT
export RDTC_STA_UNUSED_RW_DOUT_MIN_CAP_WAIVER RDTC_STA_WAIVER_POLICY
export RDTC_PRODUCT_PROFILE RDTC_MEMORY_MODE RDTC_TSMC90_MEMORY_VARIANT RDTC_ORFS_PLATFORM RDTC_TECHNOLOGY
export RDTC_STDCELL_DB RDTC_NANGATE15_DB RDTC_NANGATE45_DB RDTC_ICSPROUT55_DB
export RDTC_TSMC90_RF_GENERATOR RDTC_TSMC90_SRAM_GENERATOR
export RDTC_TOOL_GRDGENXO RDTC_FREEPDK45_ROOT RDTC_RC_OUTPUT_DIR
export RDTC_TOOL_ICC2_LM RDTC_TOOL_ICC2 RDTC_TOOL_OPENROAD RDTC_TOOL_PRIMETIME
export RDTC_DC_SETUP RDTC_DFT_SETUP RDTC_LEC_SETUP RDTC_ICC2_SETUP RDTC_PRIMETIME_SETUP
export RDTC_ORFS_IMAGE RDTC_DOCKER
ifneq ($(strip $(RDTC_SYNOPSYS_LC_ROOT)),)
export SYNOPSYS_LC_ROOT := $(RDTC_SYNOPSYS_LC_ROOT)
endif

.DEFAULT_GOAL := help
.PHONY: help defconfig rdtc_v1_public_preflight_defconfig rdtc_v1_45nm_defconfig rdtc_v1_45nm_holdfix_400m_defconfig \
        rdtc_v1_45nm_dc900_pnr800_defconfig rdtc_v1_45nm_dc900_pnr700_defconfig \
        rdtc_v1_45nm_dc900_pnr650_defconfig rdtc_v1_45nm_dc900_pnr650_guardband_defconfig \
        rdtc_v1_45nm_dc900mapped_pnr700_defconfig \
        rdtc_v1_45nm_dc900mapped_pnr600_defconfig \
        rdtc_v1_45nm_dc900mapped_pnr600_spice_sram_defconfig \
        rdtc_v1_45nm_dc900mapped_pnr350_spice_sram_defconfig \
        rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_defconfig \
        rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_eco1_defconfig \
        rdtc_v1_45nm_dc900mapped_pnr550_defconfig \
        rdtc_v1_45nm_dc900mapped_pnr500_defconfig \
        rdtc_v1_90nm_defconfig rdtc_v1_tsmc90_rf64x128_partial_defconfig \
        rdtc_v1_tsmc90_sram128x128_partial_defconfig \
        rdtc_v1_sky130_registers_100m_defconfig rdtc_v1_sky130_macro_100m_defconfig \
        rdtc_v1_sky130_macro_200m_defconfig rdtc_v1_sky130_macro_400m_defconfig \
        menuconfig showconfig validate-profile verify-checksums verify-release public-preflight \
        list-stages lib-prep lib-prep-dry-run sram-model-smoke \
        sram-prep sram-prep-dry-run rc-itf rc-prep rc-prep-dry-run \
        icc2-libs icc2-libs-dry-run \
        rtl-smoke sim sim-dry-run sim-full selected selected-dry-run \
        lint lint-dry-run cdc cdc-dry-run \
        dc-baseline dc-baseline-dry-run dc-gated dc-gated-dry-run \
        dft dft-dry-run lec lec-dry-run pnr pnr-full pnr-floorplan pnr-dry-run sta sta-dry-run timing-audit

help:
	@printf '%s\n' \
	  'MRTC RDTC v1 public implementation flow' \
	  '' \
	  '  make rdtc_v1_public_preflight_defconfig  Create the public-safe default .config' \
	  '  make rdtc_v1_45nm_defconfig   Create the historical 45 nm implementation .config' \
	  '  make rdtc_v1_45nm_holdfix_400m_defconfig  Create the 400 MHz post-GRT hold-closure profile' \
	  '  make rdtc_v1_45nm_dc900_pnr800_defconfig  Create the 900 MHz DC / 800 MHz P&R profile' \
	  '  make rdtc_v1_45nm_dc900_pnr700_defconfig  Create the 900 MHz-target DC / 700 MHz P&R profile' \
	  '  make rdtc_v1_45nm_dc900_pnr650_defconfig  Create the 900 MHz-target DC / 650 MHz P&R profile' \
	  '  make rdtc_v1_45nm_dc900_pnr650_guardband_defconfig  Create the guarded 650 MHz closure profile' \
	  '  make rdtc_v1_45nm_dc900mapped_pnr700_defconfig  Preserve the DC mapping for 700 MHz P&R' \
	  '  make rdtc_v1_45nm_dc900mapped_pnr600_defconfig  Preserve the DC mapping for 600 MHz P&R' \
	  '  make rdtc_v1_45nm_dc900mapped_pnr600_spice_sram_defconfig  Re-run 600 MHz P&R with SPICE-characterized SRAM timing' \
	  '  make rdtc_v1_45nm_dc900mapped_pnr350_spice_sram_defconfig  Close a 350 MHz baseline with SPICE-characterized SRAM timing' \
	  '  make rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_defconfig  Close a 333 MHz SRAM run with cap/slew guardbands' \
	  '  make rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_eco1_defconfig  Select the reviewed 333 MHz active-DRC ECO' \
	  '  make rdtc_v1_45nm_dc900mapped_pnr550_defconfig  Preserve the DC mapping for 550 MHz P&R' \
	  '  make rdtc_v1_45nm_dc900mapped_pnr500_defconfig  Preserve the DC mapping for 500 MHz P&R' \
	  '  make rdtc_v1_90nm_defconfig   Create the compatible TSMC90 RF partial profile' \
	  '  make rdtc_v1_tsmc90_rf64x128_partial_defconfig  Select the exact 64x128 RF profile' \
	  '  make rdtc_v1_tsmc90_sram128x128_partial_defconfig  Select the overprovisioned SRAM profile' \
	  '  make rdtc_v1_sky130_macro_100m_defconfig  Create the SKY130 closure profile' \
	  '  make rdtc_v1_register_<node>_<freq>_defconfig  Select a tracked register-expanded DC or physical profile' \
	  '  make menuconfig                Edit .config with a Kconfig mconf frontend' \
	  '  make showconfig                Display selected profile and stages' \
	  '  make validate-profile          Validate profile, claim, evidence, and config consistency' \
	  '  make public-preflight          Run the complete open-source release preflight' \
	  '  make rtl-smoke                 Elaborate the selected top with Icarus' \
	  '  make sim                       Run the bounded Questa/ModelSim smoke suite' \
	  '  make sim-full                  Run the extended RTL regression matrix' \
	  '  make <stage>-dry-run           Show one tool invocation without running it' \
	  '  make <stage>                   Run an enabled stage using flows/local setup' \
	  '  make timing-audit              Parse existing DC/PT reports using local audit paths' \
	  '  make pnr-floorplan             Run ICC2 import/floorplan/macro/PG only' \
	  '  make pnr-full                  Force ICC2 full mode; fails closed without audited RC' \
	  '  make selected[-dry-run]        Run all stages enabled in .config' \
	  '' \
	  'Stages: lib-prep sram-prep rc-prep sim lint cdc dc-baseline dc-gated dft lec icc2-libs pnr sta' \
	  'Local PDK, library, macro, and tool setup belongs in flows/local/ (ignored).'

defconfig rdtc_v1_public_preflight_defconfig:
	@$(FLOWCTL) defconfig --source "$(DEFCONFIG)"

rdtc_v1_45nm_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_defconfig

rdtc_v1_register_%_defconfig:
	@$(FLOWCTL) defconfig --source "configs/$@"

rdtc_v1_45nm_holdfix_400m_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_holdfix_400m_defconfig

rdtc_v1_45nm_dc900_pnr800_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900_pnr800_defconfig

rdtc_v1_45nm_dc900_pnr700_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900_pnr700_defconfig

rdtc_v1_45nm_dc900_pnr650_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900_pnr650_defconfig

rdtc_v1_45nm_dc900_pnr650_guardband_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900_pnr650_guardband_defconfig

rdtc_v1_45nm_dc900mapped_pnr700_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900mapped_pnr700_defconfig

rdtc_v1_45nm_dc900mapped_pnr600_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900mapped_pnr600_defconfig

rdtc_v1_45nm_dc900mapped_pnr600_spice_sram_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900mapped_pnr600_spice_sram_defconfig

rdtc_v1_45nm_dc900mapped_pnr350_spice_sram_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900mapped_pnr350_spice_sram_defconfig

rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_defconfig

rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_eco1_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_eco1_defconfig

rdtc_v1_45nm_dc900mapped_pnr550_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900mapped_pnr550_defconfig

rdtc_v1_45nm_dc900mapped_pnr500_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_45nm_dc900mapped_pnr500_defconfig

rdtc_v1_90nm_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_90nm_defconfig

rdtc_v1_tsmc90_rf64x128_partial_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_tsmc90_rf64x128_partial_defconfig

rdtc_v1_tsmc90_sram128x128_partial_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_tsmc90_sram128x128_partial_defconfig

rdtc_v1_sky130_registers_100m_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_sky130_registers_100m_defconfig

rdtc_v1_sky130_macro_100m_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_sky130_macro_100m_defconfig

rdtc_v1_sky130_macro_200m_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_sky130_macro_200m_defconfig

rdtc_v1_sky130_macro_400m_defconfig:
	@$(FLOWCTL) defconfig --source configs/rdtc_v1_sky130_macro_400m_defconfig

menuconfig:
	@test -f "$(CONFIG)" || $(FLOWCTL) defconfig --source "$(DEFCONFIG)"
	@command -v "$(KCONFIG_MCONF)" >/dev/null 2>&1 || { \
	  echo "Kconfig frontend not found. Install mconf/kconfig-frontends or set KCONFIG_MCONF=/path/to/frontend."; \
	  exit 2; \
	}
	@KCONFIG_CONFIG="$(abspath $(CONFIG))" "$(KCONFIG_MCONF)" Kconfig

showconfig:
	@$(FLOWCTL) show-config

validate-profile:
	@$(PROFILE_VALIDATOR)

verify-checksums:
	@$(CHECKSUM_GENERATOR) --ref "$(RELEASE_REF)" --check

verify-release:
	@$(RELEASE_VERIFIER) --ref "$(RELEASE_REF)"

public-preflight:
	@$(MAKE) showconfig
	@$(MAKE) -C ref_model/c test
	@$(MAKE) rtl-smoke
	@$(PROFILE_VALIDATOR)
	@$(CHECKSUM_GENERATOR) --ref "$(RELEASE_REF)" --check
	@$(PYTHON) -m unittest flows/scripts/test_flowctl_primetime.py flows/scripts/test_validate_profile.py provenance/test_verify_release.py -v
	@$(PYTHON) flows/scripts/check_public_docs.py
	@$(PYTHON) flows/scripts/scan_public_release.py --ref HEAD

list-stages:
	@$(FLOWCTL) list-stages

lib-prep:
	@$(FLOWCTL) run --stage lib-prep

lib-prep-dry-run:
	@$(FLOWCTL) run --stage lib-prep --dry-run

sram-model-smoke:
	@$(RDTC_TOOL_PYTHON) flows/scripts/sram_model_smoke.py --root "$(ROOT)"

sram-prep:
	@$(FLOWCTL) run --stage sram-prep

sram-prep-dry-run:
	@$(FLOWCTL) run --stage sram-prep --dry-run

rc-itf:
	@$(RDTC_TOOL_PYTHON) flows/scripts/freepdk45_rc_prepare.py --itf-only

rc-prep:
	@$(FLOWCTL) run --stage rc-prep

rc-prep-dry-run:
	@$(FLOWCTL) run --stage rc-prep --dry-run

icc2-libs:
	@$(FLOWCTL) run --stage icc2-libs

icc2-libs-dry-run:
	@$(FLOWCTL) run --stage icc2-libs --dry-run

rtl-smoke:
	@$(PYTHON) flows/scripts/rtl_smoke.py --root "$(ROOT)" --filelist "$(RDTC_FILELIST)" --top "$(if $(RDTC_TOP),$(RDTC_TOP),mrtc_rdtc_wb_wrapper)"

sim:
	@$(FLOWCTL) run --stage sim

sim-dry-run:
	@$(FLOWCTL) run --stage sim --dry-run

sim-full:
	@$(PYTHON) flows/scripts/rtl_regression.py --root "$(ROOT)" --filelist "$(RDTC_FILELIST)" --suite full

selected:
	@$(FLOWCTL) run-selected

selected-dry-run:
	@$(FLOWCTL) run-selected --dry-run

lint:
	@$(FLOWCTL) run --stage lint

lint-dry-run:
	@$(FLOWCTL) run --stage lint --dry-run

cdc:
	@$(FLOWCTL) run --stage cdc

cdc-dry-run:
	@$(FLOWCTL) run --stage cdc --dry-run

dc-baseline:
	@$(FLOWCTL) run --stage dc-baseline

dc-baseline-dry-run:
	@$(FLOWCTL) run --stage dc-baseline --dry-run

dc-gated:
	@$(FLOWCTL) run --stage dc-gated

dc-gated-dry-run:
	@$(FLOWCTL) run --stage dc-gated --dry-run

dft:
	@$(FLOWCTL) run --stage dft

dft-dry-run:
	@$(FLOWCTL) run --stage dft --dry-run

lec:
	@$(FLOWCTL) run --stage lec

lec-dry-run:
	@$(FLOWCTL) run --stage lec --dry-run

pnr:
	@$(FLOWCTL) run --stage pnr

pnr-full:
	@RDTC_PNR_SCOPE=full $(FLOWCTL) run --stage pnr

pnr-floorplan:
	@RDTC_PNR_SCOPE=floorplan_only $(FLOWCTL) run --stage pnr

pnr-dry-run:
	@$(FLOWCTL) run --stage pnr --dry-run

sta:
	@$(FLOWCTL) run --stage sta

sta-dry-run:
	@$(FLOWCTL) run --stage sta --dry-run

timing-audit:
	@test -n "$(RDTC_AUDIT_DC_ROOT)" || { echo 'RDTC_AUDIT_DC_ROOT is required'; exit 2; }
	@test -n "$(RDTC_AUDIT_PT_RUNS)" || { echo 'RDTC_AUDIT_PT_RUNS is required'; exit 2; }
	@$(PYTHON) flows/scripts/timing_audit.py \
	  --dc-root "$(RDTC_AUDIT_DC_ROOT)" \
	  $(foreach run,$(RDTC_AUDIT_PT_RUNS),--pt "$(run)") \
	  $(foreach run,$(RDTC_AUDIT_OPENROAD_RUNS),--openroad "$(run)") \
	  $(foreach copy,$(RDTC_AUDIT_DC_NETLIST_COPIES),--dc-netlist-copy "$(copy)") \
	  $(foreach report,$(RDTC_AUDIT_LIBRARY_REPORTS),--library-report "$(report)") \
	  --output "$(RDTC_BUILD_ROOT)/timing_audit/audit.json" \
	  --markdown "$(RDTC_BUILD_ROOT)/timing_audit/audit.md"
