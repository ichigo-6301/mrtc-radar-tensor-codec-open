module mrtc_scoreboard_stub;
  import mrtc_dpi_pkg::*;

  // Future RTL encoder scoreboard flow:
  // collect one raw block, call dpi_mrtc_rdtc_encode_block,
  // compare RTL header/payload bytes, then optionally decode and compare I/Q.
endmodule
