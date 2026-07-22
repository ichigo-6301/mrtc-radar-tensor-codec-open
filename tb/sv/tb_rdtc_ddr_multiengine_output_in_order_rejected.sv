`timescale 1ns/1ps

module tb_rdtc_ddr_multiengine_output_in_order_rejected;
  mrtc_rdtc_ddr_multiengine_wrapper #(
    .OUTPUT_IN_ORDER(1'b1)
  ) u_dut ();

  initial begin
    #10;
    $fatal(1, "OUTPUT_IN_ORDER fail-fast did not trigger");
  end
endmodule
