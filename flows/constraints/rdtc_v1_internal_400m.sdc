# Internal-clock synthesis constraint for the RDTC v1 wrapper profile.
# Integration-level IO delays, generated clocks, asynchronous groups, and exceptions
# belong to the consuming SoC profile and are intentionally not claimed here.
set rdtc_clock_period_ns 2.500
if {[info exists ::env(RDTC_CLOCK_PERIOD_NS)] && $::env(RDTC_CLOCK_PERIOD_NS) ne ""} {
  set rdtc_clock_period_ns $::env(RDTC_CLOCK_PERIOD_NS)
}
set rdtc_sdc_time_scale 1.0
if {[info exists ::env(RDTC_SDC_TIME_SCALE)] && $::env(RDTC_SDC_TIME_SCALE) ne ""} {
  set rdtc_sdc_time_scale $::env(RDTC_SDC_TIME_SCALE)
}
set rdtc_clock_period [expr {$rdtc_clock_period_ns * $rdtc_sdc_time_scale}]
set rdtc_setup_uncertainty [expr {0.100 * $rdtc_sdc_time_scale}]
create_clock -name rdtc_clk -period $rdtc_clock_period [get_ports clk]
set_clock_uncertainty -setup $rdtc_setup_uncertainty [get_clocks rdtc_clk]
# Same-edge hold uses the propagated clock in this nominal academic profile.
# OCV and jitter are not modeled here and must be added by a signoff profile.
set_clock_uncertainty -hold 0.000 [get_clocks rdtc_clk]
