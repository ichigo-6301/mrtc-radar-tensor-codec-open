module mrtc_axis_packet_arbiter #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W     = 8
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic [AXIS_DATA_W-1:0] s0_axis_tdata,
  input  logic                   s0_axis_tvalid,
  output logic                   s0_axis_tready,
  input  logic                   s0_axis_tlast,
  input  logic [TUSER_W-1:0]     s0_axis_tuser,
  input  logic [AXIS_DATA_W-1:0] s1_axis_tdata,
  input  logic                   s1_axis_tvalid,
  output logic                   s1_axis_tready,
  input  logic                   s1_axis_tlast,
  input  logic [TUSER_W-1:0]     s1_axis_tuser,
  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready,
  output logic                   m_axis_tlast,
  output logic [TUSER_W-1:0]     m_axis_tuser,
  output logic                   o_active_sel,
  output logic                   o_active_valid,
  output logic [31:0]            o_packet_count,
  output logic [31:0]            o_idle_cycles,
  output logic [31:0]            o_backpressure_cycles,
  output logic [31:0]            o_error_flags
);
  localparam logic [31:0] ERR_NONE = 32'd0;

  logic lock_reg;
  logic active_sel_reg;
  logic rr_next_reg;
  logic sel_comb;
  logic sel_valid_comb;
  logic selected_tvalid;
  logic selected_tlast;
  logic selected_accept;

  always_comb begin
    sel_comb = active_sel_reg;
    sel_valid_comb = 1'b0;
    if (lock_reg) begin
      sel_comb = active_sel_reg;
      sel_valid_comb = 1'b1;
    end else if (s0_axis_tvalid && s1_axis_tvalid) begin
      sel_comb = rr_next_reg;
      sel_valid_comb = 1'b1;
    end else if (s0_axis_tvalid) begin
      sel_comb = 1'b0;
      sel_valid_comb = 1'b1;
    end else if (s1_axis_tvalid) begin
      sel_comb = 1'b1;
      sel_valid_comb = 1'b1;
    end
  end

  assign selected_tvalid = sel_comb ? s1_axis_tvalid : s0_axis_tvalid;
  assign selected_tlast  = sel_comb ? s1_axis_tlast  : s0_axis_tlast;
  assign selected_accept = sel_valid_comb && selected_tvalid && m_axis_tready;

  assign m_axis_tdata  = sel_comb ? s1_axis_tdata  : s0_axis_tdata;
  assign m_axis_tvalid = sel_valid_comb && selected_tvalid;
  assign m_axis_tlast  = sel_comb ? s1_axis_tlast  : s0_axis_tlast;
  assign m_axis_tuser  = sel_comb ? s1_axis_tuser  : s0_axis_tuser;

  assign s0_axis_tready = sel_valid_comb && !sel_comb && m_axis_tready;
  assign s1_axis_tready = sel_valid_comb &&  sel_comb && m_axis_tready;

  assign o_active_sel = sel_comb;
  assign o_active_valid = sel_valid_comb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lock_reg <= 1'b0;
      active_sel_reg <= 1'b0;
      rr_next_reg <= 1'b0;
      o_packet_count <= 32'd0;
      o_idle_cycles <= 32'd0;
      o_backpressure_cycles <= 32'd0;
      o_error_flags <= ERR_NONE;
    end else begin
      if (m_axis_tvalid && !m_axis_tready) begin
        o_backpressure_cycles <= o_backpressure_cycles + 32'd1;
      end
      if (!m_axis_tvalid) begin
        o_idle_cycles <= o_idle_cycles + 32'd1;
      end

      if (!lock_reg && sel_valid_comb && selected_tvalid && !selected_tlast) begin
        lock_reg <= 1'b1;
        active_sel_reg <= sel_comb;
      end

      if (selected_accept && selected_tlast) begin
        lock_reg <= 1'b0;
        active_sel_reg <= sel_comb;
        rr_next_reg <= ~sel_comb;
        o_packet_count <= o_packet_count + 32'd1;
      end else if (selected_accept && !lock_reg) begin
        active_sel_reg <= sel_comb;
      end
    end
  end
endmodule
