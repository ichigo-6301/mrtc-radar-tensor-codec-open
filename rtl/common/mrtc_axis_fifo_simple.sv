module mrtc_axis_fifo_simple #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W     = 8,
  parameter int DEPTH_BEATS = 16,
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
  localparam int PTR_W = (DEPTH_BEATS <= 1) ? 1 : $clog2(DEPTH_BEATS);

  logic [AXIS_DATA_W-1:0] data_mem [0:DEPTH_BEATS-1];
  logic [TUSER_W-1:0]     user_mem [0:DEPTH_BEATS-1];
  logic                   last_mem [0:DEPTH_BEATS-1];
  logic [PTR_W-1:0]       wr_ptr_reg;
  logic [PTR_W-1:0]       rd_ptr_reg;
  logic [LEVEL_W-1:0]     count_reg;

  logic write_fire;
  logic read_fire;
  logic [PTR_W-1:0] wr_ptr_next;
  logic [PTR_W-1:0] rd_ptr_next;
  logic [LEVEL_W-1:0] count_next;

  function automatic logic [PTR_W-1:0] next_ptr(input logic [PTR_W-1:0] ptr);
    integer ptr_int;
    begin
      ptr_int = ptr + 1;
      if (ptr_int >= DEPTH_BEATS) begin
        ptr_int = 0;
      end
      next_ptr = PTR_W'(ptr_int);
    end
  endfunction

  assign o_empty = (count_reg == '0);
  assign o_full = (count_reg == LEVEL_W'(DEPTH_BEATS));
  assign m_axis_tvalid = !o_empty;
  assign s_axis_tready = !o_full || (m_axis_tvalid && m_axis_tready);

  assign m_axis_tdata = data_mem[rd_ptr_reg];
  assign m_axis_tuser = user_mem[rd_ptr_reg];
  assign m_axis_tlast = last_mem[rd_ptr_reg];
  assign o_level = count_reg;

  assign write_fire = s_axis_tvalid && s_axis_tready;
  assign read_fire = m_axis_tvalid && m_axis_tready;
  assign wr_ptr_next = next_ptr(wr_ptr_reg);
  assign rd_ptr_next = next_ptr(rd_ptr_reg);

  always_comb begin
    count_next = count_reg;
    unique case ({write_fire, read_fire})
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
      o_overflow_error <= 1'b0;
      o_underflow_error <= 1'b0;
      o_max_level <= '0;
      o_full_cycles <= 32'd0;
    end else begin
      if (i_clear_status) begin
        o_overflow_error <= 1'b0;
        o_underflow_error <= 1'b0;
        o_max_level <= count_reg;
        o_full_cycles <= 32'd0;
      end

      if (write_fire) begin
        data_mem[wr_ptr_reg] <= s_axis_tdata;
        user_mem[wr_ptr_reg] <= s_axis_tuser;
        last_mem[wr_ptr_reg] <= s_axis_tlast;
        wr_ptr_reg <= wr_ptr_next;
      end

      if (read_fire) begin
        rd_ptr_reg <= rd_ptr_next;
      end

      count_reg <= count_next;

      if (!i_clear_status) begin
        if (o_full) begin
          o_full_cycles <= o_full_cycles + 32'd1;
        end
        if (count_next > o_max_level) begin
          o_max_level <= count_next;
        end
      end
    end
  end
endmodule
