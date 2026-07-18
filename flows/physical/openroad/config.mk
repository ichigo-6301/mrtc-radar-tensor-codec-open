export PLATFORM = $(RDTC_ORFS_PLATFORM)
export DESIGN_NICKNAME = rdtc_v1
export DESIGN_NAME = $(RDTC_TOP)

# Preserve the macro-aware Design Compiler mapping. ORFS copies this gate-level
# netlist into its synthesis handoff and skips Yosys/ABC remapping.
export SYNTH_NETLIST_FILES = $(RDTC_DC_HANDOFF_ROOT)/dc_baseline/$(RDTC_TOP)_baseline.v
export VERILOG_FILES =
# Re-apply the implementation-period constraint to the faster synthesized
# netlist. The DC-generated SDC remains in the build for handoff auditing.
export SDC_FILE = $(RDTC_SDC)
RDTC_HOLD_SLACK_MARGIN_NS ?= -0.05
RDTC_SETUP_SLACK_MARGIN_NS ?= 0.00
RDTC_GRT_HOLD_SLACK_MARGIN_NS ?=
RDTC_POST_GRT_HOLD_REPAIR_PASSES ?= 0

ifneq ($(RDTC_POST_GRT_HOLD_REPAIR_PASSES),0)
export POST_GLOBAL_ROUTE_TCL = $(RDTC_FLOW_ROOT)/flows/physical/openroad/post_global_route_hold_repair.tcl
endif

ifneq ($(RDTC_GRT_HOLD_SLACK_MARGIN_NS),)
export PRE_GLOBAL_ROUTE_TCL = $(RDTC_FLOW_ROOT)/flows/physical/openroad/pre_global_route_hold_margin.tcl
endif

ifeq ($(RDTC_MEMORY_MODE),macro)
export ADDITIONAL_LEFS = $(RDTC_SRAM_LEF)
export ADDITIONAL_LIBS = $(RDTC_SRAM_LIB)
export ADDITIONAL_GDS = $(RDTC_SRAM_GDS)
export MACRO_PLACE_HALO = 40 40
export MACRO_PLACEMENT_TCL = $(RDTC_FLOW_ROOT)/flows/physical/openroad/macro_placement.tcl
export PRE_PDN_TCL = $(RDTC_FLOW_ROOT)/flows/physical/openroad/pdn_macro_connect.tcl
endif

ifeq ($(PLATFORM),sky130hd)
export DIE_AREA = 0 0 3000 3000
export CORE_AREA = 25 25 2975 2975
export PLACE_DENSITY = 0.45
export MIN_ROUTING_LAYER = met1
export MIN_CLK_ROUTING_LAYER = met3
export MAX_ROUTING_LAYER = met5
export TNS_END_PERCENT = 100
export SETUP_SLACK_MARGIN = $(RDTC_SETUP_SLACK_MARGIN_NS)
export HOLD_SLACK_MARGIN = $(RDTC_HOLD_SLACK_MARGIN_NS)
else
export DIE_AREA = 0 0 1200 1200
export CORE_AREA = 20.14 22.4 1179.86 1177.6
export PLACE_DENSITY = 0.55
export MACRO_PLACE_HALO = 20 20
export MIN_ROUTING_LAYER = metal2
export MIN_CLK_ROUTING_LAYER = metal4
export MAX_ROUTING_LAYER = metal10
export TNS_END_PERCENT = 100
export SETUP_SLACK_MARGIN = $(RDTC_SETUP_SLACK_MARGIN_NS)
# Keep the baseline at -50 ps while allowing an isolated profile to request
# zero-slack physical hold closure without changing the synthesis constraint.
export HOLD_SLACK_MARGIN = $(RDTC_HOLD_SLACK_MARGIN_NS)
ifneq ($(strip $(RDTC_CAP_MARGIN_PERCENT)),)
export CAP_MARGIN = $(RDTC_CAP_MARGIN_PERCENT)
endif
ifneq ($(strip $(RDTC_SLEW_MARGIN_PERCENT)),)
export SLEW_MARGIN = $(RDTC_SLEW_MARGIN_PERCENT)
endif
ifneq ($(strip $(RDTC_TARGETED_DRC_ECO)),)
ifeq ($(RDTC_TARGETED_DRC_ECO),rdtc333_spice_eco1)
export PRE_DETAIL_ROUTE_TCL = $(RDTC_FLOW_ROOT)/flows/physical/openroad/pre_detail_route_rdtc333_eco1.tcl
else
$(error Unsupported RDTC_TARGETED_DRC_ECO=$(RDTC_TARGETED_DRC_ECO))
endif
endif
ifeq ($(RDTC_MEMORY_MODE),macro)
export GDS_ALLOW_EMPTY = $(RDTC_SRAM_MACRO)
endif
endif
