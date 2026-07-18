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

proc require_routing_directions {} {
  set horizontal [get_layers -quiet -filter \
    {is_routing_layer == true && routing_direction == horizontal && pitch > 0 && default_width > 0}]
  set vertical [get_layers -quiet -filter \
    {is_routing_layer == true && routing_direction == vertical && pitch > 0 && default_width > 0}]
  if {[sizeof_collection $horizontal] == 0 || [sizeof_collection $vertical] == 0} {
    error "Technology must contain horizontal and vertical routing layers"
  }
}

proc create_rdtc_workspace {name tech_file tech_lef tech_name tech_layers \
                            site_name site_width site_height} {
  if {$tech_file ne "" && $tech_lef ne ""} {
    error "Define only one of rdtc_tech_file or rdtc_tech_lef"
  }

  if {$tech_file ne "" || $tech_lef ne ""} {
    if {$tech_file ne ""} {require_file $tech_file "technology file"}
    if {$tech_lef ne ""} {require_file $tech_lef "technology LEF"}
    if {$tech_file ne ""} {
      create_workspace $name -technology $tech_file
    } else {
      if {$tech_name eq "" || [llength $tech_layers] == 0} {
        error "Technology-LEF mode requires rdtc_tech_name and rdtc_tech_layers"
      }
      create_workspace $name
      set tech [create_tech $tech_name]
      foreach {layer_name layer_number layer_type routing_direction} $tech_layers {
        create_layer -tech $tech -name $layer_name -number $layer_number \
          -layer_type $layer_type
      }
      if {$site_name ne ""} {
        create_site_def -tech $tech -name $site_name -width $site_width \
          -height $site_height -type core -symmetry {X Y}
      }
    }

    set mask_order 0
    foreach {layer_name layer_number layer_type routing_direction} $tech_layers {
      set layer [get_layers -quiet -exact $layer_name]
      if {[sizeof_collection $layer] != 1} {
        error "Technology is missing configured layer $layer_name"
      }
      if {$tech_lef ne ""} {
        set_attribute -objects $layer -name mask_order -value $mask_order
      }
      if {$routing_direction ne ""} {
        set_attribute -objects $layer -name routing_direction -value $routing_direction
      }
      incr mask_order
    }
  } else {
    error "Local setup must define rdtc_tech_file or rdtc_tech_lef"
  }
}

if {[catch {
  set build_root [require_env RDTC_BUILD_ROOT]
  source [require_env RDTC_ICC2_SETUP]

  foreach {path label} [list \
    $rdtc_stdcell_db "standard-cell DB" \
    $rdtc_stdcell_lef "standard-cell LEF" \
    $rdtc_sram_db "SRAM DB" \
    $rdtc_sram_lef "SRAM LEF"] {
    require_file $path $label
  }

  set output_dir "$build_root/icc2_libs"
  file mkdir $output_dir
  foreach ndm [list $rdtc_stdcell_ndm $rdtc_sram_ndm] {
    if {[file exists $ndm]} {
      file delete -force $ndm
    }
  }

  if {![info exists rdtc_tech_file]} {set rdtc_tech_file ""}
  if {![info exists rdtc_tech_lef]} {set rdtc_tech_lef ""}
  if {![info exists rdtc_tech_name]} {set rdtc_tech_name ""}
  if {![info exists rdtc_tech_layers]} {set rdtc_tech_layers {}}
  if {![info exists rdtc_site_name]} {set rdtc_site_name ""}
  if {![info exists rdtc_site_width]} {set rdtc_site_width 0}
  if {![info exists rdtc_site_height]} {set rdtc_site_height 0}
  if {![info exists rdtc_stdcell_workspace]} {set rdtc_stdcell_workspace rdtc_stdcell}
  if {![info exists rdtc_sram_workspace]} {set rdtc_sram_workspace rdtc_memory}
  create_rdtc_workspace $rdtc_stdcell_workspace $rdtc_tech_file $rdtc_tech_lef \
    $rdtc_tech_name $rdtc_tech_layers $rdtc_site_name $rdtc_site_width $rdtc_site_height
  read_db $rdtc_stdcell_db
  if {$rdtc_tech_lef ne "" && \
      [file normalize $rdtc_tech_lef] eq [file normalize $rdtc_stdcell_lef]} {
    read_lef -library $rdtc_stdcell_library -include {tech cell} \
      -merge_action overwrite $rdtc_stdcell_lef
  } elseif {$rdtc_tech_lef ne ""} {
    if {$rdtc_tech_lef ne ""} {
      read_lef -library $rdtc_stdcell_library -include tech \
        -merge_action overwrite $rdtc_tech_lef
    }
    read_lef -library $rdtc_stdcell_library -include cell $rdtc_stdcell_lef
  } else {
    read_lef $rdtc_stdcell_lef
  }
  require_routing_directions
  redirect -file "$output_dir/check_stdcell_workspace.rpt" {check_workspace}
  commit_workspace -output $rdtc_stdcell_ndm
  remove_workspace

  create_rdtc_workspace $rdtc_sram_workspace $rdtc_tech_file $rdtc_tech_lef \
    $rdtc_tech_name $rdtc_tech_layers $rdtc_site_name $rdtc_site_width $rdtc_site_height
  read_lef -include tech $rdtc_stdcell_lef
  read_db $rdtc_sram_db
  read_lef -include cell $rdtc_sram_lef
  require_routing_directions
  redirect -file "$output_dir/check_sram_workspace.rpt" {check_workspace}
  commit_workspace -output $rdtc_sram_ndm

  foreach ndm [list $rdtc_stdcell_ndm $rdtc_sram_ndm] {
    if {![file exists $ndm]} {
      error "ICC2 Library Manager did not create $ndm"
    }
  }
  puts "INFO: ICC2 reference libraries completed: $rdtc_stdcell_ndm $rdtc_sram_ndm"
} message]} {
  puts stderr "ERROR: ICC2 reference-library build failed: $message"
  exit 1
}
exit 0
