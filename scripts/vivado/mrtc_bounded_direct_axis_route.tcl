set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir .. ..]]

proc fail_closed {message} {
  puts stderr "MRTC_BOUNDED_DIRECT_AXIS_ROUTE_ERROR: $message"
  exit 1
}

proc require_nonempty_file {path} {
  if {![file exists $path] || [file size $path] == 0} {
    fail_closed "required output is missing or empty: $path"
  }
}

proc run_required_report {command path} {
  if {[catch {uplevel #0 $command} report_error]} {
    fail_closed "report command failed for $path: $report_error"
  }
  require_nonempty_file $path
}

proc timing_object_name {object} {
  set result $object
  if {![catch {set result [get_property NAME $object]}]} {
    return $result
  }
  return $object
}

proc write_negative_setup_endpoints {path} {
  set fp [open $path w]
  puts $fp "slack_ns\tstartpoint\tendpoint"
  set count 0
  set timing_paths [get_timing_paths -quiet -setup -nworst 1 \
    -max_paths 100000 -slack_lesser_than 0.0]
  foreach timing_path $timing_paths {
    set slack [get_property SLACK $timing_path]
    set startpoint [timing_object_name \
      [get_property STARTPOINT_PIN $timing_path]]
    set endpoint [timing_object_name \
      [get_property ENDPOINT_PIN $timing_path]]
    puts $fp "[format %.3f $slack]\t$startpoint\t$endpoint"
    incr count
  }
  close $fp
  require_nonempty_file $path
  return $count
}

proc read_repo_filelist {repo_root filelist} {
  if {![file exists $filelist]} {
    fail_closed "RTL filelist is missing: $filelist"
  }
  set fp [open $filelist r]
  while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} {
      continue
    }
    if {[regexp {^\+incdir\+(.+)$} $line -> incdir]} {
      set normalized [file normalize [file join $repo_root $incdir]]
      set_property include_dirs \
        [concat [get_property include_dirs [current_fileset]] $normalized] \
        [current_fileset]
      continue
    }
    if {![regexp {\.sv$} $line]} {
      close $fp
      fail_closed "unsupported filelist entry: $line"
    }
    set source_path [file normalize [file join $repo_root $line]]
    if {![file exists $source_path]} {
      close $fp
      fail_closed "RTL source is missing: $source_path"
    }
    read_verilog -sv $source_path
  }
  close $fp
}

proc original_ref_name {cell} {
  set value ""
  if {![catch {set value [get_property ORIG_REF_NAME $cell]}] && $value ne ""} {
    return $value
  }
  return [get_property REF_NAME $cell]
}

proc hierarchy_cells_by_ref {reference} {
  set result [list]
  foreach cell [get_cells -quiet -hier] {
    if {[original_ref_name $cell] eq $reference} {
      lappend result $cell
    }
  }
  return [lsort -dictionary $result]
}

proc cells_under {root cells} {
  set result [list]
  set prefix "$root/"
  foreach cell $cells {
    if {[string first $prefix [get_property NAME $cell]] == 0} {
      lappend result $cell
    }
  }
  return [lsort -dictionary $result]
}

proc is_lutram_primitive {cell} {
  return [regexp {^RAM(16|32|64|128|256|512)} [get_property REF_NAME $cell]]
}

proc is_ramb18_primitive {cell} {
  return [regexp {^RAMB18E[12]$} [get_property REF_NAME $cell]]
}

proc is_ramb36_primitive {cell} {
  return [regexp {^RAMB36E[12]$} [get_property REF_NAME $cell]]
}

proc is_srl_primitive {cell} {
  return [regexp {^SRL(C)?(16|32)E$} [get_property REF_NAME $cell]]
}

proc is_ff_primitive {cell} {
  return [regexp {^FD(R|S|C|P)?E?$} [get_property REF_NAME $cell]]
}

if {![info exists ::env(MRTC_DIRECT_ROUTE_OUT_DIR)] ||
    $::env(MRTC_DIRECT_ROUTE_OUT_DIR) eq ""} {
  fail_closed "MRTC_DIRECT_ROUTE_OUT_DIR is not set; invoke the Python runner"
}
if {![info exists ::env(MRTC_DIRECT_TARGET_MHZ)] ||
    ![info exists ::env(MRTC_DIRECT_CLOCK_PERIOD_NS)]} {
  fail_closed "target frequency identity is incomplete"
}

set out_dir [file normalize $::env(MRTC_DIRECT_ROUTE_OUT_DIR)]
set schema 2
set top_name "mrtc_rdtc_bounded_axis_multiengine_wrapper"
set part_name "xc7z100ffg900-2"
set clock_period_ns $::env(MRTC_DIRECT_CLOCK_PERIOD_NS)
set target_mhz $::env(MRTC_DIRECT_TARGET_MHZ)
if {$target_mhz eq "200"} {
  if {$clock_period_ns ne "5.000"} {
    fail_closed "200 MHz requires an exact 5.000 ns period"
  }
} elseif {$target_mhz eq "250"} {
  if {$clock_period_ns ne "4.000"} {
    fail_closed "250 MHz requires an exact 4.000 ns period"
  }
} else {
  fail_closed "target frequency must be 200 or 250 MHz"
}
set num_engines 2
set way_count 4
set way_depth_words 32
set prefix_samples 128
set output_fifo_depth 16
set expected_way_lutram_primitives 128
set expected_ring_lutram_primitives \
  [expr {$num_engines * $way_count * $expected_way_lutram_primitives}]
set rtl_defines [list]
set tcl_marker "MRTC_BOUNDED_DIRECT_AXIS_ROUTE_TCL_PASS"

file mkdir $out_dir
if {[llength [get_parts -quiet $part_name]] != 1} {
  fail_closed "Vivado does not uniquely recognize part $part_name"
}

create_project -in_memory -part $part_name
read_repo_filelist $repo_root \
  [file join $repo_root flows manifests rdtc_v1_bounded_direct.f]
set xdc_path [file join $script_dir \
  "mrtc_bounded_direct_axis_route_${target_mhz}m.xdc"]
if {![file exists $xdc_path]} {
  fail_closed "target XDC is missing: $xdc_path"
}
read_xdc $xdc_path

if {[catch {
  synth_design -top $top_name -part $part_name -mode out_of_context \
    -flatten_hierarchy none \
    -generic [list \
      AXIS_DATA_W=128 \
      NUM_ENGINES=2 \
      ENGINE_BOUNDED_WAY_COUNT=4 \
      PREFIX_SAMPLES=128 \
      OUTPUT_FIFO_DEPTH=16]
} synth_error]} {
  fail_closed "synth_design failed: $synth_error"
}

set clock_ports [get_ports -quiet clk]
if {[llength $clock_ports] != 1} {
  fail_closed "expected exactly one clk input port"
}
set clocks [get_clocks -quiet clk]
if {[llength $clocks] != 1} {
  fail_closed "expected exactly one clk timing object"
}
set actual_period [format %.3f [get_property PERIOD [lindex $clocks 0]]]
if {$actual_period ne $clock_period_ns} {
  fail_closed "clock period mismatch: expected $clock_period_ns got $actual_period"
}
set clk_sites [get_sites -quiet BUFGCTRL_X0Y0]
if {[llength $clk_sites] != 1} {
  fail_closed "expected exactly one BUFGCTRL_X0Y0 site"
}
set_property HD.CLK_SRC BUFGCTRL_X0Y0 $clock_ports
if {[get_property HD.CLK_SRC $clock_ports] ne "BUFGCTRL_X0Y0"} {
  fail_closed "HD.CLK_SRC readback mismatch"
}

set blackboxes [get_cells -quiet -hier -filter {IS_BLACKBOX == 1}]
set latch_cells [list]
set global_lutram_cells [list]
set global_ramb18_cells [list]
set global_ramb36_cells [list]
foreach cell [get_cells -quiet -hier -filter {IS_PRIMITIVE == 1}] {
  set ref_name [get_property REF_NAME $cell]
  if {[regexp {^(LDCE|LDPE|LDCPE)$} $ref_name]} {
    lappend latch_cells $cell
  }
  if {[is_lutram_primitive $cell]} {
    lappend global_lutram_cells $cell
  }
  if {[is_ramb18_primitive $cell]} {
    lappend global_ramb18_cells $cell
  }
  if {[is_ramb36_primitive $cell]} {
    lappend global_ramb36_cells $cell
  }
}

set engine_cells [hierarchy_cells_by_ref mrtc_rdtc_encoder_bounded_ht]
set ring_cells [hierarchy_cells_by_ref mrtc_shallow_way_ring_slice]
set way_cells [hierarchy_cells_by_ref mrtc_shallow_1rw_way]
set commit_store_cells [hierarchy_cells_by_ref mrtc_axis_payload_commit_store]
set payload_bram_cells [hierarchy_cells_by_ref mrtc_axis_payload_bram]
set payload_slot_cells [hierarchy_cells_by_ref mrtc_bounded_payload_slot_mem]
set ddr_feeder_cells [concat \
  [hierarchy_cells_by_ref mrtc_rdtc_ddr_feeder_engine] \
  [hierarchy_cells_by_ref mrtc_rdtc_ddr_feeder_engine_sync64]]
set feeder_fifo_cells [hierarchy_cells_by_ref mrtc_bounded_feeder_fifo_mem]
set width_packer_cells [hierarchy_cells_by_ref mrtc_axis_width_packer]
set ingress_queue_cells [hierarchy_cells_by_ref mrtc_axis_reg_queue2]
set output_fifo_cells [hierarchy_cells_by_ref mrtc_axis_bounded_output_fifo]
set legacy_packet_buffer_cells [hierarchy_cells_by_ref mrtc_axis_packet_buffer]
set legacy_accumulator_cells [hierarchy_cells_by_ref mrtc_bit_accumulator_axis]

if {[llength $blackboxes] != 0 || [llength $latch_cells] != 0} {
  fail_closed "post-synthesis blackbox/latch count is [llength $blackboxes]/[llength $latch_cells]"
}
if {[llength $engine_cells] != $num_engines ||
    [llength $ring_cells] != $num_engines ||
    [llength $way_cells] != ($num_engines * $way_count) ||
    [llength $width_packer_cells] != $num_engines ||
    [llength $ingress_queue_cells] != $num_engines ||
    [llength $output_fifo_cells] != 1} {
  fail_closed "direct wrapper hierarchy count drifted"
}
if {[llength $commit_store_cells] != 0 ||
    [llength $payload_bram_cells] != 0 ||
    [llength $payload_slot_cells] != 0 ||
    [llength $ddr_feeder_cells] != 0 ||
    [llength $feeder_fifo_cells] != 0 ||
    [llength $legacy_packet_buffer_cells] != 0 ||
    [llength $legacy_accumulator_cells] != 0} {
  fail_closed "forbidden DDR, payload, or legacy storage hierarchy is present"
}
if {[llength $global_ramb36_cells] != 0 ||
    [llength $global_ramb18_cells] != 0} {
  fail_closed "direct wrapper unexpectedly contains block RAM"
}

set ring_lutram_cells [list]
foreach way_cell $way_cells {
  set way_memories [cells_under [get_property NAME $way_cell] $global_lutram_cells]
  if {[llength $way_memories] != $expected_way_lutram_primitives} {
    fail_closed "a ring way does not contain exactly $expected_way_lutram_primitives LUTRAM primitives"
  }
  set way_refs [list]
  foreach memory $way_memories {
    lappend way_refs [get_property REF_NAME $memory]
  }
  if {[lsort -unique $way_refs] ne [list RAM32X1S]} {
    fail_closed "a ring way is not mapped exclusively to RAM32X1S"
  }
  set ring_lutram_cells [concat $ring_lutram_cells $way_memories]
}

set output_fifo_root [get_property NAME [lindex $output_fifo_cells 0]]
set output_fifo_lutram_cells [cells_under $output_fifo_root $global_lutram_cells]
set output_fifo_srl_cells [list]
set output_fifo_ff_cells [list]
foreach cell [get_cells -quiet -hier -filter {IS_PRIMITIVE == 1}] {
  set cell_name [get_property NAME $cell]
  if {[string first "$output_fifo_root/" $cell_name] != 0} {
    continue
  }
  if {[is_srl_primitive $cell]} {
    lappend output_fifo_srl_cells $cell
  }
  if {[is_ff_primitive $cell]} {
    lappend output_fifo_ff_cells $cell
  }
}
set attributed_lutram_cells \
  [lsort -unique [concat $ring_lutram_cells $output_fifo_lutram_cells]]
if {[llength $ring_lutram_cells] != $expected_ring_lutram_primitives} {
  fail_closed "ring LUTRAM primitive count drifted from $expected_ring_lutram_primitives"
}
if {[llength $attributed_lutram_cells] != [llength $global_lutram_cells]} {
  fail_closed "LUTRAM exists outside the ring and global output FIFO"
}

set structural_path [file join $out_dir structural_audit.txt]
set fp [open $structural_path w]
puts $fp "schema=$schema"
puts $fp "top=$top_name"
puts $fp "num_engines=[llength $engine_cells]"
puts $fp "way_count=[llength $way_cells]"
puts $fp "way_depth_words=$way_depth_words"
puts $fp "prefix_samples=$prefix_samples"
puts $fp "output_fifo_depth=$output_fifo_depth"
puts $fp "ring_count=[llength $ring_cells]"
puts $fp "commit_store_count=[llength $commit_store_cells]"
puts $fp "payload_bram_leaf_count=[llength $payload_bram_cells]"
puts $fp "payload_slot_leaf_count=[llength $payload_slot_cells]"
puts $fp "ddr_feeder_count=[llength $ddr_feeder_cells]"
puts $fp "feeder_fifo_leaf_count=[llength $feeder_fifo_cells]"
puts $fp "width_packer_count=[llength $width_packer_cells]"
puts $fp "ingress_queue_count=[llength $ingress_queue_cells]"
puts $fp "output_fifo_count=[llength $output_fifo_cells]"
puts $fp "legacy_packet_buffer_count=[llength $legacy_packet_buffer_cells]"
puts $fp "legacy_accumulator_count=[llength $legacy_accumulator_cells]"
puts $fp "blackbox_count=[llength $blackboxes]"
puts $fp "latch_count=[llength $latch_cells]"
puts $fp "global_lutram_primitive_count=[llength $global_lutram_cells]"
puts $fp "ring_lutram_primitive_count=[llength $ring_lutram_cells]"
puts $fp "output_fifo_lutram_primitive_count=[llength $output_fifo_lutram_cells]"
puts $fp "output_fifo_srl_primitive_count=[llength $output_fifo_srl_cells]"
puts $fp "output_fifo_ff_primitive_count=[llength $output_fifo_ff_cells]"
puts $fp "ramb36_count=[llength $global_ramb36_cells]"
puts $fp "ramb18_count=[llength $global_ramb18_cells]"
close $fp
require_nonempty_file $structural_path

set post_synth_timing_summary [file join $out_dir post_synth_timing_summary.rpt]
set post_synth_timing_paths [file join $out_dir post_synth_timing_worst_50.rpt]
set post_synth_high_fanout [file join $out_dir post_synth_high_fanout.rpt]
run_required_report \
  [list report_timing_summary -delay_type max -max_paths 50 \
    -file $post_synth_timing_summary] \
  $post_synth_timing_summary
run_required_report \
  [list report_timing -delay_type max -max_paths 50 -nworst 1 \
    -sort_by group -path_type full -file $post_synth_timing_paths] \
  $post_synth_timing_paths
run_required_report \
  [list report_high_fanout_nets -timing -load_types -max_nets 100 \
    -file $post_synth_high_fanout] \
  $post_synth_high_fanout

if {[catch {opt_design} opt_error]} {
  fail_closed "opt_design failed: $opt_error"
}
if {[catch {place_design -directive Explore} place_error]} {
  fail_closed "place_design failed: $place_error"
}
if {[catch {phys_opt_design -directive AggressiveExplore} physopt_error]} {
  fail_closed "phys_opt_design failed: $physopt_error"
}

set post_place_timing_summary [file join $out_dir post_place_timing_summary.rpt]
set post_place_timing_paths [file join $out_dir post_place_timing_worst_50.rpt]
set post_place_high_fanout [file join $out_dir post_place_high_fanout.rpt]
run_required_report \
  [list report_timing_summary -delay_type max -max_paths 50 \
    -file $post_place_timing_summary] \
  $post_place_timing_summary
run_required_report \
  [list report_timing -delay_type max -max_paths 50 -nworst 1 \
    -sort_by group -path_type full -file $post_place_timing_paths] \
  $post_place_timing_paths
run_required_report \
  [list report_high_fanout_nets -timing -load_types -max_nets 100 \
    -file $post_place_high_fanout] \
  $post_place_high_fanout

if {[catch {route_design -directive Explore} route_error]} {
  fail_closed "route_design failed: $route_error"
}
if {[catch {write_checkpoint -force [file join $out_dir post_route.dcp]} dcp_error]} {
  fail_closed "post-route checkpoint write failed: $dcp_error"
}

set timing_setup_summary [file join $out_dir timing_setup_summary.rpt]
set timing_setup_paths [file join $out_dir timing_setup_worst_50.rpt]
set timing_hold_summary [file join $out_dir timing_hold_summary.rpt]
set timing_hold_paths [file join $out_dir timing_hold_worst_50.rpt]
set utilization [file join $out_dir utilization.rpt]
set utilization_hier [file join $out_dir utilization_hierarchical.rpt]
set route_status [file join $out_dir route_status.rpt]
set drc [file join $out_dir drc.rpt]
set methodology [file join $out_dir methodology.rpt]
set check_timing_rpt [file join $out_dir check_timing.rpt]
set all_setup_violations [file join $out_dir all_setup_violations.tsv]
set post_route_high_fanout [file join $out_dir post_route_high_fanout.rpt]

run_required_report \
  [list report_timing_summary -delay_type max -max_paths 50 \
    -check_timing_verbose -file $timing_setup_summary] \
  $timing_setup_summary
run_required_report \
  [list report_timing -delay_type max -max_paths 50 -nworst 1 \
    -sort_by group -path_type full -file $timing_setup_paths] \
  $timing_setup_paths
run_required_report \
  [list report_timing_summary -delay_type min -max_paths 50 \
    -file $timing_hold_summary] \
  $timing_hold_summary
run_required_report \
  [list report_timing -delay_type min -max_paths 50 -nworst 1 \
    -sort_by group -path_type full -file $timing_hold_paths] \
  $timing_hold_paths
run_required_report [list report_utilization -file $utilization] $utilization
run_required_report \
  [list report_utilization -hierarchical -hierarchical_depth 20 -file $utilization_hier] \
  $utilization_hier
run_required_report [list report_route_status -file $route_status] $route_status
run_required_report [list report_drc -file $drc] $drc
run_required_report [list report_methodology -file $methodology] $methodology
run_required_report [list check_timing -verbose -file $check_timing_rpt] $check_timing_rpt
run_required_report \
  [list report_high_fanout_nets -timing -load_types -max_nets 100 \
    -file $post_route_high_fanout] \
  $post_route_high_fanout
set negative_setup_endpoint_count \
  [write_negative_setup_endpoints $all_setup_violations]

set identity_path [file join $out_dir tcl_identity.txt]
set fp [open $identity_path w]
puts $fp "schema=$schema"
puts $fp "vivado_version_short=[version -short]"
puts $fp "top=$top_name"
puts $fp "part=$part_name"
puts $fp "mode=out_of_context"
puts $fp "implementation_stage=post_route"
puts $fp "flatten_hierarchy=none"
puts $fp "clock_period_ns=$clock_period_ns"
puts $fp "target_mhz=$target_mhz"
puts $fp "hd_clk_src=BUFGCTRL_X0Y0"
puts $fp "axis_data_w=128"
puts $fp "num_engines=$num_engines"
puts $fp "way_count=$way_count"
puts $fp "way_depth_words=$way_depth_words"
puts $fp "prefix_samples=$prefix_samples"
puts $fp "output_fifo_depth=$output_fifo_depth"
puts $fp "defines=[join $rtl_defines ,]"
puts $fp "negative_setup_endpoint_count=$negative_setup_endpoint_count"
close $fp
require_nonempty_file $identity_path

set fp [open [file join $out_dir tcl_status.txt] w]
puts $fp $tcl_marker
close $fp
puts $tcl_marker
exit 0
