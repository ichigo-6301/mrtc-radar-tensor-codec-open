if {![info exists ::env(RDTC_GRT_HOLD_SLACK_MARGIN_NS)] ||
    $::env(RDTC_GRT_HOLD_SLACK_MARGIN_NS) eq ""} {
  error "RDTC_GRT_HOLD_SLACK_MARGIN_NS is required"
}

puts "RDTC global-route hold margin: $::env(RDTC_GRT_HOLD_SLACK_MARGIN_NS) ns"
set ::env(HOLD_SLACK_MARGIN) $::env(RDTC_GRT_HOLD_SLACK_MARGIN_NS)

# Design Compiler writes logic constants as supply1/supply0 nets. OpenDB then
# classifies them as POWER/GROUND, but they are routed logic signals rather
# than PDN special nets. Keep the real VDD/VSS nets unchanged.
set rdtc_block [[[ord::get_db] getChip] getBlock]
set rdtc_constant_net_count 0
foreach rdtc_constant_net [$rdtc_block getNets] {
  set rdtc_constant_net_name [$rdtc_constant_net getName]
  if {[regexp {(^|/)(one_|zero_)$} $rdtc_constant_net_name]} {
    puts "RDTC constant net $rdtc_constant_net_name: [$rdtc_constant_net getSigType] -> SIGNAL"
    $rdtc_constant_net setSigType SIGNAL
    incr rdtc_constant_net_count
  }
}
puts "RDTC normalized constant-net count: $rdtc_constant_net_count"
