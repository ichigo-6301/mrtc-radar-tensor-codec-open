proc require_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "Missing required environment variable: $name"
  }
  return $::env($name)
}

proc require_file {path label} {
  if {![file isfile $path]} {
    error "Missing $label: $path"
  }
}

set build_root [require_env RDTC_BUILD_ROOT]
set top [require_env RDTC_TOP]
source [require_env RDTC_PRIMETIME_SETUP]

set output_dir "$build_root/primetime"
file mkdir $output_dir

set required_inputs [list \
  $rdtc_stdcell_db "standard-cell DB" \
  $rdtc_postroute_netlist "post-route netlist" \
  $rdtc_postroute_sdc "post-route SDC" \
  $rdtc_postroute_spef "post-route SPEF"]
if {[info exists rdtc_sram_db] && $rdtc_sram_db ne ""} {
  lappend required_inputs $rdtc_sram_db "SRAM DB"
}
foreach {path label} $required_inputs {
  require_file $path $label
}

set timing_libraries [list $rdtc_stdcell_db]
if {[info exists rdtc_sram_db] && $rdtc_sram_db ne ""} {
  lappend timing_libraries $rdtc_sram_db
}
set library_paths [list]
foreach library $timing_libraries {
  lappend library_paths [file dirname $library]
}
set_app_var search_path [concat $library_paths [get_app_var search_path]]
set_app_var target_library [list $rdtc_stdcell_db]
set_app_var link_path [concat "*" $timing_libraries]
read_verilog $rdtc_postroute_netlist
current_design $top
if {![link_design $top]} {
  error "PrimeTime link_design failed"
}
if {[catch {read_sdc $rdtc_postroute_sdc} message]} {
  error "PrimeTime read_sdc failed: $message"
}
set expected_clock_period [require_env RDTC_CLOCK_PERIOD_NS]
set rdtc_clocks [get_clocks -quiet rdtc_clk]
if {[sizeof_collection $rdtc_clocks] != 1} {
  error "PrimeTime expected exactly one rdtc_clk after reading the post-route SDC"
}
set actual_clock_period [get_attribute $rdtc_clocks period]
if {[expr {abs($actual_clock_period - $expected_clock_period)}] > 0.0001} {
  error "PrimeTime clock-period mismatch: expected $expected_clock_period ns, got $actual_clock_period ns"
}
if {[catch {read_parasitics $rdtc_postroute_spef} message]} {
  error "PrimeTime read_parasitics failed: $message"
}

redirect -file "$output_dir/check_timing.rpt" {check_timing -verbose}
update_timing
if {[sizeof_collection [get_clocks -quiet *]] == 0} {
  error "PrimeTime has no clocks after reading the post-route SDC"
}
if {[sizeof_collection [all_registers -clock_pins]] == 0} {
  error "PrimeTime linked no clocked registers"
}
redirect -file "$output_dir/setup_timing.rpt" {report_timing -delay_type max -slack_lesser_than 999 -max_paths 20}
redirect -file "$output_dir/hold_timing.rpt" {report_timing -delay_type min -slack_lesser_than 999 -max_paths 20}
redirect -file "$output_dir/setup_summary.rpt" {report_global_timing -delay_type max}
redirect -file "$output_dir/hold_summary.rpt" {report_global_timing -delay_type min}
redirect -file "$output_dir/constraint_violations.rpt" {report_constraint -all_violators}
redirect -file "$output_dir/analysis_coverage.rpt" {report_analysis_coverage}
redirect -file "$output_dir/qor.rpt" {report_qor}
puts "INFO: PrimeTime post-route STA completed"
quit
