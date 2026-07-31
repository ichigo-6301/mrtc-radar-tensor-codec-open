# Common synchronous boundary contract for the bounded buffered/direct DC A/B.
# Every non-clock port is treated as synchronous to rdtc_clk. The consuming
# SoC must replace this academic 10% boundary budget with its integration SDC.
set rdtc_clock_period_ns 3.174603
if {[info exists ::env(RDTC_CLOCK_PERIOD_NS)] && $::env(RDTC_CLOCK_PERIOD_NS) ne ""} {
  set rdtc_clock_period_ns $::env(RDTC_CLOCK_PERIOD_NS)
}
set rdtc_sdc_time_scale 1.0
if {[info exists ::env(RDTC_SDC_TIME_SCALE)] && $::env(RDTC_SDC_TIME_SCALE) ne ""} {
  set rdtc_sdc_time_scale $::env(RDTC_SDC_TIME_SCALE)
}

set rdtc_clock_period [expr {$rdtc_clock_period_ns * $rdtc_sdc_time_scale}]
set rdtc_setup_uncertainty [expr {0.100 * $rdtc_sdc_time_scale}]
set rdtc_boundary_delay [expr {0.100 * $rdtc_clock_period}]

create_clock -name rdtc_clk -period $rdtc_clock_period [get_ports clk]
set_clock_uncertainty -setup $rdtc_setup_uncertainty [get_clocks rdtc_clk]
set_clock_uncertainty -hold 0.000 [get_clocks rdtc_clk]

set rdtc_sync_inputs [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay -clock rdtc_clk -max $rdtc_boundary_delay $rdtc_sync_inputs
set_input_delay -clock rdtc_clk -min 0.000 $rdtc_sync_inputs
set_output_delay -clock rdtc_clk -max $rdtc_boundary_delay [all_outputs]
set_output_delay -clock rdtc_clk -min 0.000 [all_outputs]
