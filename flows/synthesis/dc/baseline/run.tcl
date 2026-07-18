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

set root [require_env RDTC_FLOW_ROOT]
set filelist [require_env RDTC_FILELIST]
set top [require_env RDTC_TOP]
set sdc [require_env RDTC_SDC]
set build_root [require_env RDTC_BUILD_ROOT]
source [require_env RDTC_DC_SETUP]

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
set configured_memory_mode [require_env RDTC_MEMORY_MODE]
if {$configured_memory_mode eq "registers" && $use_sram_macro} {
  fail "register-expanded profile selected a macro-aware DC setup"
}
if {$configured_memory_mode eq "macro" && !$use_sram_macro} {
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
if {![info exists rdtc_memory_model_files]} {set rdtc_memory_model_files {}}
foreach memory_model $rdtc_memory_model_files {
  if {![file isfile $memory_model]} {
    fail "Missing local memory model: $memory_model"
  }
  lappend rtl_files $memory_model
}
if {$use_sram_macro} {
  set analyze_command [list analyze -format sverilog]
  foreach define $rdtc_rtl_defines {
    lappend analyze_command -define $define
  }
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
} else {
  set forbidden_memory_refs [list \
    mrtc_rdtc_prefix_1r1w_64x128 \
    mrtc_rdtc_prefix_1rw1r_64x128 \
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
redirect -file "$output_dir/timing.rpt" {report_timing -max_paths 20}
redirect -file "$output_dir/qor.rpt" {report_qor}
redirect -file "$output_dir/references.rpt" {report_reference -hierarchy}
redirect -file "$output_dir/constraint_violations.rpt" {report_constraint -all_violators}
redirect -file "$output_dir/run_contract.txt" {
  echo "product_profile=[require_env RDTC_PRODUCT_PROFILE]"
  echo "technology=[require_env RDTC_TECHNOLOGY]"
  echo "top=$top"
  echo "clock_period_library_units=$actual_clock_period"
  echo "documented_clock_period_ns=$expected_clock_period"
  echo "sdc_time_scale=$sdc_time_scale"
  echo "memory_mode=$configured_memory_mode"
  if {$use_sram_macro} {
    echo "memory_macro_count=$mapped_sram_count"
  } else {
    echo "memory_macro_count=$mapped_memory_count"
  }
  echo "total_cell_count=[sizeof_collection [get_cells -hierarchical -quiet *]]"
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

echo "INFO: RDTC DC baseline completed"
quit
