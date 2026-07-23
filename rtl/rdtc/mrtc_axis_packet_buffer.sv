module mrtc_axis_packet_buffer #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W = 8,
  parameter int MAX_PACKET_BYTES = mrtc_pkg::MRTC_MAX_OUTPUT_BYTES,
  parameter int MAX_PACKET_BEATS =
    (MAX_PACKET_BYTES + (AXIS_DATA_W / 8) - 1) / (AXIS_DATA_W / 8),
  parameter int PACKET_DEPTH = 2
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_clear_status,

  input  logic [AXIS_DATA_W-1:0] s_axis_tdata,
  input  logic                   s_axis_tvalid,
  output logic                   s_axis_tready,
  input  logic                   s_axis_tlast,
  input  logic [TUSER_W-1:0]     s_axis_tuser,

  output logic                   o_packet_valid,
  input  logic                   i_packet_start,
  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready,
  output logic                   m_axis_tlast,
  output logic [TUSER_W-1:0]     m_axis_tuser,

  output logic                   o_busy,
  output logic                   o_full,
  output logic                   o_overflow,
  output logic [31:0]            o_packets_written,
  output logic [31:0]            o_packets_read,
  output logic [31:0]            o_write_stall_cycles,
  output logic [31:0]            o_read_stall_cycles,
  output logic [$clog2(PACKET_DEPTH + 1)-1:0] o_max_occupancy
);
  import mrtc_pkg::*;

  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int DEPTH_PTR_W = (PACKET_DEPTH <= 1) ? 1 : $clog2(PACKET_DEPTH);
  localparam int COUNT_W = $clog2(PACKET_DEPTH + 1);
  localparam int BEAT_IDX_W = (MAX_PACKET_BEATS <= 1) ? 1 : $clog2(MAX_PACKET_BEATS);
  localparam int BEAT_COUNT_W = $clog2(MAX_PACKET_BEATS + 1);
  localparam int DEPTH_CHECK = 1 / ((PACKET_DEPTH >= 2) ? 1 : 0);
  localparam int PACKET_BEATS_CHECK = 1 / ((MAX_PACKET_BEATS > 0) ? 1 : 0);

  logic [AXIS_DATA_W-1:0] packet_data_reg [0:PACKET_DEPTH-1][0:MAX_PACKET_BEATS-1];
  logic [TUSER_W-1:0]     packet_user_reg [0:PACKET_DEPTH-1][0:MAX_PACKET_BEATS-1];
  logic                   packet_last_reg [0:PACKET_DEPTH-1][0:MAX_PACKET_BEATS-1];
  logic                   packet_complete_reg [0:PACKET_DEPTH-1];
  logic [BEAT_COUNT_W-1:0] packet_beat_count_reg [0:PACKET_DEPTH-1];

  logic [DEPTH_PTR_W-1:0] wr_slot_reg;
  logic [DEPTH_PTR_W-1:0] rd_slot_reg;
  logic [COUNT_W-1:0]     occupancy_reg;
  logic [BEAT_IDX_W-1:0]  wr_beat_idx_reg;
  logic [DEPTH_PTR_W-1:0] wr_active_slot_reg;
  logic                   write_active_reg;
  logic                   read_active_reg;
  logic [DEPTH_PTR_W-1:0] read_slot_reg;
  logic [BEAT_IDX_W-1:0]  read_beat_idx_reg;
  logic                   overflow_reg;

  logic [COUNT_W-1:0] completed_packet_count;

  function automatic logic [DEPTH_PTR_W-1:0] next_slot_idx(
    input logic [DEPTH_PTR_W-1:0] cur_slot
  );
    integer next_slot_int;
    begin
      next_slot_int = cur_slot + 1;
      if (next_slot_int >= PACKET_DEPTH) begin
        next_slot_int = 0;
      end
      next_slot_idx = DEPTH_PTR_W'(next_slot_int);
    end
  endfunction

  assign completed_packet_count = occupancy_reg - (write_active_reg ? COUNT_W'(1) : COUNT_W'(0));
  assign o_packet_valid = (completed_packet_count != COUNT_W'(0));
  assign o_full = (occupancy_reg == COUNT_W'(PACKET_DEPTH));
  assign s_axis_tready = !overflow_reg &&
                         (write_active_reg || (occupancy_reg != COUNT_W'(PACKET_DEPTH)));
  assign m_axis_tvalid = read_active_reg;
  assign m_axis_tdata = packet_data_reg[read_slot_reg][read_beat_idx_reg];
  assign m_axis_tuser = packet_user_reg[read_slot_reg][read_beat_idx_reg];
  assign m_axis_tlast = packet_last_reg[read_slot_reg][read_beat_idx_reg];
  assign o_busy = write_active_reg || read_active_reg || (occupancy_reg != COUNT_W'(0));
  assign o_overflow = overflow_reg;

  // An overlength packet has no trustworthy boundary to resume from. Keep
  // ingress fail-stopped until reset; i_clear_status only resets counters.

  always_ff @(posedge clk or negedge rst_n) begin
    integer slot_idx;
    logic write_fire;
    logic read_fire;
    logic start_fire;
    logic packet_finish_write;
    logic packet_finish_read;
    logic start_new_packet;
    logic [COUNT_W-1:0] occupancy_next;
    logic [DEPTH_PTR_W-1:0] write_slot_cur;
    logic [DEPTH_PTR_W-1:0] next_wr_slot;
    logic [DEPTH_PTR_W-1:0] next_rd_slot;
    if (!rst_n) begin
      wr_slot_reg <= '0;
      rd_slot_reg <= '0;
      occupancy_reg <= '0;
      wr_beat_idx_reg <= '0;
      wr_active_slot_reg <= '0;
      write_active_reg <= 1'b0;
      read_active_reg <= 1'b0;
      read_slot_reg <= '0;
      read_beat_idx_reg <= '0;
      overflow_reg <= 1'b0;
      o_packets_written <= 32'd0;
      o_packets_read <= 32'd0;
      o_write_stall_cycles <= 32'd0;
      o_read_stall_cycles <= 32'd0;
      o_max_occupancy <= '0;
      for (slot_idx = 0; slot_idx < PACKET_DEPTH; slot_idx = slot_idx + 1) begin
        packet_complete_reg[slot_idx] <= 1'b0;
        packet_beat_count_reg[slot_idx] <= '0;
      end
    end else begin
      write_fire = s_axis_tvalid && s_axis_tready;
      read_fire = read_active_reg && m_axis_tvalid && m_axis_tready;
      start_fire = i_packet_start && !read_active_reg && (completed_packet_count != COUNT_W'(0));
      packet_finish_write = write_fire && s_axis_tlast;
      packet_finish_read = read_fire && m_axis_tlast;
      start_new_packet = !write_active_reg && write_fire;
      write_slot_cur = write_active_reg ? wr_active_slot_reg : wr_slot_reg;
      next_wr_slot = next_slot_idx(write_slot_cur);
      next_rd_slot = next_slot_idx(rd_slot_reg);

      if (i_clear_status) begin
        o_packets_written <= 32'd0;
        o_packets_read <= 32'd0;
        o_write_stall_cycles <= 32'd0;
        o_read_stall_cycles <= 32'd0;
        o_max_occupancy <= occupancy_reg;
      end

      if (!i_clear_status && s_axis_tvalid && !s_axis_tready) begin
        o_write_stall_cycles <= o_write_stall_cycles + 32'd1;
      end
      if (!i_clear_status && read_active_reg && m_axis_tvalid && !m_axis_tready) begin
        o_read_stall_cycles <= o_read_stall_cycles + 32'd1;
      end

      if (write_fire) begin
        packet_data_reg[write_slot_cur][wr_beat_idx_reg] <= s_axis_tdata;
        packet_user_reg[write_slot_cur][wr_beat_idx_reg] <= s_axis_tuser;
        packet_last_reg[write_slot_cur][wr_beat_idx_reg] <= s_axis_tlast;
        if ((wr_beat_idx_reg == BEAT_IDX_W'(MAX_PACKET_BEATS - 1)) && !s_axis_tlast) begin
          overflow_reg <= 1'b1;
        end
      end

      if (start_new_packet) begin
        wr_active_slot_reg <= wr_slot_reg;
      end

      if (start_new_packet && !packet_finish_write) begin
        write_active_reg <= 1'b1;
        wr_beat_idx_reg <= BEAT_IDX_W'(1);
      end else if (write_active_reg && write_fire && !packet_finish_write) begin
        wr_beat_idx_reg <= wr_beat_idx_reg + BEAT_IDX_W'(1);
      end else if (packet_finish_write) begin
        write_active_reg <= 1'b0;
        wr_beat_idx_reg <= '0;
      end

      if (packet_finish_write) begin
        packet_complete_reg[write_slot_cur] <= 1'b1;
        packet_beat_count_reg[write_slot_cur] <= BEAT_COUNT_W'(wr_beat_idx_reg + BEAT_IDX_W'(1));
        wr_slot_reg <= next_wr_slot;
        if (!i_clear_status) begin
          o_packets_written <= o_packets_written + 32'd1;
        end
      end

      if (start_fire) begin
        read_active_reg <= 1'b1;
        read_slot_reg <= rd_slot_reg;
        read_beat_idx_reg <= '0;
      end else if (read_fire && !packet_finish_read) begin
        read_beat_idx_reg <= read_beat_idx_reg + BEAT_IDX_W'(1);
      end

      if (packet_finish_read) begin
        packet_complete_reg[read_slot_reg] <= 1'b0;
        packet_beat_count_reg[read_slot_reg] <= '0;
        read_active_reg <= 1'b0;
        read_beat_idx_reg <= '0;
        rd_slot_reg <= next_rd_slot;
        if (!i_clear_status) begin
          o_packets_read <= o_packets_read + 32'd1;
        end
      end

      occupancy_next = occupancy_reg;
      if (start_new_packet && !packet_finish_read) begin
        occupancy_next = occupancy_next + COUNT_W'(1);
      end
      if (packet_finish_read && !start_new_packet) begin
        occupancy_next = occupancy_next - COUNT_W'(1);
      end
      occupancy_reg <= occupancy_next;
      if (!i_clear_status && (occupancy_next > o_max_occupancy)) begin
        o_max_occupancy <= occupancy_next;
      end
    end
  end
endmodule
