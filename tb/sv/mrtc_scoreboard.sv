module mrtc_scoreboard #(
  parameter string CASE_DIR = "",
  parameter string EXPECTED_HEX_FILE = "axis_comp_expected.hex",
  parameter string EXPECTED_CTRL_FILE = "axis_comp_expected_ctrl.csv"
) (
  input logic i_compare_start,
  input integer i_byte_count,
  input integer i_beat_count,
  input byte i_bytes [0:32767],
  output logic o_pass
);
  integer first_mismatch;
  byte expected_byte;
  byte actual_byte;

  mrtc_file_compare #(
    .CASE_DIR(CASE_DIR),
    .EXPECTED_HEX_FILE(EXPECTED_HEX_FILE),
    .EXPECTED_CTRL_FILE(EXPECTED_CTRL_FILE)
  ) u_file_compare (
    .i_start(i_compare_start),
    .i_actual_byte_count(i_byte_count),
    .i_actual_beat_count(i_beat_count),
    .i_actual_bytes(i_bytes),
    .o_pass(o_pass),
    .o_first_mismatch(first_mismatch),
    .o_expected_byte(expected_byte),
    .o_actual_byte(actual_byte)
  );

  always @(*) begin
    if (i_compare_start && !o_pass && (first_mismatch >= 0)) begin
      $display("MISMATCH case=%s idx=%0d expected=%02x actual=%02x", CASE_DIR, first_mismatch, expected_byte, actual_byte);
    end
  end
endmodule
