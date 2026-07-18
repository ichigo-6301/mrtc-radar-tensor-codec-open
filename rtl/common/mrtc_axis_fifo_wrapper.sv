module mrtc_axis_fifo_wrapper #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W     = 8,
  parameter int DEPTH_BEATS = 16,
  parameter int FIFO_IMPL   = 0,  // 0=GENERIC_SIMPLE, 1=XPM_SYNC, 2=reserved
  parameter FPGA_RAM_STYLE = "block",
  parameter int LEVEL_W     = (DEPTH_BEATS <= 1) ? 1 : $clog2(DEPTH_BEATS + 1)
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_clear_status,
  input  logic [AXIS_DATA_W-1:0] s_axis_tdata,
  input  logic                   s_axis_tvalid,
  output logic                   s_axis_tready,
  input  logic                   s_axis_tlast,
  input  logic [TUSER_W-1:0]     s_axis_tuser,
  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready,
  output logic                   m_axis_tlast,
  output logic [TUSER_W-1:0]     m_axis_tuser,
  output logic [LEVEL_W-1:0]     o_level,
  output logic                   o_full,
  output logic                   o_empty,
  output logic                   o_overflow_error,
  output logic                   o_underflow_error,
  output logic [LEVEL_W-1:0]     o_max_level,
  output logic [31:0]            o_full_cycles
);
  localparam int DEPTH_CHECK = 1 / ((DEPTH_BEATS > 0) ? 1 : 0);
  localparam int FIFO_W = AXIS_DATA_W + TUSER_W + 1;

  generate
    if (FIFO_IMPL == 0) begin : g_generic_simple
      mrtc_axis_fifo_simple #(
        .AXIS_DATA_W(AXIS_DATA_W),
        .TUSER_W    (TUSER_W),
        .DEPTH_BEATS(DEPTH_BEATS),
        .LEVEL_W    (LEVEL_W)
      ) u_fifo (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_clear_status   (i_clear_status),
        .s_axis_tdata     (s_axis_tdata),
        .s_axis_tvalid    (s_axis_tvalid),
        .s_axis_tready    (s_axis_tready),
        .s_axis_tlast     (s_axis_tlast),
        .s_axis_tuser     (s_axis_tuser),
        .m_axis_tdata     (m_axis_tdata),
        .m_axis_tvalid    (m_axis_tvalid),
        .m_axis_tready    (m_axis_tready),
        .m_axis_tlast     (m_axis_tlast),
        .m_axis_tuser     (m_axis_tuser),
        .o_level          (o_level),
        .o_full           (o_full),
        .o_empty          (o_empty),
        .o_overflow_error (o_overflow_error),
        .o_underflow_error(o_underflow_error),
        .o_max_level      (o_max_level),
        .o_full_cycles    (o_full_cycles)
      );
    end else if (FIFO_IMPL == 1) begin : g_xpm_sync
      logic [FIFO_W-1:0] xpm_din;
      logic [FIFO_W-1:0] xpm_dout;
      logic              xpm_full;
      logic              xpm_empty;
      logic              xpm_overflow;
      logic              xpm_underflow;
      logic              xpm_wr_rst_busy;
      logic              xpm_rd_rst_busy;
      logic [LEVEL_W-1:0] xpm_wr_count;
      logic              write_fire;
      logic              read_fire;

      assign xpm_din = {s_axis_tlast, s_axis_tuser, s_axis_tdata};
      assign {m_axis_tlast, m_axis_tuser, m_axis_tdata} = xpm_dout;
      assign o_full = xpm_full;
      assign o_empty = xpm_empty;
      assign o_level = xpm_wr_count;
      assign s_axis_tready = !xpm_full && !xpm_wr_rst_busy;
      assign m_axis_tvalid = !xpm_empty && !xpm_rd_rst_busy;
      assign write_fire = s_axis_tvalid && s_axis_tready;
      assign read_fire = m_axis_tvalid && m_axis_tready;

      xpm_fifo_sync #(
        .DOUT_RESET_VALUE   ("0"),
        .ECC_MODE           ("no_ecc"),
        .FIFO_MEMORY_TYPE   (FPGA_RAM_STYLE),
        .FIFO_READ_LATENCY  (0),
        .FIFO_WRITE_DEPTH   (DEPTH_BEATS),
        .FULL_RESET_VALUE   (0),
        .PROG_EMPTY_THRESH  (10),
        .PROG_FULL_THRESH   (DEPTH_BEATS > 16 ? DEPTH_BEATS - 8 : DEPTH_BEATS - 1),
        .RD_DATA_COUNT_WIDTH(LEVEL_W),
        .READ_DATA_WIDTH    (FIFO_W),
        .READ_MODE          ("fwft"),
        .SIM_ASSERT_CHK     (0),
        .USE_ADV_FEATURES   ("0707"),
        .WAKEUP_TIME        (0),
        .WRITE_DATA_WIDTH   (FIFO_W),
        .WR_DATA_COUNT_WIDTH(LEVEL_W)
      ) u_xpm_fifo_sync (
        .sleep        (1'b0),
        .rst          (!rst_n),
        .wr_clk       (clk),
        .wr_en        (write_fire),
        .din          (xpm_din),
        .full         (xpm_full),
        .prog_full    (),
        .wr_data_count(xpm_wr_count),
        .overflow     (xpm_overflow),
        .wr_rst_busy  (xpm_wr_rst_busy),
        .almost_full  (),
        .wr_ack       (),
        .rd_en        (read_fire),
        .dout         (xpm_dout),
        .empty        (xpm_empty),
        .prog_empty   (),
        .rd_data_count(),
        .underflow    (xpm_underflow),
        .rd_rst_busy  (xpm_rd_rst_busy),
        .data_valid   (),
        .almost_empty (),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0),
        .sbiterr      (),
        .dbiterr      ()
      );

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          o_overflow_error <= 1'b0;
          o_underflow_error <= 1'b0;
          o_max_level <= '0;
          o_full_cycles <= 32'd0;
        end else begin
          if (i_clear_status) begin
            o_overflow_error <= 1'b0;
            o_underflow_error <= 1'b0;
            o_max_level <= o_level;
            o_full_cycles <= 32'd0;
          end else begin
            o_overflow_error <= o_overflow_error || xpm_overflow;
            o_underflow_error <= o_underflow_error || xpm_underflow;
            if (o_full) begin
              o_full_cycles <= o_full_cycles + 32'd1;
            end
            if (o_level > o_max_level) begin
              o_max_level <= o_level;
            end
          end
        end
      end
    end else begin : g_reserved_impl
      localparam int UNSUPPORTED_FIFO_IMPL = 1 / ((FIFO_IMPL == 0) ? 1 : 0);
    end
  endgenerate
endmodule
