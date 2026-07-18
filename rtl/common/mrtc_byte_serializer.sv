module mrtc_byte_serializer #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W = 8
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  s_byte_valid,
  output logic                  s_byte_ready,
  input  logic [7:0]            s_byte_data,
  input  logic                  s_byte_last,
  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic                  m_axis_tvalid,
  input  logic                  m_axis_tready,
  output logic                  m_axis_tlast,
  output logic [TUSER_W-1:0]    m_axis_tuser,
  output logic                  o_busy
);
  // Legacy helper: this path ingests one byte per cycle and is kept for
  // debug/compatibility. Stage 16B-1A does not use it as the new
  // AXIS-width high-throughput compressed output datapath.
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;

  logic [AXIS_DATA_W-1:0] data_reg;
  logic [4:0]            byte_count_reg;
  logic                  out_valid_reg;
  logic                  out_last_reg;
  logic [TUSER_W-1:0]    out_user_reg;

  assign s_byte_ready = !out_valid_reg;
  assign m_axis_tdata = data_reg;
  assign m_axis_tvalid = out_valid_reg;
  assign m_axis_tlast = out_last_reg;
  assign m_axis_tuser = out_user_reg;
  assign o_busy = out_valid_reg || (byte_count_reg != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_reg       <= '0;
      byte_count_reg <= '0;
      out_valid_reg  <= 1'b0;
      out_last_reg   <= 1'b0;
      out_user_reg   <= '0;
    end else begin
      if (out_valid_reg && m_axis_tready) begin
        out_valid_reg  <= 1'b0;
        out_last_reg   <= 1'b0;
        out_user_reg   <= '0;
        data_reg       <= '0;
        byte_count_reg <= '0;
      end

      if (s_byte_valid && s_byte_ready) begin
        data_reg[byte_count_reg*8 +: 8] <= s_byte_data;
        if (s_byte_last || (byte_count_reg == AXIS_BYTES-1)) begin
          out_valid_reg             <= 1'b1;
          out_last_reg              <= s_byte_last;
          out_user_reg              <= '0;
          out_user_reg[3:0]         <= byte_count_reg[3:0];
        end
        byte_count_reg <= (s_byte_last || (byte_count_reg == AXIS_BYTES-1)) ? 5'd0 : (byte_count_reg + 5'd1);
      end
    end
  end
endmodule
