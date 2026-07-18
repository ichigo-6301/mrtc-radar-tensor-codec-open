if {![info exists ::env(RDTC_POST_GRT_HOLD_REPAIR_PASSES)]} {
  error "RDTC_POST_GRT_HOLD_REPAIR_PASSES is required"
}
if {![info exists ::env(RDTC_POST_GRT_HOLD_SLACK_MARGIN_NS)]} {
  error "RDTC_POST_GRT_HOLD_SLACK_MARGIN_NS is required"
}

set rdtc_hold_repair_passes $::env(RDTC_POST_GRT_HOLD_REPAIR_PASSES)
if {![string is integer -strict $rdtc_hold_repair_passes] || $rdtc_hold_repair_passes < 1} {
  error "RDTC_POST_GRT_HOLD_REPAIR_PASSES must be a positive integer"
}

set rdtc_original_hold_margin $::env(HOLD_SLACK_MARGIN)
set ::env(HOLD_SLACK_MARGIN) $::env(RDTC_POST_GRT_HOLD_SLACK_MARGIN_NS)

for {set pass 1} {$pass <= $rdtc_hold_repair_passes} {incr pass} {
  puts "RDTC post-GRT hold repair pass $pass/$rdtc_hold_repair_passes"
  log_cmd estimate_parasitics -global_routing
  log_cmd global_route -start_incremental
  repair_timing_helper
  log_cmd detailed_placement
  log_cmd global_route -end_incremental \
    -congestion_report_file "$::env(REPORTS_DIR)/congestion_post_hold_repair_${pass}.rpt"
}

log_cmd estimate_parasitics -global_routing
report_metrics 5 "post global route hold repair"
write_guides $::env(RESULTS_DIR)/route.guide
set ::env(HOLD_SLACK_MARGIN) $rdtc_original_hold_margin
