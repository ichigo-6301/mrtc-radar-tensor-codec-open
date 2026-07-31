if {![info exists ::env(RDTC_FINAL_ODB)] || $::env(RDTC_FINAL_ODB) eq ""} {
  error "RDTC_FINAL_ODB is required"
}
if {![info exists ::env(RDTC_DIRECT_MACRO_RAW_AUDIT)] ||
    $::env(RDTC_DIRECT_MACRO_RAW_AUDIT) eq ""} {
  error "RDTC_DIRECT_MACRO_RAW_AUDIT is required"
}

read_db $::env(RDTC_FINAL_ODB)
set rdtc_block [ord::get_db_block]
set rdtc_dbu_per_micron [$rdtc_block getDbUnitsPerMicron]
set rdtc_records {}
set rdtc_eco_records {}
set rdtc_eco_connections {}

foreach rdtc_inst [$rdtc_block getInsts] {
  set rdtc_master [$rdtc_inst getMaster]
  set rdtc_inst_name [$rdtc_inst getName]
  if {[string match {*rdtc_direct_eco_addr_buf_*} $rdtc_inst_name] ||
      [string match {*rdtc_direct_eco_dout_buf_*} $rdtc_inst_name]} {
    set rdtc_bbox [$rdtc_inst getBBox]
    set rdtc_a_iterm [$rdtc_inst findITerm A]
    set rdtc_z_iterm [$rdtc_inst findITerm Z]
    if {$rdtc_a_iterm eq "NULL" || $rdtc_z_iterm eq "NULL"} {
      error "Direct SRAM ECO buffer lacks A/Z terminals: $rdtc_inst_name"
    }
    set rdtc_a_net [$rdtc_a_iterm getNet]
    set rdtc_z_net [$rdtc_z_iterm getNet]
    if {$rdtc_a_net eq "NULL" || $rdtc_z_net eq "NULL" ||
        $rdtc_a_net eq $rdtc_z_net} {
      error "Direct SRAM ECO buffer has malformed A/Z nets: $rdtc_inst_name"
    }
    lappend rdtc_eco_records [list \
      $rdtc_inst_name \
      [$rdtc_master getName] \
      [$rdtc_bbox xMin] \
      [$rdtc_bbox yMin] \
      [$rdtc_bbox xMax] \
      [$rdtc_bbox yMax] \
      [$rdtc_inst getPlacementStatus] \
      [$rdtc_a_net getName] \
      [$rdtc_z_net getName]]
    foreach rdtc_port_net [list [list A $rdtc_a_net] [list Z $rdtc_z_net]] {
      lassign $rdtc_port_net rdtc_buffer_port rdtc_net
      foreach rdtc_endpoint [$rdtc_net getITerms] {
        set rdtc_endpoint_mterm [$rdtc_endpoint getMTerm]
        if {[$rdtc_endpoint_mterm getSigType] ne "SIGNAL"} {
          continue
        }
        set rdtc_endpoint_inst [$rdtc_endpoint getInst]
        lappend rdtc_eco_connections [list \
          $rdtc_inst_name $rdtc_buffer_port [$rdtc_net getName] iterm \
          [$rdtc_endpoint_inst getName] \
          [$rdtc_endpoint_mterm getName] \
          [[$rdtc_endpoint_inst getMaster] getName] \
          [$rdtc_endpoint_mterm getIoType]]
      }
      foreach rdtc_endpoint [$rdtc_net getBTerms] {
        if {[$rdtc_endpoint getSigType] ne "SIGNAL"} {
          continue
        }
        lappend rdtc_eco_connections [list \
          $rdtc_inst_name $rdtc_buffer_port [$rdtc_net getName] bterm \
          PORT [$rdtc_endpoint getName] - [$rdtc_endpoint getIoType]]
      }
    }
  }
  if {[$rdtc_master getType] ne "BLOCK"} {
    continue
  }
  set rdtc_bbox [$rdtc_inst getBBox]
  lappend rdtc_records [list \
    $rdtc_inst_name \
    [$rdtc_master getName] \
    [$rdtc_bbox xMin] \
    [$rdtc_bbox yMin] \
    [$rdtc_bbox xMax] \
    [$rdtc_bbox yMax] \
    [$rdtc_inst getOrient] \
    [$rdtc_inst getPlacementStatus]]
}

set rdtc_records [lsort -index 0 $rdtc_records]
set rdtc_eco_records [lsort -index 0 $rdtc_eco_records]
set rdtc_eco_connections [lsort $rdtc_eco_connections]
file mkdir [file dirname $::env(RDTC_DIRECT_MACRO_RAW_AUDIT)]
set rdtc_output [open $::env(RDTC_DIRECT_MACRO_RAW_AUDIT) w]
puts $rdtc_output "schema_version\t2"
puts $rdtc_output "dbu_per_micron\t$rdtc_dbu_per_micron"
foreach rdtc_record $rdtc_records {
  puts $rdtc_output "macro\t[join $rdtc_record \t]"
}
puts $rdtc_output "macro_count\t[llength $rdtc_records]"
foreach rdtc_record $rdtc_eco_records {
  puts $rdtc_output "eco_buffer\t[join $rdtc_record \t]"
}
foreach rdtc_record $rdtc_eco_connections {
  puts $rdtc_output "eco_connection\t[join $rdtc_record \t]"
}
puts $rdtc_output "eco_buffer_count\t[llength $rdtc_eco_records]"
close $rdtc_output

puts "RDTC direct macro raw audit: [llength $rdtc_records] block macros, [llength $rdtc_eco_records] ECO buffers"
