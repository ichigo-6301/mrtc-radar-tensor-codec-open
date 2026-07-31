proc require_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "Missing required environment variable: $name"
  }
  return $::env($name)
}

proc fail {message} {
  echo "ERROR: $message"
  exit 1
}

proc require_sha256 {path expected label} {
  if {![file isfile $path]} {
    fail "Missing $label: $path"
  }
  if {![regexp {^[0-9a-f]{64}$} $expected]} {
    fail "$label expected SHA256 is malformed: $expected"
  }
  if {[catch {set hash_output [exec sha256sum -- $path]} hash_message]} {
    fail "Cannot hash $label with sha256sum: $hash_message"
  }
  set actual [lindex $hash_output 0]
  if {$actual ne $expected} {
    fail "$label SHA256 mismatch: expected $expected got $actual"
  }
  return $actual
}

set root [require_env RDTC_FLOW_ROOT]
set filelist [require_env RDTC_FILELIST]
set top [require_env RDTC_TOP]
set sdc [require_env RDTC_SDC]
set build_root [require_env RDTC_BUILD_ROOT]
set dc_setup [require_env RDTC_DC_SETUP]
set bounded_dc_ab [expr {
  [info exists ::env(RDTC_BOUNDED_DC_AB)] &&
  $::env(RDTC_BOUNDED_DC_AB) eq "y"
}]
set bounded_legacy_register [expr {
  [info exists ::env(RDTC_BOUNDED_ASIC_REGISTER_EXPANDED)] &&
  $::env(RDTC_BOUNDED_ASIC_REGISTER_EXPANDED) eq "y"
}]
set forbid_retime [expr {
  [info exists ::env(RDTC_DC_FORBID_RETIME)] &&
  $::env(RDTC_DC_FORBID_RETIME) eq "y"
}]
if {$forbid_retime} {
  set dc_setup_fh [open $dc_setup r]
  set dc_setup_text [read $dc_setup_fh]
  close $dc_setup_fh
  regsub -all {\\[ \t]*\r?\n} $dc_setup_text { } dc_setup_joined
  set dc_setup_code ""
  foreach setup_line [split $dc_setup_joined "\n"] {
    regsub {#.*$} $setup_line "" setup_line_code
    append dc_setup_code " " [string trim $setup_line_code]
  }
  if {[regexp -nocase \
      {(compile_ultra[^;\n]*-retime|set_optimize_registers|optimize_registers)} \
      $dc_setup_code]} {
    fail "RDTC DC setup enables register retiming, which this profile forbids"
  }
}
source $dc_setup

set approved_stdcell_db ""
set approved_stdcell_db_sha256 ""
if {[info exists ::env(RDTC_EXPECTED_STDCELL_DB_SHA256)] &&
    $::env(RDTC_EXPECTED_STDCELL_DB_SHA256) ne ""} {
  set approved_stdcell_db_sha256 $::env(RDTC_EXPECTED_STDCELL_DB_SHA256)
  set configured_target_library [get_app_var target_library]
  if {[llength $configured_target_library] != 1} {
    fail "hash-bound DC run requires exactly one standard-cell target library"
  }
  set approved_stdcell_db [file normalize [lindex $configured_target_library 0]]
  require_sha256 $approved_stdcell_db $approved_stdcell_db_sha256 \
    "standard-cell target DB"
}

set dc_max_cores 0
if {[info exists ::env(RDTC_DC_MAX_CORES)] && $::env(RDTC_DC_MAX_CORES) ne ""} {
  set dc_max_cores $::env(RDTC_DC_MAX_CORES)
  if {![string is integer -strict $dc_max_cores] ||
      $dc_max_cores < 1 || $dc_max_cores > 12} {
    fail "RDTC_DC_MAX_CORES must be an integer in 1..12"
  }
  if {[catch {set_host_options -max_cores $dc_max_cores} host_options_message]} {
    fail "cannot apply RDTC_DC_MAX_CORES=$dc_max_cores: $host_options_message"
  }
}

set output_dir "$build_root/dc_baseline"
file mkdir $output_dir

set filelist_fh [open $filelist r]
set rtl_files [list]
set include_dirs [list]
while {[gets $filelist_fh raw_line] >= 0} {
  regsub {//.*$} $raw_line "" without_comment
  set line [string trim $without_comment]
  if {$line eq ""} {
    continue
  }
  if {[string match "+incdir+*" $line]} {
    foreach entry [split [string range $line 8 end] "+"] {
      set include_dir [file normalize [file join $root $entry]]
      if {![file isdirectory $include_dir]} {
        close $filelist_fh
        fail "Missing include directory: $include_dir"
      }
      lappend include_dirs $include_dir
    }
  } elseif {[string index $line 0] eq "+"} {
    close $filelist_fh
    fail "Unsupported DC filelist directive: $line"
  } else {
    set rtl_file [file normalize [file join $root $line]]
    if {![file isfile $rtl_file]} {
      close $filelist_fh
      fail "Missing RTL source: $rtl_file"
    }
    lappend rtl_files $rtl_file
  }
}
close $filelist_fh

if {[llength $rtl_files] == 0} {
  fail "No RTL sources found in $filelist"
}
set_app_var search_path [concat $include_dirs [get_app_var search_path]]

set use_sram_macro [expr {[info exists rdtc_use_sram_macro] && $rdtc_use_sram_macro}]
set use_bounded_sram_macro [expr {
  [info exists rdtc_use_bounded_sram_macro] && $rdtc_use_bounded_sram_macro
}]
set use_any_sram_macro [expr {$use_sram_macro || $use_bounded_sram_macro}]
set configured_memory_mode [require_env RDTC_MEMORY_MODE]
if {$configured_memory_mode eq "registers" && $use_any_sram_macro} {
  fail "register-expanded profile selected a macro-aware DC setup"
}
if {$configured_memory_mode eq "macro" && !$use_any_sram_macro} {
  fail "sram-macro profile selected a register-expanded DC setup"
}
if {![info exists rdtc_rtl_defines]} {
  if {$use_sram_macro} {
    if {[info exists ::env(CONFIG_FLOW_TECHNOLOGY)] &&
        $::env(CONFIG_FLOW_TECHNOLOGY) eq "nangate45_openram_spice"} {
      set rdtc_rtl_defines [list RDTC_USE_OPENRAM_PREFIX_SRAM_1RW1R]
    } else {
      set rdtc_rtl_defines [list RDTC_USE_OPENRAM_PREFIX_SRAM]
    }
  } else {
    set rdtc_rtl_defines {}
  }
}
set direct_register [expr {
  [info exists ::env(RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED)] &&
  $::env(RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED) eq "y"
}]
set direct_sram [expr {
  [info exists ::env(RDTC_BOUNDED_DIRECT_ASIC_SRAM)] &&
  $::env(RDTC_BOUNDED_DIRECT_ASIC_SRAM) eq "y"
}]
set bounded_profile_count [expr {
  $bounded_legacy_register + $direct_register + $direct_sram
}]
if {$bounded_profile_count > 1} {
  fail "buffered and Direct-AXIS bounded profiles are mutually exclusive"
}
set bounded_ab_family [expr {
  $direct_register ? "direct" : ($bounded_legacy_register ? "buffered" : "none")
}]
set bounded_expected_bulk_bits 0
if {$bounded_dc_ab} {
  if {!$forbid_retime || $bounded_profile_count != 1 || $direct_sram} {
    fail "bounded DC A/B requires one register-expanded profile and no retiming"
  }
  set bounded_expected_top [expr {
    $bounded_ab_family eq "direct" ?
      "mrtc_rdtc_bounded_axis_multiengine_wrapper" :
      "mrtc_rdtc_ddr_multiengine_wrapper"
  }]
  if {$top ne $bounded_expected_top} {
    fail "bounded DC A/B selected the wrong top: $top"
  }
  set bounded_expected_bulk_bits [require_env RDTC_EXPECTED_BOUNDED_BULK_STORAGE_BITS]
  set bounded_contract_bits [expr {
    $bounded_ab_family eq "direct" ? 32768 : 180224
  }]
  if {![string is integer -strict $bounded_expected_bulk_bits] ||
      $bounded_expected_bulk_bits != $bounded_contract_bits} {
    fail "bounded $bounded_ab_family bulk-storage contract must be $bounded_contract_bits bits"
  }
  if {![info exists ::env(RDTC_DC_NO_INIT)] ||
      $::env(RDTC_DC_NO_INIT) ne "y"} {
    fail "bounded DC A/B requires dc_shell -no_init"
  }
  if {[llength [info commands _snps_array_peek]] == 0} {
    proc _snps_array_peek {level array_name} {
      upvar #$level $array_name values
      set result [list]
      if {[catch {set search [array startsearch values]}]} {
        return $result
      }
      if {[array anymore values $search]} {
        set key [array nextelement values $search]
        set result [list $key $values($key)]
      }
      array donesearch values $search
      return $result
    }
  }
  if {[llength [info commands _snps_array_peek]] != 1} {
    fail "DC array-mapping compatibility helper is unavailable"
  }
  lappend rdtc_rtl_defines RDTC_BOUNDED_HT_WAY_RING
  set rdtc_rtl_defines [lsort -unique $rdtc_rtl_defines]
}
if {$direct_register || $direct_sram} {
  if {$top ne "mrtc_rdtc_bounded_axis_multiengine_wrapper"} {
    fail "Direct-AXIS profile selected the wrong top: $top"
  }
  lappend rdtc_rtl_defines [expr {
    $direct_register ?
      "RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED" :
      "RDTC_BOUNDED_DIRECT_ASIC_SRAM"
  }]
  set rdtc_rtl_defines [lsort -unique $rdtc_rtl_defines]
}
if {$bounded_legacy_register} {
  if {$top ne "mrtc_rdtc_ddr_multiengine_wrapper"} {
    fail "bounded buffered profile selected the wrong top: $top"
  }
  lappend rdtc_rtl_defines RDTC_BOUNDED_ASIC_REGISTER_EXPANDED
  set rdtc_rtl_defines [lsort -unique $rdtc_rtl_defines]
}
if {![info exists rdtc_memory_model_files]} {set rdtc_memory_model_files {}}
foreach memory_model $rdtc_memory_model_files {
  if {![file isfile $memory_model]} {
    fail "Missing local memory model: $memory_model"
  }
  lappend rtl_files $memory_model
}
if {[llength $rdtc_rtl_defines] > 0} {
  set analyze_command [list analyze -format sverilog]
  # O-2018.06 accepts one -define option whose value is the complete list.
  lappend analyze_command -define $rdtc_rtl_defines
  lappend analyze_command $rtl_files
} else {
  set analyze_command [list analyze -format sverilog $rtl_files]
}
if {[catch {set analyze_ok [eval $analyze_command]} analyze_message] || !$analyze_ok} {
  fail "analyze failed: $analyze_message"
}
if {[catch {elaborate $top} elaborate_message]} {
  fail "elaborate failed: $elaborate_message"
}
if {[sizeof_collection [get_designs -quiet $top]] == 0} {
  fail "elaborate did not create design '$top'"
}
current_design $top
if {[catch {set link_ok [link]} link_message] || !$link_ok} {
  fail "link failed: $link_message"
}
if {$use_sram_macro} {
  if {![info exists rdtc_sram_cell] || ![info exists rdtc_expected_sram_count]} {
    fail "SRAM mode requires rdtc_sram_cell and rdtc_expected_sram_count"
  }
  set linked_sram_cells [get_cells -hierarchical -quiet -filter "ref_name == $rdtc_sram_cell"]
  set linked_sram_count [sizeof_collection $linked_sram_cells]
  if {$linked_sram_count != $rdtc_expected_sram_count} {
    fail "expected $rdtc_expected_sram_count linked SRAM macros, found $linked_sram_count"
  }
  set_dont_touch $linked_sram_cells
} elseif {$use_bounded_sram_macro} {
  if {![info exists rdtc_bounded_sram_cell] ||
      ![info exists rdtc_expected_bounded_sram_count]} {
    fail "bounded SRAM mode requires cell name and expected count"
  }
  set linked_sram_cells [get_cells -hierarchical -quiet \
    -filter "ref_name == $rdtc_bounded_sram_cell"]
  set linked_sram_count [sizeof_collection $linked_sram_cells]
  if {$linked_sram_count != $rdtc_expected_bounded_sram_count} {
    fail "expected $rdtc_expected_bounded_sram_count bounded SRAM macros, found $linked_sram_count"
  }
  set_dont_touch $linked_sram_cells
} else {
  set forbidden_memory_refs [list \
    mrtc_rdtc_prefix_1r1w_64x128 \
    mrtc_rdtc_prefix_1rw1r_64x128 \
    mrtc_rdtc_bounded_feeder_1rw1r_64x32 \
    mrtc_rdtc_bounded_ring_1rw_32x128 \
    mrtc_rdtc_block_1rw_256x32 \
    sky130_sram_1kbyte_1rw1r_32x256_8 \
    RF_2P_ADV SRAM_DP_ADV]
  set linked_memory_count 0
  foreach memory_ref $forbidden_memory_refs {
    incr linked_memory_count [sizeof_collection \
      [get_cells -hierarchical -quiet -filter "ref_name == $memory_ref"]]
  }
  if {$linked_memory_count != 0} {
    fail "register-expanded profile linked $linked_memory_count memory macro leaf/leaves"
  }
}
set bounded_register_layer_records {}
set bounded_precompile_register_bits 0
if {$bounded_dc_ab} {
  if {$bounded_ab_family eq "direct"} {
    set bounded_storage_owners [get_cells -hierarchical -quiet -filter {
      ref_name =~ mrtc_shallow_1rw_way*
    }]
    set bounded_expected_storage_owners 8
    set bounded_register_layer_records [list \
      [list ring "*u_engine*u_way_ring*g_way*u_way*mem_reg*" 32768]]
  } else {
    set bounded_storage_owners [get_cells -hierarchical -quiet -filter {
      ref_name =~ mrtc_bounded_feeder_fifo_mem* ||
      ref_name =~ mrtc_shallow_1rw_way* ||
      ref_name =~ mrtc_bounded_payload_slot_mem*
    }]
    set bounded_expected_storage_owners 14
    set bounded_register_layer_records [list \
      [list feeder "*u_feeder*u_fifo_mem*mem_reg*" 16384] \
      [list ring "*u_engine*u_way_ring*g_way*u_way*mem_reg*" 32768] \
      [list payload "*u_pktbuf*u_payload_ram*g_asic_slots*g_slot*u_slot_mem*mem_reg*" 131072]]
  }
  if {[sizeof_collection $bounded_storage_owners] != $bounded_expected_storage_owners} {
    fail "bounded $bounded_ab_family register storage-owner count mismatch"
  }
  set_ungroup $bounded_storage_owners false
  redirect -file "$output_dir/bounded_storage_precompile.rpt" {
    foreach layer_record $bounded_register_layer_records {
      lassign $layer_record layer hierarchy_pattern expected_bits
      set storage_cells [get_cells -hierarchical -quiet \
        -filter "full_name =~ $hierarchy_pattern"]
      set actual_bits [sizeof_collection $storage_cells]
      echo "$layer.storage_bits=$actual_bits"
      echo "$layer.expected_storage_bits=$expected_bits"
      if {$actual_bits != $expected_bits} {
        fail "bounded register $layer storage has $actual_bits bits, expected $expected_bits"
      }
      incr bounded_precompile_register_bits $actual_bits
    }
    echo "total.storage_bits=$bounded_precompile_register_bits"
    echo "total.expected_storage_bits=$bounded_expected_bulk_bits"
  }
  if {$bounded_precompile_register_bits != $bounded_expected_bulk_bits} {
    fail "bounded register bulk-storage precompile audit failed"
  }
}
if {[catch {source $sdc} sdc_message]} {
  fail "constraint load failed: $sdc_message"
}
set expected_clock_period [require_env RDTC_CLOCK_PERIOD_NS]
set sdc_time_scale 1.0
if {[info exists ::env(RDTC_SDC_TIME_SCALE)] && $::env(RDTC_SDC_TIME_SCALE) ne ""} {
  set sdc_time_scale $::env(RDTC_SDC_TIME_SCALE)
}
set rdtc_clocks [get_clocks -quiet rdtc_clk]
if {[sizeof_collection $rdtc_clocks] != 1} {
  fail "expected exactly one rdtc_clk after loading constraints"
}
set actual_clock_period [get_attribute $rdtc_clocks period]
set expected_clock_period_in_library_units [expr {$expected_clock_period * $sdc_time_scale}]
if {[expr {abs($actual_clock_period - $expected_clock_period_in_library_units)}] > 0.0001} {
  fail "clock-period mismatch: expected $expected_clock_period_in_library_units library units, got $actual_clock_period"
}
if {[catch {compile_ultra} compile_message]} {
  fail "compile_ultra failed: $compile_message"
}
set bounded_design_rule_repair_passes 0
if {$bounded_dc_ab} {
  if {[catch {
    compile_ultra -incremental -only_design_rule
  } design_rule_repair_message]} {
    fail "bounded DC A/B design-rule repair failed: $design_rule_repair_message"
  }
  set bounded_design_rule_repair_passes 1
}

set setup_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[sizeof_collection $setup_paths] != 1} {
  fail "DC did not produce a constrained maximum-delay timing path"
}
set setup_wns [get_attribute $setup_paths slack]
if {![string is double -strict $setup_wns]} {
  fail "DC setup WNS is not numeric: $setup_wns"
}
set setup_path_collection_limit 100000
set setup_violating_path_collection [get_timing_paths -delay_type max \
  -slack_lesser_than 0.0 -max_paths $setup_path_collection_limit -nworst 1]
set setup_violating_paths [sizeof_collection $setup_violating_path_collection]
if {$setup_violating_paths >= $setup_path_collection_limit} {
  fail "DC setup violating-path collection reached its audit limit"
}
set setup_tns 0.0
foreach_in_collection setup_path $setup_violating_path_collection {
  set path_slack [get_attribute $setup_path slack]
  if {![string is double -strict $path_slack]} {
    fail "DC setup path slack is not numeric: $path_slack"
  }
  set setup_tns [expr {$setup_tns + $path_slack}]
}

if {$use_sram_macro} {
  set mapped_sram_cells [get_cells -hierarchical -quiet -filter "ref_name == $rdtc_sram_cell"]
  set mapped_sram_count [sizeof_collection $mapped_sram_cells]
  redirect -file "$output_dir/sram_macros.rpt" {
    echo "macro_cell=$rdtc_sram_cell"
    echo "expected_count=$rdtc_expected_sram_count"
    echo "mapped_count=$mapped_sram_count"
    report_cell $mapped_sram_cells
  }
  if {$mapped_sram_count != $rdtc_expected_sram_count} {
    fail "expected $rdtc_expected_sram_count mapped SRAM macros, found $mapped_sram_count"
  }
} else {
  set mapped_memory_count 0
  foreach memory_ref $forbidden_memory_refs {
    incr mapped_memory_count [sizeof_collection \
      [get_cells -hierarchical -quiet -filter "ref_name == $memory_ref"]]
  }
  if {$mapped_memory_count != 0} {
    fail "register-expanded profile mapped $mapped_memory_count memory macro leaf/leaves"
  }
}

set bounded_mapped_register_bits 0
if {$bounded_dc_ab} {
  redirect -file "$output_dir/bounded_storage.rpt" {
    foreach layer_record $bounded_register_layer_records {
      lassign $layer_record layer hierarchy_pattern expected_bits
      set storage_cells [filter_collection [all_registers] \
        "full_name =~ $hierarchy_pattern"]
      set actual_bits [sizeof_collection $storage_cells]
      echo "$layer.storage_bits=$actual_bits"
      echo "$layer.expected_storage_bits=$expected_bits"
      if {$actual_bits != $expected_bits} {
        fail "bounded register $layer storage mapped $actual_bits bits, expected $expected_bits"
      }
      incr bounded_mapped_register_bits $actual_bits
    }
    echo "total.storage_bits=$bounded_mapped_register_bits"
    echo "total.expected_storage_bits=$bounded_expected_bulk_bits"
  }
  if {$bounded_mapped_register_bits != $bounded_expected_bulk_bits} {
    fail "bounded register mapped bulk-storage audit failed"
  }
}

set seqgen_cell_count 0
set gtech_cell_count 0
set designware_cell_count 0
set unmapped_cell_count 0
if {$bounded_dc_ab} {
  set seqgen_cell_count [sizeof_collection \
    [get_cells -hierarchical -quiet -filter "ref_name =~ *SEQGEN*"]]
  set gtech_cell_count [sizeof_collection \
    [get_cells -hierarchical -quiet -filter "ref_name =~ GTECH*"]]
  set designware_cell_count [sizeof_collection \
    [get_cells -hierarchical -quiet -filter "ref_name =~ DW*"]]
  set unmapped_cell_count [expr {
    $seqgen_cell_count + $gtech_cell_count + $designware_cell_count
  }]
  if {$unmapped_cell_count != 0} {
    fail "bounded DC A/B contains unmapped/GTECH/DW/SEQGEN cells"
  }
}

set check_design_status 0
if {[catch {
  redirect -file "$output_dir/check_design.rpt" {
    set check_design_status [check_design]
  }
} check_design_message]} {
  fail "check_design failed: $check_design_message"
}
if {!$check_design_status} {
  fail "check_design reported unresolved synthesis issues; see $output_dir/check_design.rpt"
}

redirect -file "$output_dir/area_hier.rpt" {report_area -hierarchy}
redirect -file "$output_dir/area.rpt" {report_area}
redirect -file "$output_dir/timing.rpt" {
  report_timing -delay_type max -max_paths 20
}
redirect -file "$output_dir/qor.rpt" {report_qor}
redirect -file "$output_dir/references.rpt" {report_reference -hierarchy}
redirect -file "$output_dir/constraint_violations.rpt" {report_constraint -all_violators}

set raw_constraint_violating_checks 0
set default_zero_leakage_artifact_count 0
set constraint_violating_checks 0
if {$bounded_dc_ab} {
  set constraint_report_fp [open "$output_dir/constraint_violations.rpt" r]
  set constraint_report_text [read $constraint_report_fp]
  close $constraint_report_fp
  set raw_constraint_violating_checks \
    [regexp -all -nocase {\(VIOLATED\)} $constraint_report_text]
  redirect -file "$output_dir/max_leakage_power.rpt" {
    report_constraint -max_leakage_power -all_violators \
      -significant_digits 13 -nosplit
  }
  set leakage_report_fp [open "$output_dir/max_leakage_power.rpt" r]
  set leakage_report_text [read $leakage_report_fp]
  close $leakage_report_fp
  set leakage_violating_checks \
    [regexp -all -nocase {\(VIOLATED\)} $leakage_report_text]
  if {$leakage_violating_checks == 1} {
    foreach leakage_line [split $leakage_report_text "\n"] {
      if {[regexp [format {^\s*%s\s+([-+0-9.eE]+)\s+} $top] \
          $leakage_line leakage_match leakage_target] &&
          [string is double -strict $leakage_target] &&
          abs($leakage_target) <= 1.0e-18} {
        set default_zero_leakage_artifact_count 1
      }
    }
  }
  set constraint_violating_checks [expr {
    $raw_constraint_violating_checks - $default_zero_leakage_artifact_count
  }]
  if {$constraint_violating_checks < 0} {
    fail "constraint artifact classification produced a negative count"
  }
}
set dc_closure_pass [expr {
  $setup_wns >= 0.0 && abs($setup_tns) <= 1.0e-12 &&
  $setup_violating_paths == 0 && $constraint_violating_checks == 0
}]
set dc_closure_status [expr {$dc_closure_pass ? "PASS" : "FAIL"}]
redirect -file "$output_dir/run_contract.txt" {
  echo "product_profile=[require_env RDTC_PRODUCT_PROFILE]"
  echo "technology=[require_env RDTC_TECHNOLOGY]"
  echo "top=$top"
  echo "clock_period_library_units=$actual_clock_period"
  echo "documented_clock_period_ns=$expected_clock_period"
  echo "sdc_time_scale=$sdc_time_scale"
  echo "memory_mode=$configured_memory_mode"
  echo "bounded_dc_ab=$bounded_dc_ab"
  echo "bounded_asic_family=$bounded_ab_family"
  echo "bounded_bulk_storage_bits=$bounded_expected_bulk_bits"
  echo "setup_wns=$setup_wns"
  echo "setup_tns=$setup_tns"
  echo "setup_violating_paths=$setup_violating_paths"
  if {$bounded_dc_ab} {
    echo "constraint_violating_checks=$constraint_violating_checks"
    echo "bounded_design_rule_repair_passes=$bounded_design_rule_repair_passes"
    echo "seqgen_cell_count=$seqgen_cell_count"
    echo "gtech_cell_count=$gtech_cell_count"
    echo "designware_cell_count=$designware_cell_count"
    echo "unmapped_cell_count=$unmapped_cell_count"
  }
  if {$use_sram_macro} {
    echo "memory_macro_count=$mapped_sram_count"
  } else {
    echo "memory_macro_count=$mapped_memory_count"
  }
  echo "total_cell_count=[sizeof_collection [get_cells -hierarchical -quiet *]]"
  echo "stdcell_db=$approved_stdcell_db"
  echo "stdcell_db_sha256=$approved_stdcell_db_sha256"
  echo "dc_max_cores=$dc_max_cores"
}

if {[catch {
  write -format verilog -hierarchy -output "$output_dir/${top}_baseline.v"
} write_verilog_message]} {
  fail "Verilog netlist write failed: $write_verilog_message"
}
if {[catch {
  write_sdc "$output_dir/${top}_baseline.sdc"
} write_sdc_message]} {
  fail "SDC write failed: $write_sdc_message"
}
if {[catch {
  write -format ddc -hierarchy -output "$output_dir/${top}_baseline.ddc"
} write_ddc_message]} {
  fail "DDC write failed: $write_ddc_message"
}

if {$bounded_dc_ab} {
  redirect -file "$output_dir/dc_closure_summary.txt" {
    echo "status=$dc_closure_status"
    echo "setup_wns=$setup_wns"
    echo "setup_tns=$setup_tns"
    echo "setup_violating_paths=$setup_violating_paths"
    echo "constraint_violating_checks=$constraint_violating_checks"
    echo "bounded_design_rule_repair_passes=$bounded_design_rule_repair_passes"
    echo "seqgen_cell_count=$seqgen_cell_count"
    echo "gtech_cell_count=$gtech_cell_count"
    echo "designware_cell_count=$designware_cell_count"
    echo "unmapped_cell_count=$unmapped_cell_count"
    echo "retiming=disabled"
    echo "bounded_asic_family=$bounded_ab_family"
    echo "bounded_bulk_storage_bits=$bounded_expected_bulk_bits"
    echo "bounded_register_storage_bits=$bounded_mapped_register_bits"
    echo "memory_macro_count=0"
    echo "stdcell_db=$approved_stdcell_db"
    echo "stdcell_db_sha256=$approved_stdcell_db_sha256"
    echo "dc_max_cores=$dc_max_cores"
  }
  if {!$dc_closure_pass} {
    fail "DC A/B point did not close: WNS=$setup_wns TNS=$setup_tns"
  }
}

echo "INFO: RDTC DC baseline completed"
quit
