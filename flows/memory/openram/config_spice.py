"""SPICE characterization config for the RDTC v1 1RW1R prefix SRAM."""

import os

word_size = 128
num_words = 64

num_rw_ports = 1
num_r_ports = 1
num_w_ports = 0
words_per_row = 2

# The default FreePDK45 replica-bitline pulse is too short to enable all 128
# write drivers. Keep the generator default available for diagnosis and make
# the reviewed value explicit in the characterized profile.
delay_chain_stages = int(os.environ.get("RDTC_OPENRAM_DELAY_CHAIN_STAGES", "21"))
delay_chain_fanout_per_stage = int(
    os.environ.get("RDTC_OPENRAM_DELAY_CHAIN_FANOUT", "4")
)

tech_name = "freepdk45"
process_corners = ["TT"]
supply_voltages = [1.1]
temperatures = [25]
use_specified_corners = [("TT", 1.1, 25)]

# Cover the extracted SRAM-output operating region rather than OpenRAM's
# three-point analytical default. The FreePDK45 base values are about 0.209 fF
# load and 5 ps slew.
if os.environ.get("RDTC_OPENRAM_CHARACTERIZATION_SMOKE") == "1":
    load_scales = [20]
    slew_scales = [16]
else:
    load_scales = [1, 4, 10, 20]
    slew_scales = [1, 4, 8, 16]

analytical_delay = False
spice_name = "ngspice"
num_sim_threads = 8
trim_netlist = True
use_pex = False
check_lvsdrc = False
use_nix = False
# Physical integration requires signal pins to be routed to the macro
# perimeter. Interior pins are sufficient for transistor-level diagnostics but
# cannot provide reliable access points to a standard-cell routing grid.
perimeter_pins = True
# OpenRAM's FreePDK45 macro examples leave top-level supplies as must-connect
# pins. Routing a monolithic supply mesh is unrelated to characterization and
# is prohibitively slow for this wide dual-port macro.
route_supplies = False

output_name = "mrtc_rdtc_prefix_1rw1r_64x128"
output_path = os.environ.get("RDTC_OPENRAM_OUTPUT", "output")
