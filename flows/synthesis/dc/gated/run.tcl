proc require_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "Missing required environment variable: $name"
  }
  return $::env($name)
}

set filelist [require_env RDTC_FILELIST]
set top [require_env RDTC_TOP]
set sdc [require_env RDTC_SDC]
set build_root [require_env RDTC_BUILD_ROOT]
source [require_env RDTC_DC_SETUP]

if {![info exists RDTC_CLOCK_GATING_STYLE]} {
  error "RDTC_CLOCK_GATING_STYLE must be defined by the local DC setup after an ICG and test-enable audit"
}

set output_dir "$build_root/dc_gated"
file mkdir $output_dir
analyze -format sverilog -f $filelist
elaborate $top
link
source $sdc
eval set_clock_gating_style $RDTC_CLOCK_GATING_STYLE
compile_ultra -gate_clock
check_design > "$output_dir/check_design.rpt"
report_clock_gating > "$output_dir/clock_gating.rpt"
report_area -hierarchy > "$output_dir/area_hier.rpt"
report_timing -max_paths 20 > "$output_dir/timing.rpt"
report_qor > "$output_dir/qor.rpt"
write -format verilog -hierarchy -output "$output_dir/${top}_gated.v"
write_sdc "$output_dir/${top}_gated.sdc"
write -format ddc -hierarchy -output "$output_dir/${top}_gated.ddc"
