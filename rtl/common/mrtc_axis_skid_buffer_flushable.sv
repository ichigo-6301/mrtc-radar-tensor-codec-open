module mrtc_axis_skid_buffer_flushable #(
  parameter int DATA_W = 128,
  parameter int TUSER_W = 8
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               i_flush,
  input  logic [DATA_W-1:0]  s_tdata,
  input  logic [TUSER_W-1:0] s_tuser,
  input  logic               s_tvalid,
  input  logic               s_tlast,
  output logic               s_tready,
  output logic [DATA_W-1:0]  m_tdata,
  output logic [TUSER_W-1:0] m_tuser,
  output logic               m_tvalid,
  output logic               m_tlast,
  input  logic               m_tready
);
  logic [DATA_W-1:0] hold_data;
  logic [TUSER_W-1:0] hold_user;
  logic hold_last;
  logic hold_valid;

  assign s_tready = !i_flush && (!hold_valid || m_tready);
  assign m_tvalid = hold_valid;
  assign m_tdata = hold_data;
  assign m_tuser = hold_user;
  assign m_tlast = hold_last;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hold_valid <= 1'b0;
      hold_data <= '0;
      hold_user <= '0;
      hold_last <= 1'b0;
    end else if (i_flush) begin
      hold_valid <= 1'b0;
      hold_data <= '0;
      hold_user <= '0;
      hold_last <= 1'b0;
    end else if (s_tready) begin
      hold_valid <= s_tvalid;
      hold_data <= s_tdata;
      hold_user <= s_tuser;
      hold_last <= s_tlast;
    end
  end
endmodule
