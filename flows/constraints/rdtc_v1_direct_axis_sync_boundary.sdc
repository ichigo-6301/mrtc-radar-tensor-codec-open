# Academic block-level timing contract for the bounded direct-AXIS wrapper.
# All non-clock inputs and all outputs are synchronous to rdtc_clk. The
# consuming integration must replace the 10% boundary budgets with its real
# board or SoC timing. rst_n may assert asynchronously, but its release is
# required to be synchronized externally and is intentionally not false-pathed.
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
set rdtc_boundary_delay [expr {0.100 * $rdtc_clock_period}]

create_clock -name rdtc_clk -period $rdtc_clock_period [get_ports clk]
set_clock_uncertainty -setup $rdtc_setup_uncertainty [get_clocks rdtc_clk]
# Same-edge hold uses the propagated clock in this nominal academic profile.
# OCV and jitter are not modeled here and must be added by a signoff profile.
set_clock_uncertainty -hold 0.000 [get_clocks rdtc_clk]

set rdtc_sync_inputs [get_ports {
  rst_n
  i_clear_status
  s_desc_valid
  s_desc_block_id*
  s_desc_block_range_start*
  s_desc_frame_id*
  s_desc_codec_mode*
  s_desc_rice_mode*
  s_desc_fixed_k*
  s_desc_tensor_spatial_size*
  s_desc_tensor_doppler_size*
  s_desc_tensor_range_size*
  s_desc_last_block
  s_axis_raw_tdata*
  s_axis_raw_tvalid
  s_axis_raw_tlast
  m_axis_comp_tready
}]
set_input_delay -clock rdtc_clk -max $rdtc_boundary_delay $rdtc_sync_inputs
set_input_delay -clock rdtc_clk -min 0.000 $rdtc_sync_inputs
set_output_delay -clock rdtc_clk -max $rdtc_boundary_delay [all_outputs]
set_output_delay -clock rdtc_clk -min 0.000 [all_outputs]
