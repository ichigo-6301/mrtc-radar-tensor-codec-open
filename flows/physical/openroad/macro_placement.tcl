if {![info exists ::env(RDTC_SRAM_MACRO)] || $::env(RDTC_SRAM_MACRO) eq ""} {
  error "RDTC_SRAM_MACRO is required for macro placement"
}
set rdtc_macro_master $::env(RDTC_SRAM_MACRO)
set rdtc_macro_names {}
set rdtc_block [ord::get_db_block]
foreach rdtc_inst [$rdtc_block getInsts] {
  if {[[$rdtc_inst getMaster] getName] eq $rdtc_macro_master} {
    lappend rdtc_macro_names [$rdtc_inst getName]
  }
}
set rdtc_macro_names [lsort $rdtc_macro_names]
if {[info exists ::env(RDTC_ORFS_PLATFORM)] && $::env(RDTC_ORFS_PLATFORM) eq "sky130hd"} {
  if {[llength $rdtc_macro_names] != 8} {
    error "Expected eight SKY130 prefix SRAM lane macros, found [llength $rdtc_macro_names]"
  }
  set rdtc_locations {
    {300 650 R0} {900 650 MY} {1500 650 R0} {2100 650 MY}
    {300 1900 MX} {900 1900 R180} {1500 1900 MX} {2100 1900 R180}
  }
  for {set index 0} {$index < 8} {incr index} {
    set placement [lindex $rdtc_locations $index]
    place_macro -macro_name [lindex $rdtc_macro_names $index] \
      -location [lrange $placement 0 1] -orientation [lindex $placement 2]
  }
} else {
  if {[llength $rdtc_macro_names] != 2} {
    error "Expected exactly two RDTC prefix SRAM macros, found [llength $rdtc_macro_names]"
  }
  place_macro -macro_name [lindex $rdtc_macro_names 0] -location {110 500} -orientation R0
  place_macro -macro_name [lindex $rdtc_macro_names 1] -location {650 500} -orientation MY
}
