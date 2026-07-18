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

proc require_path {path label} {
  if {![file exists $path]} {
    error "Missing $label: $path"
  }
}

proc require_reference_ndm {path} {
  if {![file isdirectory $path] || ![file isfile [file join $path reflib.ndm]]} {
    error "Missing or incomplete ICC2 reference NDM: $path"
  }
}

set build_root [require_env RDTC_BUILD_ROOT]
set top [require_env RDTC_TOP]
set pnr_scope [require_env RDTC_PNR_SCOPE]
if {$pnr_scope ni {full floorplan_only}} {
  error "RDTC_PNR_SCOPE must be full or floorplan_only, got: $pnr_scope"
}
source [require_env RDTC_ICC2_SETUP]

foreach {path label} [list \
  $rdtc_dc_netlist "DC netlist" \
  $rdtc_dc_sdc "DC SDC"] {
  require_file $path $label
}
foreach ndm $rdtc_reference_ndms {
  require_reference_ndm $ndm
}

set output_dir "$build_root/icc2"
file mkdir $output_dir
if {[file exists $rdtc_design_library]} {
  file delete -force $rdtc_design_library
}

create_lib -ref_libs $rdtc_reference_ndms $rdtc_design_library
read_verilog -top $top $rdtc_dc_netlist
current_block $top
link_block
read_sdc $rdtc_dc_sdc

if {$pnr_scope eq "full"} {
  if {![info exists rdtc_rc_mode]} {set rdtc_rc_mode unavailable}
  set rc_preflight "$output_dir/rc_preflight.rpt"
  if {$rdtc_rc_mode eq "native_tluplus"} {
   foreach name {
    rdtc_tluplus_file
    rdtc_tluplus_layermap
    rdtc_parasitic_tech_name
    rdtc_parasitic_temperature
    rdtc_parasitic_sanity_check
   } {
    if {![info exists $name] || [set $name] eq ""} {
      set fh [open $rc_preflight w]
      puts $fh "status=blocked_missing_parasitic_tech"
      puts $fh "missing_variable=$name"
      close $fh
      error "blocked_missing_parasitic_tech: full ICC2 flow requires $name"
    }
   }
   if {$rdtc_parasitic_sanity_check ni {basic advanced}} {
     error "rdtc_parasitic_sanity_check must be basic or advanced"
   }
   if {![file exists $rdtc_tluplus_file] || ![file isfile $rdtc_tluplus_layermap]} {
     set fh [open $rc_preflight w]
     puts $fh "status=blocked_missing_parasitic_tech"
     puts $fh "tluplus_exists=[file exists $rdtc_tluplus_file]"
     puts $fh "layermap_exists=[file isfile $rdtc_tluplus_layermap]"
     close $fh
     error "blocked_missing_parasitic_tech: matching TLUPlus or layer map is missing"
   }
   set parasitic_args [list -tlup $rdtc_tluplus_file \
    -name $rdtc_parasitic_tech_name \
    -sanity_check $rdtc_parasitic_sanity_check]
   lappend parasitic_args -layermap $rdtc_tluplus_layermap
   eval [linsert $parasitic_args 0 read_parasitic_tech]
   set_parasitic_techs [get_parasitic_techs -quiet $rdtc_parasitic_tech_name]
   if {[sizeof_collection $parasitic_techs] != 1} {
     set fh [open $rc_preflight w]
     puts $fh "status=blocked_missing_parasitic_tech"
     puts $fh "parasitic_tech_count=[sizeof_collection $parasitic_techs]"
     close $fh
     error "blocked_missing_parasitic_tech: expected one loaded model named $rdtc_parasitic_tech_name"
   }
   set_parasitic_parameters \
    -early_spec $rdtc_parasitic_tech_name \
    -late_spec $rdtc_parasitic_tech_name \
    -early_temperature $rdtc_parasitic_temperature \
    -late_temperature $rdtc_parasitic_temperature
   redirect -file "$output_dir/parasitic_parameters.rpt" {report_parasitic_parameters}
   set fh [open $rc_preflight w]
   puts $fh "status=pass"
   puts $fh "mode=native_tluplus"
   puts $fh "parasitic_tech_count=1"
   close $fh
  } elseif {$rdtc_rc_mode eq "preloaded"} {
    set available_parasitic_techs [get_parasitic_techs -quiet]
    if {[sizeof_collection $available_parasitic_techs] == 0} {
      set fh [open $rc_preflight w]
      puts $fh "status=blocked_missing_parasitic_tech"
      puts $fh "mode=preloaded"
      puts $fh "parasitic_tech_count=0"
      close $fh
      error "blocked_missing_parasitic_tech: ICC2 has no preloaded early/late RC model"
    }
    set fh [open $rc_preflight w]
    puts $fh "status=pass"
    puts $fh "mode=preloaded"
    puts $fh "parasitic_tech_count=[sizeof_collection $available_parasitic_techs]"
    close $fh
    redirect -file "$output_dir/parasitic_parameters.rpt" {report_parasitic_parameters}
    puts "WARNING: using an audited preloaded parasitic technology; not a foundry-signoff claim"
  } elseif {$rdtc_rc_mode in {unavailable estimated}} {
    set available_parasitic_techs [get_parasitic_techs -quiet]
    set fh [open $rc_preflight w]
    puts $fh "status=blocked_missing_parasitic_tech"
    puts $fh "mode=$rdtc_rc_mode"
    puts $fh "parasitic_tech_count=[sizeof_collection $available_parasitic_techs]"
    puts $fh "astro_captable_is_not_icc2_parasitic_technology=true"
    close $fh
    error "blocked_missing_parasitic_tech: TSMC90 Astro CapTable/CapModel is not an ICC2 early/late RC model; use floorplan_only or provide matching TLUPlus"
  } else {
    error "rdtc_rc_mode must be native_tluplus, preloaded, or unavailable"
  }
}

set_app_options -name place.coarse.continue_on_missing_scandef -value true
initialize_floorplan \
  -shape R \
  -side_ratio [list $rdtc_core_aspect_ratio $rdtc_core_aspect_ratio] \
  -core_utilization $rdtc_core_utilization \
  -core_offset [list $rdtc_core_offset $rdtc_core_offset]

set macros [get_flat_cells -quiet -filter "ref_name == $rdtc_sram_cell"]
set macro_count [sizeof_collection $macros]
if {$macro_count != $rdtc_expected_sram_count} {
  error "Expected $rdtc_expected_sram_count SRAM macros, found $macro_count"
}

set core_bbox [get_attribute [get_core_area] bbox]
set ll [lindex $core_bbox 0]
set ur [lindex $core_bbox 1]
set llx [lindex $ll 0]
set lly [lindex $ll 1]
set core_width [expr {[lindex $ur 0] - $llx}]
set core_height [expr {[lindex $ur 1] - $lly}]
set macro_names [lsort [get_object_name $macros]]
if {$rdtc_expected_sram_count != 2} {
  error "The symmetric macro placer currently requires exactly two memory macros"
}
if {![info exists rdtc_macro_edge_margin]} {set rdtc_macro_edge_margin 20.0}
if {![info exists rdtc_macro_spacing]} {set rdtc_macro_spacing 20.0}

set macro0 [get_cells [lindex $macro_names 0]]
set macro1 [get_cells [lindex $macro_names 1]]
set width0 [get_attribute $macro0 width]
set height0 [get_attribute $macro0 height]
set width1 [get_attribute $macro1 width]
set height1 [get_attribute $macro1 height]
set horizontal_width [expr {$width0 + $width1 + (2.0 * $rdtc_macro_edge_margin) + $rdtc_macro_spacing}]
set horizontal_height [expr {max($height0, $height1) + (2.0 * $rdtc_macro_edge_margin)}]
set vertical_width [expr {max($width0, $width1) + (2.0 * $rdtc_macro_edge_margin)}]
set vertical_height [expr {$height0 + $height1 + (2.0 * $rdtc_macro_edge_margin) + $rdtc_macro_spacing}]

if {$horizontal_width <= $core_width && $horizontal_height <= $core_height} {
  set macro_placement_axis horizontal
  set macro_locations [list \
    [list [expr {$llx + $rdtc_macro_edge_margin}] \
          [expr {$lly + (($core_height - $height0) / 2.0)}]] \
    [list [expr {[lindex $ur 0] - $rdtc_macro_edge_margin - $width1}] \
          [expr {$lly + (($core_height - $height1) / 2.0)}]]]
} elseif {$vertical_width <= $core_width && $vertical_height <= $core_height} {
  set macro_placement_axis vertical
  set macro_locations [list \
    [list [expr {$llx + (($core_width - $width0) / 2.0)}] \
          [expr {$lly + $rdtc_macro_edge_margin}]] \
    [list [expr {$llx + (($core_width - $width1) / 2.0)}] \
          [expr {[lindex $ur 1] - $rdtc_macro_edge_margin - $height1}]]]
} else {
  error "Core cannot contain two $rdtc_sram_cell macros with the configured edge margin and spacing"
}

for {set index 0} {$index < 2} {incr index} {
  set macro [get_cells [lindex $macro_names $index]]
  set_cell_location -coordinates [lindex $macro_locations $index] \
    -orientation R0 $macro
}
set_fixed_objects $macros

set macro_bboxes [list]
foreach macro_name $macro_names {
  set macro_bbox [get_attribute [get_cells $macro_name] bbox]
  lappend macro_bboxes $macro_bbox
  set macro_ll [lindex $macro_bbox 0]
  set macro_ur [lindex $macro_bbox 1]
  if {[lindex $macro_ll 0] < ($llx - 0.001) ||
      [lindex $macro_ll 1] < ($lly - 0.001) ||
      [lindex $macro_ur 0] > ([lindex $ur 0] + 0.001) ||
      [lindex $macro_ur 1] > ([lindex $ur 1] + 0.001)} {
    error "Memory macro is outside the core: $macro_name bbox=$macro_bbox core=$core_bbox"
  }
}
set bbox0 [lindex $macro_bboxes 0]
set bbox1 [lindex $macro_bboxes 1]
if {$macro_placement_axis eq "horizontal"} {
  set actual_macro_spacing [expr {
    [lindex [lindex $bbox1 0] 0] - [lindex [lindex $bbox0 1] 0]}]
} else {
  set actual_macro_spacing [expr {
    [lindex [lindex $bbox1 0] 1] - [lindex [lindex $bbox0 1] 1]}]
}
if {$actual_macro_spacing < ($rdtc_macro_spacing - 0.001)} {
  error "Memory macros overlap or violate spacing: actual=$actual_macro_spacing required=$rdtc_macro_spacing"
}

if {[info exists rdtc_pg_hook] && $rdtc_pg_hook ne ""} {
  require_file $rdtc_pg_hook "power-planning hook"
  source $rdtc_pg_hook
} elseif {[info exists rdtc_require_pg_hook] && $rdtc_require_pg_hook} {
  error "Full physical profile requires rdtc_pg_hook"
}

redirect -file "$output_dir/floorplan.rpt" {
  report_utilization
  puts "floorplan_status: partial"
  puts "core_bbox: $core_bbox"
  puts "core_width_um: $core_width"
  puts "core_height_um: $core_height"
  puts "die_bbox_from_core_offset: [list \
    [list [expr {$llx - $rdtc_core_offset}] [expr {$lly - $rdtc_core_offset}]] \
    [list [expr {[lindex $ur 0] + $rdtc_core_offset}] [expr {[lindex $ur 1] + $rdtc_core_offset}]]]"
  puts "sram_macro_count: $macro_count"
  puts "macro_placement_axis: $macro_placement_axis"
  puts "macro_required_spacing_um: $rdtc_macro_spacing"
  puts "macro_actual_spacing_um: $actual_macro_spacing"
  foreach macro_name $macro_names {
    set macro [get_cells $macro_name]
    puts "sram_macro: $macro_name bbox=[get_attribute $macro bbox]"
  }
}
save_block -as floorplan

if {$pnr_scope eq "floorplan_only"} {
  puts "INFO: ICC2 floorplan-only diagnostic completed; no post-route handoff was claimed"
  exit
}

place_opt
redirect -file "$output_dir/placement_qor.rpt" {report_qor}
redirect -file "$output_dir/placement_congestion.rpt" {report_congestion}
save_block -as placed

clock_opt
redirect -file "$output_dir/cts_qor.rpt" {report_qor}
redirect -file "$output_dir/clock_timing.rpt" {report_clock_timing -type summary}
save_block -as cts

route_auto
route_opt
redirect -file "$output_dir/postroute_qor.rpt" {report_qor}
redirect -file "$output_dir/postroute_timing.rpt" {report_timing -max_paths 20}
redirect -file "$output_dir/congestion.rpt" {report_congestion}
redirect -file "$output_dir/drc.rpt" {check_routes}
save_block -as routed

write_verilog -hierarchy all "$output_dir/${top}_postroute.v"
write_sdc -output "$output_dir/${top}_postroute.sdc"
write_parasitics -format spef -output "$output_dir/${top}_postroute.spef"
write_def "$output_dir/${top}_postroute.def"

foreach path [list \
  "$output_dir/${top}_postroute.v" \
  "$output_dir/${top}_postroute.sdc" \
  "$output_dir/${top}_postroute.spef"] {
  if {![file isfile $path]} {
    error "ICC2 did not create required handoff: $path"
  }
}
puts "INFO: ICC2 post-route handoff completed"
exit
