module mrtc_comp_input_unpack #(
  parameter int AXIS_DATA_W = 128
) (
  input  logic [AXIS_DATA_W-1:0] i_tdata,
  output logic [7:0]             o_byte0,
  output logic [7:0]             o_byte1,
  output logic [7:0]             o_byte2,
  output logic [7:0]             o_byte3,
  output logic [7:0]             o_byte4,
  output logic [7:0]             o_byte5,
  output logic [7:0]             o_byte6,
  output logic [7:0]             o_byte7,
  output logic [7:0]             o_byte8,
  output logic [7:0]             o_byte9,
  output logic [7:0]             o_byte10,
  output logic [7:0]             o_byte11,
  output logic [7:0]             o_byte12,
  output logic [7:0]             o_byte13,
  output logic [7:0]             o_byte14,
  output logic [7:0]             o_byte15
);
  assign o_byte0  = i_tdata[7:0];
  assign o_byte1  = i_tdata[15:8];
  assign o_byte2  = i_tdata[23:16];
  assign o_byte3  = i_tdata[31:24];
  assign o_byte4  = i_tdata[39:32];
  assign o_byte5  = i_tdata[47:40];
  assign o_byte6  = i_tdata[55:48];
  assign o_byte7  = i_tdata[63:56];
  assign o_byte8  = i_tdata[71:64];
  assign o_byte9  = i_tdata[79:72];
  assign o_byte10 = i_tdata[87:80];
  assign o_byte11 = i_tdata[95:88];
  assign o_byte12 = i_tdata[103:96];
  assign o_byte13 = i_tdata[111:104];
  assign o_byte14 = i_tdata[119:112];
  assign o_byte15 = i_tdata[127:120];
endmodule
