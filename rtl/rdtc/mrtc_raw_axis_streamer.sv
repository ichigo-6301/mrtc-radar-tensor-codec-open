module mrtc_raw_axis_streamer #(
  parameter int AXIS_DATA_W = 128,
  parameter int RAW_BYTES = 4096
) (
  input  logic                               clk,
  input  logic                               rst_n,
  input  logic                               i_start,
  input  logic [(RAW_BYTES*8)-1:0]           i_raw_flat,
  output logic [AXIS_DATA_W-1:0]             m_axis_tdata,
  output logic                               m_axis_tvalid,
  input  logic                               m_axis_tready,
  output logic                               m_axis_tlast,
  output logic [$clog2((AXIS_DATA_W/8)+1)-1:0] m_axis_tvalid_bytes_minus1,
  output logic                               o_busy,
  output logic                               o_done
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int VALID_BYTE_COUNT_W = $clog2(AXIS_BYTES + 1);
  localparam int AXIS_WIDTH_SUPPORTED_CHECK =
    1 / (((AXIS_DATA_W == 32) ||
          (AXIS_DATA_W == 64) ||
          (AXIS_DATA_W == 128) ||
          (AXIS_DATA_W == 256) ||
          (AXIS_DATA_W == 512)) ? 1 : 0);
  localparam int RAW_BYTE_ALIGN_CHECK = 1 / (((RAW_BYTES % 4) == 0) ? 1 : 0);

  logic busy_reg;
  logic [$clog2(RAW_BYTES+1)-1:0] byte_idx_reg;
  integer byte_idx;
  integer remain_bytes;

  assign o_busy = busy_reg;
  assign m_axis_tvalid = busy_reg;
  assign m_axis_tlast = busy_reg && ((byte_idx_reg + AXIS_BYTES) >= RAW_BYTES);

  always_comb begin
    m_axis_tdata = '0;
    remain_bytes = RAW_BYTES - byte_idx_reg;
    if (remain_bytes >= AXIS_BYTES) begin
      m_axis_tvalid_bytes_minus1 = VALID_BYTE_COUNT_W'(AXIS_BYTES - 1);
    end else begin
      m_axis_tvalid_bytes_minus1 = VALID_BYTE_COUNT_W'(remain_bytes - 1);
    end

    for (byte_idx = 0; byte_idx < AXIS_BYTES; byte_idx = byte_idx + 1) begin
      if ((byte_idx_reg + byte_idx) < RAW_BYTES) begin
        m_axis_tdata[(byte_idx*8) +: 8] = i_raw_flat[((byte_idx_reg + byte_idx)*8) +: 8];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_reg <= 1'b0;
      byte_idx_reg <= '0;
      o_done <= 1'b0;
    end else begin
      o_done <= 1'b0;
      if (!busy_reg) begin
        if (i_start) begin
          busy_reg <= 1'b1;
          byte_idx_reg <= '0;
        end
      end else if (m_axis_tvalid && m_axis_tready) begin
        if ((byte_idx_reg + AXIS_BYTES) >= RAW_BYTES) begin
          busy_reg <= 1'b0;
          byte_idx_reg <= '0;
          o_done <= 1'b1;
        end else begin
          byte_idx_reg <= byte_idx_reg + AXIS_BYTES;
        end
      end
    end
  end
endmodule
