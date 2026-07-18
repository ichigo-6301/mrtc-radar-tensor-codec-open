proc require_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "Missing required environment variable: $name"
  }
  return $::env($name)
}

set build_root [require_env RDTC_BUILD_ROOT]
source [require_env RDTC_LEC_SETUP]

set output_dir "$build_root/lec"
file mkdir $output_dir
match
verify
report_unmatched_points > "$output_dir/unmatched_points.rpt"
report_failing_points > "$output_dir/failing_points.rpt"
