module mrtc_axis_bounded_output_fifo #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W = 8,
  parameter int DEPTH_BEATS = 16,
  parameter int LEVEL_W = $clog2(DEPTH_BEATS + 1)
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     i_clear_status,
  input  logic                     i_halt,

  input  logic [AXIS_DATA_W-1:0]   s_axis_tdata,
  input  logic                     s_axis_tvalid,
  output logic                     s_axis_tready,
  input  logic                     s_axis_tlast,
  input  logic [TUSER_W-1:0]       s_axis_tuser,

  output logic [AXIS_DATA_W-1:0]   m_axis_tdata,
  output logic                     m_axis_tvalid,
  input  logic                     m_axis_tready,
  output logic                     m_axis_tlast,
  output logic [TUSER_W-1:0]       m_axis_tuser,

  output logic [LEVEL_W-1:0]       o_level,
  output logic [LEVEL_W-1:0]       o_max_level,
  output logic                     o_credit_exhausted,
  output logic [31:0]              o_push_count,
  output logic [31:0]              o_pop_count
);
  localparam int PTR_W = (DEPTH_BEATS <= 1) ? 1 : $clog2(DEPTH_BEATS);
  localparam int DEPTH_CHECK = 1 / ((DEPTH_BEATS == 16) ? 1 : 0);

  (* ram_style = "distributed" *)
  logic [AXIS_DATA_W-1:0] data_mem [0:DEPTH_BEATS-1];
  (* ram_style = "distributed" *)
  logic [TUSER_W-1:0] user_mem [0:DEPTH_BEATS-1];
  (* ram_style = "distributed" *)
  logic last_mem [0:DEPTH_BEATS-1];

  logic [PTR_W-1:0] wr_ptr_reg;
  logic [PTR_W-1:0] rd_ptr_reg;
  logic [LEVEL_W-1:0] count_reg;
  logic [LEVEL_W-1:0] count_next;
  logic push;
  logic pop;

  function automatic logic [PTR_W-1:0] next_ptr(input logic [PTR_W-1:0] ptr);
    if (ptr == PTR_W'(DEPTH_BEATS - 1)) begin
      next_ptr = '0;
    end else begin
      next_ptr = ptr + PTR_W'(1);
    end
  endfunction

  assign s_axis_tready = rst_n && !i_halt &&
                         (count_reg < LEVEL_W'(DEPTH_BEATS));
  assign m_axis_tvalid = rst_n && !i_halt && (count_reg != LEVEL_W'(0));
  assign m_axis_tdata = data_mem[rd_ptr_reg];
  assign m_axis_tlast = last_mem[rd_ptr_reg];
  assign m_axis_tuser = user_mem[rd_ptr_reg];
  assign o_level = count_reg;

  assign push = s_axis_tvalid && s_axis_tready;
  assign pop = m_axis_tvalid && m_axis_tready;

  // The final physical entry is an emergency credit. Consuming it without a
  // simultaneous drain is fatal, but the producer never observes backpressure.
  assign o_credit_exhausted = push && !pop &&
                              (count_reg == LEVEL_W'(DEPTH_BEATS - 1));

  always_comb begin
    count_next = count_reg;
    unique case ({push, pop})
      2'b10: count_next = count_reg + LEVEL_W'(1);
      2'b01: count_next = count_reg - LEVEL_W'(1);
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr_reg <= '0;
      rd_ptr_reg <= '0;
      count_reg <= '0;
      o_max_level <= '0;
      o_push_count <= 32'd0;
      o_pop_count <= 32'd0;
    end else begin
      if (push) begin
        data_mem[wr_ptr_reg] <= s_axis_tdata;
        user_mem[wr_ptr_reg] <= s_axis_tuser;
        last_mem[wr_ptr_reg] <= s_axis_tlast;
        wr_ptr_reg <= next_ptr(wr_ptr_reg);
      end
      if (pop) begin
        rd_ptr_reg <= next_ptr(rd_ptr_reg);
      end
      count_reg <= count_next;

      if (i_clear_status) begin
        o_max_level <= count_next;
        o_push_count <= 32'd0;
        o_pop_count <= 32'd0;
      end else begin
        if (count_next > o_max_level) begin
          o_max_level <= count_next;
        end
        if (push) begin
          o_push_count <= o_push_count + 32'd1;
        end
        if (pop) begin
          o_pop_count <= o_pop_count + 32'd1;
        end
      end
    end
  end

  logic unused_static_checks;
  assign unused_static_checks = DEPTH_CHECK[0];
endmodule
