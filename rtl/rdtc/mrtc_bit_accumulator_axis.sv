module mrtc_bit_accumulator_axis #(
  parameter int AXIS_DATA_W = 128,
  parameter int TOKEN_W     = 256
) (
  input  logic                                   clk,
  input  logic                                   rst_n,
  input  logic                                   s_token_valid,
  output logic                                   s_token_ready,
  input  logic [TOKEN_W-1:0]                     s_token_bits,
  input  logic [$clog2(TOKEN_W+1)-1:0]           s_token_len,
  input  logic                                   s_token_last,
  output logic [AXIS_DATA_W-1:0]                 m_axis_tdata,
  output logic                                   m_axis_tvalid,
  input  logic                                   m_axis_tready,
  output logic                                   m_axis_tlast,
  output logic [$clog2((AXIS_DATA_W/8)+1)-1:0]   m_axis_tvalid_bytes_minus1,
  output logic                                   o_busy,
  output logic                                   o_done,
  output logic                                   o_overflow
);
  mrtc_axis_width_packer #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .FRAG_W     (TOKEN_W)
  ) u_axis_width_packer (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .s_frag_valid            (s_token_valid),
    .s_frag_ready            (s_token_ready),
    .s_frag_data             (s_token_bits),
    .s_frag_bits             (s_token_len),
    .s_frag_last             (s_token_last),
    .m_axis_tdata            (m_axis_tdata),
    .m_axis_tvalid           (m_axis_tvalid),
    .m_axis_tready           (m_axis_tready),
    .m_axis_tlast            (m_axis_tlast),
    .m_axis_tvalid_bytes_minus1(m_axis_tvalid_bytes_minus1),
    .o_busy                  (o_busy),
    .o_done                  (o_done),
    .o_overflow              (o_overflow)
  );
endmodule
