"""OpenRAM configuration for the RDTC SKY130 1RW1R 64x128 prefix SRAM."""

import os

word_size = 128
num_words = 64
write_size = 128

num_rw_ports = 1
num_r_ports = 1
num_w_ports = 0
words_per_row = 1

tech_name = "sky130"
nominal_corner_only = True
process_corners = ["TT"]
supply_voltages = [1.8]
temperatures = [25]

route_supplies = True
check_lvsdrc = False
use_nix = False
analytical_delay = True

output_name = "mrtc_rdtc_prefix_1rw1r_64x128"
output_path = os.environ.get("RDTC_OPENRAM_OUTPUT", "output")
