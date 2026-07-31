set rdtc_eco_name direct_sram_pt300_electrical_eco1
if {![info exists ::env(RDTC_TARGETED_DRC_ECO)] ||
    $::env(RDTC_TARGETED_DRC_ECO) ne $rdtc_eco_name} {
  error "$rdtc_eco_name was sourced without its matching profile"
}
foreach rdtc_required_env {
  RDTC_DIRECT_ECO_POLICY_SHA256
  RDTC_DIRECT_ECO_HOOK_SHA256
  RDTC_DIRECT_ECO_RESUME_MANIFEST_SHA256
  RDTC_DIRECT_ECO_PARENT_GRT_ODB_SHA256
  RDTC_DIRECT_ECO_PARENT_GRT_SDC_SHA256
  RDTC_DIRECT_ECO_PARENT_ROUTE_GUIDE_SHA256
} {
  if {![info exists ::env($rdtc_required_env)] ||
      ![regexp {^[0-9a-f]{64}$} $::env($rdtc_required_env)]} {
    error "$rdtc_eco_name requires a valid $rdtc_required_env"
  }
}
set rdtc_hook_sha256 [lindex [split [exec sha256sum -- [info script]]] 0]
if {$rdtc_hook_sha256 ne $::env(RDTC_DIRECT_ECO_HOOK_SHA256)} {
  error "$rdtc_eco_name live hook SHA256 mismatch"
}

set rdtc_block [ord::get_db_block]
set rdtc_dbu_per_micron [$rdtc_block getDbUnitsPerMicron]
set rdtc_halo_dbu [expr {round(20.0 * $rdtc_dbu_per_micron)}]
set rdtc_channel_dbu [expr {round(60.0 * $rdtc_dbu_per_micron)}]
set rdtc_addr_offset_dbu [expr {round(30.0 * $rdtc_dbu_per_micron)}]
set rdtc_dout_offset_dbu [expr {round(22.0 * $rdtc_dbu_per_micron)}]
set rdtc_side_tolerance_dbu [expr {round(0.2 * $rdtc_dbu_per_micron)}]
set rdtc_pin_x_tolerance_dbu [expr {round(10.0 * $rdtc_dbu_per_micron)}]
set rdtc_ring_master mrtc_rdtc_bounded_ring_1rw_32x128

set rdtc_addr_targets [list \
  [list {g_engine[1].u_engine/u_way_ring/g_way[3].u_way/u_sram/addr0[2]} rdtc_direct_eco_addr_buf_00 top {g_engine[1].u_engine/place14478/Z} BUF_X8 OUTPUT] \
  [list {g_engine[1].u_engine/u_way_ring/g_way[2].u_way/u_sram/addr0[3]} rdtc_direct_eco_addr_buf_01 top {g_engine[1].u_engine/wire21058/Z} BUF_X2 OUTPUT] \
  [list {g_engine[1].u_engine/u_way_ring/g_way[2].u_way/u_sram/addr0[4]} rdtc_direct_eco_addr_buf_02 top {g_engine[1].u_engine/wire21117/Z} BUF_X2 OUTPUT] \
  [list {g_engine[1].u_engine/u_way_ring/g_way[0].u_way/u_sram/addr0[4]} rdtc_direct_eco_addr_buf_03 top {g_engine[1].u_engine/wire21210/Z} BUF_X4 OUTPUT] \
  [list {g_engine[1].u_engine/u_way_ring/g_way[2].u_way/u_sram/addr0[2]} rdtc_direct_eco_addr_buf_04 top {g_engine[1].u_engine/place14474/Z} BUF_X2 OUTPUT] \
  [list {g_engine[0].u_engine/u_way_ring/g_way[2].u_way/u_sram/addr0[0]} rdtc_direct_eco_addr_buf_05 bottom {g_engine[0].u_engine/wire21156/Z} CLKBUF_X3 OUTPUT] \
  [list {g_engine[1].u_engine/u_way_ring/g_way[2].u_way/u_sram/addr0[1]} rdtc_direct_eco_addr_buf_06 top {g_engine[1].u_engine/wire21118/Z} BUF_X1 OUTPUT] \
  [list {g_engine[1].u_engine/u_way_ring/g_way[0].u_way/u_sram/addr0[0]} rdtc_direct_eco_addr_buf_07 bottom {g_engine[1].u_engine/U1223/ZN} OAI22_X1 OUTPUT] \
  [list {g_engine[0].u_engine/u_way_ring/g_way[3].u_way/u_sram/addr0[0]} rdtc_direct_eco_addr_buf_08 bottom {g_engine[0].u_engine/place14503/Z} BUF_X8 OUTPUT] \
  [list {g_engine[0].u_engine/u_way_ring/g_way[1].u_way/u_sram/addr0[3]} rdtc_direct_eco_addr_buf_09 top {g_engine[0].u_engine/U1225/ZN} OAI22_X1 OUTPUT] \
  [list {g_engine[0].u_engine/u_way_ring/g_way[3].u_way/u_sram/addr0[4]} rdtc_direct_eco_addr_buf_10 top {g_engine[0].u_engine/place14499/Z} BUF_X8 OUTPUT]]
set rdtc_dout_targets [list \
  [list {g_engine[0].u_engine/u_way_ring/g_way[1].u_way/u_sram/dout0[88]} rdtc_direct_eco_dout_buf_00 bottom {g_engine[0].u_engine/wire33563/A} BUF_X2 INPUT] \
  [list {g_engine[0].u_engine/u_way_ring/g_way[1].u_way/u_sram/dout0[45]} rdtc_direct_eco_dout_buf_01 bottom {g_engine[0].u_engine/wire33570/A} BUF_X2 INPUT] \
  [list {g_engine[1].u_engine/u_way_ring/g_way[1].u_way/u_sram/dout0[43]} rdtc_direct_eco_dout_buf_02 bottom {g_engine[1].u_engine/wire33398/A} BUF_X2 INPUT]]

if {[llength $rdtc_addr_targets] != 11 || [llength $rdtc_dout_targets] != 3} {
  error "$rdtc_eco_name target cardinality mismatch"
}
foreach rdtc_existing [$rdtc_block getInsts] {
  set rdtc_existing_name [$rdtc_existing getName]
  if {[string match {*rdtc_direct_eco_addr_buf_*} $rdtc_existing_name] ||
      [string match {*rdtc_direct_eco_dout_buf_*} $rdtc_existing_name]} {
    error "$rdtc_eco_name cannot be applied twice: $rdtc_existing_name already exists"
  }
}
if {![grt::have_routes]} {
  error "$rdtc_eco_name requires the bound 5_1_grt checkpoint"
}

proc rdtc_eco_exact_pin {rdtc_pin_name} {
  set rdtc_pin [get_pins -quiet $rdtc_pin_name]
  if {[llength $rdtc_pin] != 1} {
    error "Expected one ECO target pin $rdtc_pin_name, found [llength $rdtc_pin]"
  }
  return $rdtc_pin
}

proc rdtc_eco_target_location {
    rdtc_pin rdtc_side rdtc_dbu_per_micron rdtc_offset_dbu
    rdtc_side_tolerance_dbu rdtc_ring_master} {
  set rdtc_iterm [sta::sta_to_db_pin $rdtc_pin]
  if {$rdtc_iterm eq "NULL"} {
    error "ECO target is not an instance terminal: $rdtc_pin"
  }
  set rdtc_inst [$rdtc_iterm getInst]
  if {[[$rdtc_inst getMaster] getName] ne $rdtc_ring_master} {
    error "ECO target does not belong to the bounded ring SRAM: $rdtc_pin"
  }
  lassign [$rdtc_iterm getAvgXY] rdtc_pin_ok rdtc_pin_x rdtc_pin_y
  if {!$rdtc_pin_ok} {
    error "Cannot resolve physical location for ECO target: $rdtc_pin"
  }
  set rdtc_bbox [$rdtc_inst getBBox]
  if {$rdtc_side eq "top"} {
    if {[expr {abs($rdtc_pin_y - [$rdtc_bbox yMax])}] > $rdtc_side_tolerance_dbu} {
      error "ECO target is not on the expected top edge: $rdtc_pin"
    }
    set rdtc_target_y [expr {[$rdtc_bbox yMax] + $rdtc_offset_dbu}]
  } elseif {$rdtc_side eq "bottom"} {
    if {[expr {abs($rdtc_pin_y - [$rdtc_bbox yMin])}] > $rdtc_side_tolerance_dbu} {
      error "ECO target is not on the expected bottom edge: $rdtc_pin"
    }
    set rdtc_target_y [expr {[$rdtc_bbox yMin] - $rdtc_offset_dbu}]
  } else {
    error "Unsupported ECO target side: $rdtc_side"
  }
  return [list \
    [expr {double($rdtc_pin_x) / $rdtc_dbu_per_micron}] \
    [expr {double($rdtc_target_y) / $rdtc_dbu_per_micron}] \
    $rdtc_iterm $rdtc_pin_x $rdtc_pin_y]
}

proc rdtc_eco_inst_state {rdtc_inst} {
  set rdtc_bbox [$rdtc_inst getBBox]
  return [list \
    [$rdtc_bbox xMin] [$rdtc_bbox yMin] \
    [$rdtc_bbox xMax] [$rdtc_bbox yMax] \
    [$rdtc_inst getOrient] [$rdtc_inst getPlacementStatus]]
}

proc rdtc_eco_signal_endpoints {rdtc_net} {
  set rdtc_endpoints {}
  foreach rdtc_iterm [$rdtc_net getITerms] {
    set rdtc_mterm [$rdtc_iterm getMTerm]
    if {[$rdtc_mterm getSigType] eq "SIGNAL"} {
      lappend rdtc_endpoints [list \
        [[$rdtc_iterm getInst] getName] \
        [$rdtc_mterm getName] \
        [[[$rdtc_iterm getInst] getMaster] getName] \
        [$rdtc_mterm getIoType]]
    }
  }
  foreach rdtc_bterm [$rdtc_net getBTerms] {
    if {[$rdtc_bterm getSigType] eq "SIGNAL"} {
      lappend rdtc_endpoints [list \
        PORT [$rdtc_bterm getName] - [$rdtc_bterm getIoType]]
    }
  }
  return [lsort $rdtc_endpoints]
}

proc rdtc_eco_verify_parent_topology {
    rdtc_target_iterm rdtc_peer_pin rdtc_peer_master rdtc_peer_io
    rdtc_target_io rdtc_target_master} {
  set rdtc_peer_iterm [sta::sta_to_db_pin $rdtc_peer_pin]
  if {$rdtc_peer_iterm eq "NULL"} {
    error "ECO parent peer is not an instance terminal: $rdtc_peer_pin"
  }
  set rdtc_peer_mterm [$rdtc_peer_iterm getMTerm]
  if {[[[$rdtc_peer_iterm getInst] getMaster] getName] ne $rdtc_peer_master ||
      [$rdtc_peer_mterm getIoType] ne $rdtc_peer_io} {
    error "ECO parent peer identity mismatch: $rdtc_peer_pin"
  }
  set rdtc_target_net [$rdtc_target_iterm getNet]
  if {$rdtc_target_net eq "NULL" || [$rdtc_peer_iterm getNet] ne $rdtc_target_net} {
    error "ECO parent target and peer do not share one net"
  }
  set rdtc_target_mterm [$rdtc_target_iterm getMTerm]
  set rdtc_expected [lsort [list \
    [list [[$rdtc_target_iterm getInst] getName] \
      [$rdtc_target_mterm getName] $rdtc_target_master $rdtc_target_io] \
    [list [[$rdtc_peer_iterm getInst] getName] \
      [$rdtc_peer_mterm getName] $rdtc_peer_master $rdtc_peer_io]]]
  if {[rdtc_eco_signal_endpoints $rdtc_target_net] ne $rdtc_expected} {
    error "ECO parent net endpoint set drifted"
  }
  return $rdtc_peer_iterm
}

array set rdtc_target_pin_by_buffer {}
array set rdtc_target_side_by_buffer {}
array set rdtc_target_x_by_buffer {}
array set rdtc_target_kind_by_buffer {}
array set rdtc_buffer_inst_by_buffer {}
array set rdtc_peer_iterm_by_buffer {}
array set rdtc_parent_inst_state {}

foreach rdtc_parent_inst [$rdtc_block getInsts] {
  set rdtc_parent_name [$rdtc_parent_inst getName]
  set rdtc_parent_inst_state($rdtc_parent_name) \
    [rdtc_eco_inst_state $rdtc_parent_inst]
}

global_route -start_incremental

foreach rdtc_target $rdtc_addr_targets {
  lassign $rdtc_target \
    rdtc_pin_name rdtc_buffer_name rdtc_side \
    rdtc_peer_pin_name rdtc_peer_master rdtc_peer_io
  set rdtc_pin [rdtc_eco_exact_pin $rdtc_pin_name]
  set rdtc_location [rdtc_eco_target_location \
    $rdtc_pin $rdtc_side $rdtc_dbu_per_micron $rdtc_addr_offset_dbu \
    $rdtc_side_tolerance_dbu $rdtc_ring_master]
  set rdtc_peer_pin [rdtc_eco_exact_pin $rdtc_peer_pin_name]
  set rdtc_peer_iterm_by_buffer($rdtc_buffer_name) \
    [rdtc_eco_verify_parent_topology \
      [lindex $rdtc_location 2] $rdtc_peer_pin \
      $rdtc_peer_master $rdtc_peer_io INPUT $rdtc_ring_master]
  set rdtc_inserted [insert_buffer \
    -buffer_cell BUF_X4 \
    -load_pins $rdtc_pin \
    -location [lrange $rdtc_location 0 1] \
    -buffer_name $rdtc_buffer_name \
    -net_name ${rdtc_buffer_name}_net]
  set rdtc_actual_name [get_name $rdtc_inserted]
  if {![regexp [format {(^|/)%s[0-9]*$} $rdtc_buffer_name] $rdtc_actual_name]} {
    error "Inserted ECO buffer lost its bound basename: $rdtc_actual_name"
  }
  set rdtc_buffer_inst_by_buffer($rdtc_buffer_name) \
    [sta::sta_to_db_inst $rdtc_inserted]
  set rdtc_target_pin_by_buffer($rdtc_buffer_name) [lindex $rdtc_location 2]
  set rdtc_target_side_by_buffer($rdtc_buffer_name) $rdtc_side
  set rdtc_target_x_by_buffer($rdtc_buffer_name) [lindex $rdtc_location 3]
  set rdtc_target_kind_by_buffer($rdtc_buffer_name) addr
}

foreach rdtc_target $rdtc_dout_targets {
  lassign $rdtc_target \
    rdtc_pin_name rdtc_buffer_name rdtc_side \
    rdtc_peer_pin_name rdtc_peer_master rdtc_peer_io
  set rdtc_pin [rdtc_eco_exact_pin $rdtc_pin_name]
  set rdtc_location [rdtc_eco_target_location \
    $rdtc_pin $rdtc_side $rdtc_dbu_per_micron $rdtc_dout_offset_dbu \
    $rdtc_side_tolerance_dbu $rdtc_ring_master]
  set rdtc_peer_pin [rdtc_eco_exact_pin $rdtc_peer_pin_name]
  set rdtc_peer_iterm_by_buffer($rdtc_buffer_name) \
    [rdtc_eco_verify_parent_topology \
      [lindex $rdtc_location 2] $rdtc_peer_pin \
      $rdtc_peer_master $rdtc_peer_io OUTPUT $rdtc_ring_master]
  set rdtc_net [get_nets -quiet -of_objects $rdtc_pin]
  if {[llength $rdtc_net] != 1} {
    error "Expected one driven net for ECO target $rdtc_pin_name"
  }
  set rdtc_inserted [insert_buffer \
    -buffer_cell BUF_X1 \
    -net $rdtc_net \
    -location [lrange $rdtc_location 0 1] \
    -buffer_name $rdtc_buffer_name \
    -net_name ${rdtc_buffer_name}_net]
  set rdtc_actual_name [get_name $rdtc_inserted]
  if {![regexp [format {(^|/)%s[0-9]*$} $rdtc_buffer_name] $rdtc_actual_name]} {
    error "Inserted ECO buffer lost its bound basename: $rdtc_actual_name"
  }
  set rdtc_buffer_inst_by_buffer($rdtc_buffer_name) \
    [sta::sta_to_db_inst $rdtc_inserted]
  set rdtc_target_pin_by_buffer($rdtc_buffer_name) [lindex $rdtc_location 2]
  set rdtc_target_side_by_buffer($rdtc_buffer_name) $rdtc_side
  set rdtc_target_x_by_buffer($rdtc_buffer_name) [lindex $rdtc_location 3]
  set rdtc_target_kind_by_buffer($rdtc_buffer_name) dout
}

# Keep the parent GRT placement immutable while legalizing only the 14 new
# buffers. All original placement statuses are restored before routing.
foreach rdtc_parent_name [array names rdtc_parent_inst_state] {
  set rdtc_parent_inst [$rdtc_block findInst $rdtc_parent_name]
  if {[$rdtc_parent_inst getPlacementStatus] eq "PLACED"} {
    $rdtc_parent_inst setPlacementStatus FIRM
  }
}
detailed_placement -incremental -max_displacement {10 2}
foreach rdtc_parent_name [array names rdtc_parent_inst_state] {
  set rdtc_parent_inst [$rdtc_block findInst $rdtc_parent_name]
  if {[lindex $rdtc_parent_inst_state($rdtc_parent_name) 5] eq "PLACED"} {
    $rdtc_parent_inst setPlacementStatus PLACED
  }
  if {[rdtc_eco_inst_state $rdtc_parent_inst] ne
      $rdtc_parent_inst_state($rdtc_parent_name)} {
    error "ECO legalization moved a parent instance: $rdtc_parent_name"
  }
}
check_placement \
  -report_file_name $::env(REPORTS_DIR)/direct_sram_electrical_eco_placement.rpt
global_route -end_incremental \
  -guide_file $::env(RESULTS_DIR)/route.guide \
  -congestion_report_file $::env(REPORTS_DIR)/congestion_post_direct_sram_eco1.rpt
estimate_parasitics -global_routing

set rdtc_eco_report $::env(REPORTS_DIR)/direct_sram_electrical_eco_inserted.tsv
set rdtc_report_stream [open $rdtc_eco_report w]
puts $rdtc_report_stream "schema_version\t1"
puts $rdtc_report_stream "policy_sha256\t$::env(RDTC_DIRECT_ECO_POLICY_SHA256)"
puts $rdtc_report_stream "resume_manifest_sha256\t$::env(RDTC_DIRECT_ECO_RESUME_MANIFEST_SHA256)"
puts $rdtc_report_stream "parent_instance_count\t[llength [array names rdtc_parent_inst_state]]"
puts $rdtc_report_stream "parent_instance_moves\t0"
set rdtc_observed_buffers 0
foreach rdtc_buffer_name [lsort [array names rdtc_target_pin_by_buffer]] {
  set rdtc_buffer_inst $rdtc_buffer_inst_by_buffer($rdtc_buffer_name)
  if {$rdtc_buffer_inst eq "NULL"} {
    error "Missing inserted ECO buffer $rdtc_buffer_name"
  }
  set rdtc_buffer_bbox [$rdtc_buffer_inst getBBox]
  set rdtc_buffer_center_x [expr {([$rdtc_buffer_bbox xMin] + [$rdtc_buffer_bbox xMax]) / 2}]
  set rdtc_buffer_center_y [expr {([$rdtc_buffer_bbox yMin] + [$rdtc_buffer_bbox yMax]) / 2}]
  set rdtc_target_iterm $rdtc_target_pin_by_buffer($rdtc_buffer_name)
  set rdtc_macro_bbox [[$rdtc_target_iterm getInst] getBBox]
  set rdtc_side $rdtc_target_side_by_buffer($rdtc_buffer_name)
  if {$rdtc_side eq "top"} {
    set rdtc_channel_min [expr {[$rdtc_macro_bbox yMax] + $rdtc_halo_dbu}]
    set rdtc_channel_max [expr {[$rdtc_macro_bbox yMax] + $rdtc_channel_dbu - $rdtc_halo_dbu}]
  } else {
    set rdtc_channel_min [expr {[$rdtc_macro_bbox yMin] - $rdtc_channel_dbu + $rdtc_halo_dbu}]
    set rdtc_channel_max [expr {[$rdtc_macro_bbox yMin] - $rdtc_halo_dbu}]
  }
  if {[$rdtc_buffer_bbox yMin] < $rdtc_channel_min ||
      [$rdtc_buffer_bbox yMax] > $rdtc_channel_max ||
      [$rdtc_buffer_bbox xMin] < [$rdtc_macro_bbox xMin] ||
      [$rdtc_buffer_bbox xMax] > [$rdtc_macro_bbox xMax]} {
    error "ECO buffer escaped its reserved local channel: $rdtc_buffer_name"
  }
  if {[expr {abs($rdtc_buffer_center_x - $rdtc_target_x_by_buffer($rdtc_buffer_name))}] >
      $rdtc_pin_x_tolerance_dbu} {
    error "ECO buffer moved too far from its target pin: $rdtc_buffer_name"
  }
  set rdtc_a_iterm [$rdtc_buffer_inst findITerm A]
  set rdtc_z_iterm [$rdtc_buffer_inst findITerm Z]
  set rdtc_a_net [$rdtc_a_iterm getNet]
  set rdtc_z_net [$rdtc_z_iterm getNet]
  if {$rdtc_a_net eq "NULL" || $rdtc_z_net eq "NULL" ||
      $rdtc_a_net eq $rdtc_z_net} {
    error "ECO buffer has malformed A/Z nets: $rdtc_buffer_name"
  }
  set rdtc_kind $rdtc_target_kind_by_buffer($rdtc_buffer_name)
  set rdtc_actual_inst_name [$rdtc_buffer_inst getName]
  set rdtc_target_mterm [$rdtc_target_iterm getMTerm]
  set rdtc_peer_iterm $rdtc_peer_iterm_by_buffer($rdtc_buffer_name)
  set rdtc_peer_mterm [$rdtc_peer_iterm getMTerm]
  set rdtc_peer_endpoint [list \
    [[$rdtc_peer_iterm getInst] getName] \
    [$rdtc_peer_mterm getName] \
    [[[$rdtc_peer_iterm getInst] getMaster] getName] \
    [$rdtc_peer_mterm getIoType]]
  if {$rdtc_kind eq "addr"} {
    set rdtc_expected_z_endpoints [lsort [list \
      [list $rdtc_actual_inst_name Z BUF_X4 OUTPUT] \
      [list [[$rdtc_target_iterm getInst] getName] \
        [$rdtc_target_mterm getName] $rdtc_ring_master INPUT]]]
    set rdtc_expected_a_endpoints [lsort [list \
      [list $rdtc_actual_inst_name A BUF_X4 INPUT] \
      $rdtc_peer_endpoint]]
    if {[$rdtc_target_iterm getNet] ne $rdtc_z_net ||
        [$rdtc_peer_iterm getNet] ne $rdtc_a_net ||
        [rdtc_eco_signal_endpoints $rdtc_z_net] ne $rdtc_expected_z_endpoints ||
        [rdtc_eco_signal_endpoints $rdtc_a_net] ne $rdtc_expected_a_endpoints} {
      error "ECO address buffer topology mismatch: $rdtc_buffer_name"
    }
  } else {
    set rdtc_expected_a_endpoints [lsort [list \
      [list $rdtc_actual_inst_name A BUF_X1 INPUT] \
      [list [[$rdtc_target_iterm getInst] getName] \
        [$rdtc_target_mterm getName] $rdtc_ring_master OUTPUT]]]
    set rdtc_expected_z_endpoints [lsort [list \
      [list $rdtc_actual_inst_name Z BUF_X1 OUTPUT] \
      $rdtc_peer_endpoint]]
    if {[$rdtc_target_iterm getNet] ne $rdtc_a_net ||
        [$rdtc_peer_iterm getNet] ne $rdtc_z_net ||
        [rdtc_eco_signal_endpoints $rdtc_a_net] ne $rdtc_expected_a_endpoints ||
        [rdtc_eco_signal_endpoints $rdtc_z_net] ne $rdtc_expected_z_endpoints} {
      error "ECO dout buffer topology mismatch: $rdtc_buffer_name"
    }
  }
  puts $rdtc_report_stream [join [list \
    buffer $rdtc_buffer_name $rdtc_actual_inst_name \
    [[$rdtc_buffer_inst getMaster] getName] $rdtc_kind $rdtc_side \
    [$rdtc_buffer_bbox xMin] [$rdtc_buffer_bbox yMin] \
    [$rdtc_buffer_bbox xMax] [$rdtc_buffer_bbox yMax] \
    $rdtc_buffer_center_x $rdtc_buffer_center_y \
    [$rdtc_buffer_inst getPlacementStatus] \
    [$rdtc_a_net getName] [$rdtc_z_net getName]] \t]
  incr rdtc_observed_buffers
}
puts $rdtc_report_stream "buffer_count\t$rdtc_observed_buffers"
close $rdtc_report_stream
if {$rdtc_observed_buffers != 14} {
  error "$rdtc_eco_name inserted $rdtc_observed_buffers buffers instead of 14"
}

report_check_types \
  -violators -max_capacitance -max_slew -digits 6 -max_count 1000 \
  > $::env(REPORTS_DIR)/direct_sram_electrical_eco_pre_detail_drc.rpt
puts "RDTC direct SRAM electrical ECO inserted 11 BUF_X4 and 3 BUF_X1 cells"
