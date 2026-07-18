"""OpenRAM configuration for the RDTC v1 64x128 prefix SRAM."""

import os

word_size = 128
num_words = 64

num_rw_ports = 0
num_r_ports = 1
num_w_ports = 1
words_per_row = 2

tech_name = "freepdk45"
nominal_corner_only = True
process_corners = ["TT"]
supply_voltages = [1.1]
temperatures = [25]

route_supplies = False
check_lvsdrc = False
use_nix = False
analytical_delay = True

output_name = "mrtc_rdtc_prefix_1r1w_64x128"
output_path = os.environ.get("RDTC_OPENRAM_OUTPUT", "output")
