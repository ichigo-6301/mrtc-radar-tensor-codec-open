module mrtc_axis_packet_arbiter_nlane #(
  parameter int NUM_LANES   = 2,
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W     = 8,
  parameter int LANE_W      = (NUM_LANES <= 1) ? 1 : $clog2(NUM_LANES)
) (
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic [NUM_LANES*AXIS_DATA_W-1:0] s_axis_tdata_flat,
  input  logic [NUM_LANES-1:0]            s_axis_tvalid,
  output logic [NUM_LANES-1:0]            s_axis_tready,
  input  logic [NUM_LANES-1:0]            s_axis_tlast,
  input  logic [NUM_LANES*TUSER_W-1:0]    s_axis_tuser_flat,
  output logic [AXIS_DATA_W-1:0]          m_axis_tdata,
  output logic                            m_axis_tvalid,
  input  logic                            m_axis_tready,
  output logic                            m_axis_tlast,
  output logic [TUSER_W-1:0]              m_axis_tuser,
  output logic [LANE_W-1:0]               o_active_lane,
  output logic                            o_active_valid,
  output logic [31:0]                     o_packet_count,
  output logic [31:0]                     o_idle_cycles,
  output logic [31:0]                     o_backpressure_cycles,
  output logic [31:0]                     o_error_flags
);
  localparam int NUM_LANES_CHECK =
    1 / (((NUM_LANES == 2) || (NUM_LANES == 4)) ? 1 : 0);
  localparam logic [31:0] ERR_NONE = 32'd0;

  logic lock_reg;
  logic [LANE_W-1:0] active_lane_reg;
  logic [LANE_W-1:0] rr_next_reg;
  logic [LANE_W-1:0] sel_comb;
  logic sel_valid_comb;
  logic selected_tvalid;
  logic selected_tlast;
  logic selected_accept;
  logic [AXIS_DATA_W-1:0] lane_tdata [0:NUM_LANES-1];
  logic [TUSER_W-1:0] lane_tuser [0:NUM_LANES-1];

  generate
    genvar lane_idx;
    for (lane_idx = 0; lane_idx < NUM_LANES; lane_idx = lane_idx + 1) begin : g_lane_unpack
      assign lane_tdata[lane_idx] =
        s_axis_tdata_flat[(lane_idx * AXIS_DATA_W) +: AXIS_DATA_W];
      assign lane_tuser[lane_idx] =
        s_axis_tuser_flat[(lane_idx * TUSER_W) +: TUSER_W];
    end
  endgenerate

  function automatic logic [LANE_W-1:0] lane_next(
    input logic [LANE_W-1:0] lane_id
  );
    if (int'(lane_id) == (NUM_LANES - 1)) begin
      lane_next = '0;
    end else begin
      lane_next = lane_id + LANE_W'(1);
    end
  endfunction

  always_comb begin
    sel_comb = active_lane_reg;
    sel_valid_comb = 1'b0;

    if (lock_reg) begin
      sel_comb = active_lane_reg;
      sel_valid_comb = 1'b1;
    end else begin
      for (int offset = 0; offset < NUM_LANES; offset++) begin
        int candidate;
        candidate = int'(rr_next_reg) + offset;
        if (candidate >= NUM_LANES) begin
          candidate = candidate - NUM_LANES;
        end
        if (!sel_valid_comb && s_axis_tvalid[candidate]) begin
          sel_comb = LANE_W'(candidate);
          sel_valid_comb = 1'b1;
        end
      end
    end
  end

  assign selected_tvalid = s_axis_tvalid[int'(sel_comb)];
  assign selected_tlast = s_axis_tlast[int'(sel_comb)];
  assign selected_accept = sel_valid_comb && selected_tvalid && m_axis_tready;

  assign m_axis_tdata = lane_tdata[int'(sel_comb)];
  assign m_axis_tvalid = sel_valid_comb && selected_tvalid;
  assign m_axis_tlast = selected_tlast;
  assign m_axis_tuser = lane_tuser[int'(sel_comb)];

  always_comb begin
    s_axis_tready = '0;
    if (sel_valid_comb) begin
      s_axis_tready[int'(sel_comb)] = m_axis_tready;
    end
  end

  assign o_active_lane = sel_comb;
  assign o_active_valid = sel_valid_comb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lock_reg <= 1'b0;
      active_lane_reg <= '0;
      rr_next_reg <= '0;
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
        active_lane_reg <= sel_comb;
      end

      if (selected_accept && selected_tlast) begin
        lock_reg <= 1'b0;
        active_lane_reg <= sel_comb;
        rr_next_reg <= lane_next(sel_comb);
        o_packet_count <= o_packet_count + 32'd1;
      end else if (selected_accept && !lock_reg) begin
        active_lane_reg <= sel_comb;
      end
    end
  end

  logic unused_static_checks;
  assign unused_static_checks = NUM_LANES_CHECK[0];
endmodule
