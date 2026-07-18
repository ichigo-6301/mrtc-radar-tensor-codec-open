proc require_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "Missing required environment variable: $name"
  }
  return $::env($name)
}

set top [require_env RDTC_TOP]
set build_root [require_env RDTC_BUILD_ROOT]
source [require_env RDTC_DFT_SETUP]

set output_dir "$build_root/dft"
file mkdir $output_dir
current_design $top
create_test_protocol -infer_clock -infer_asynch
dft_drc -coverage_estimate > "$output_dir/dft_drc_pre.rpt"
insert_dft
dft_drc -coverage_estimate > "$output_dir/dft_drc_post.rpt"
report_scan_path > "$output_dir/scan_chains.rpt"
write -format verilog -hierarchy -output "$output_dir/${top}_scan.v"
write_test_protocol -output "$output_dir/${top}.spf"
