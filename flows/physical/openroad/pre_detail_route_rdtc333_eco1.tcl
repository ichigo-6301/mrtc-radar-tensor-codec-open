if {![info exists ::env(RDTC_TARGETED_DRC_ECO)] ||
    $::env(RDTC_TARGETED_DRC_ECO) ne "rdtc333_spice_eco1"} {
  error "rdtc333_spice_eco1 was sourced without its matching profile"
}

foreach eco_cell [get_cells -quiet {rdtc_eco_slew_buf_* rdtc_eco_cap_buf}] {
  error "rdtc333_spice_eco1 cannot be applied twice: $eco_cell already exists"
}

global_route -start_incremental

set target_load_pins [list \
  {u_dual_core/u_lane0/u_engine/u_prefix_sample_buffer/u_sram/addr0[3]} \
  {u_dual_core/u_lane0/u_engine/u_prefix_sample_buffer/u_sram/addr0[0]} \
  {u_dual_core/u_lane0/u_engine/u_prefix_sample_buffer/u_sram/addr0[4]} \
  {u_dual_core/u_lane1/u_engine/u_prefix_sample_buffer/u_sram/addr0[5]} \
  {u_dual_core/u_lane1/u_engine/u_prefix_sample_buffer/u_sram/addr1[5]} \
  {u_dual_core/u_lane1/u_engine/u_prefix_sample_buffer/u_sram/addr0[1]}]

set index 0
foreach pin_name $target_load_pins {
  set load_pin [get_pins -quiet $pin_name]
  if {[llength $load_pin] != 1} {
    error "Expected one ECO load pin: $pin_name"
  }
  insert_buffer \
    -buffer_cell BUF_X8 \
    -load_pins $load_pin \
    -buffer_name rdtc_eco_slew_buf_$index \
    -net_name rdtc_eco_slew_net_$index
  incr index
}

# This driver name belongs to the pinned 333 MHz guardband profile. Fail closed
# if mapping or placement changes instead of silently applying a different ECO.
set cap_driver [get_pins -quiet \
  {u_dual_core/u_lane0/u_engine/u_rice_bitpacker_lane_axis/place12718/Z}]
if {[llength $cap_driver] != 1} {
  error "Expected one ECO max-cap driver"
}
set cap_net [get_nets -quiet -of_objects $cap_driver]
if {[llength $cap_net] != 1} {
  error "Expected one ECO max-cap net"
}
insert_buffer \
  -buffer_cell BUF_X8 \
  -net $cap_net \
  -buffer_name rdtc_eco_cap_buf \
  -net_name rdtc_eco_cap_net

detailed_placement
global_route -end_incremental \
  -guide_file $::env(RESULTS_DIR)/route.guide \
  -congestion_report_file $::env(REPORTS_DIR)/congestion_post_rdtc333_eco1.rpt
estimate_parasitics -global_routing
report_check_types \
  -violators -max_capacitance -max_slew -digits 4 -max_count 1000 \
  > $::env(REPORTS_DIR)/rdtc333_eco1_drc.rpt
puts "RDTC targeted DRC ECO inserted 7 BUF_X8 cells"
