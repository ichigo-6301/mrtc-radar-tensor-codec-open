module mrtc_block_buffer #(
  parameter int BLOCK_SAMPLES = 1024
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_clear,
  input  logic        i_wr_en,
  input  logic [9:0]  i_wr_addr_base,
  input  logic [2:0]  i_wr_count,
  input  logic [31:0] i_wr_data0,
  input  logic [31:0] i_wr_data1,
  input  logic [31:0] i_wr_data2,
  input  logic [31:0] i_wr_data3,
  output logic [31:0] o_block_mem [0:BLOCK_SAMPLES-1]
);
  localparam int ADDR_W = (BLOCK_SAMPLES <= 1) ? 1 : $clog2(BLOCK_SAMPLES);

  logic [31:0] mem_rd_data [0:BLOCK_SAMPLES-1];
  logic [BLOCK_SAMPLES-1:0] visible_valid;

  logic [ADDR_W-1:0] wr_addr0;
  logic [ADDR_W-1:0] wr_addr1;
  logic [ADDR_W-1:0] wr_addr2;
  logic [ADDR_W-1:0] wr_addr3;
  logic              wr_lane0_valid;
  logic              wr_lane1_valid;
  logic              wr_lane2_valid;
  logic              wr_lane3_valid;

  assign wr_addr0 = i_wr_addr_base[ADDR_W-1:0];
  assign wr_addr1 = i_wr_addr_base[ADDR_W-1:0] + ADDR_W'(1);
  assign wr_addr2 = i_wr_addr_base[ADDR_W-1:0] + ADDR_W'(2);
  assign wr_addr3 = i_wr_addr_base[ADDR_W-1:0] + ADDR_W'(3);
  assign wr_lane0_valid = i_wr_en && (i_wr_count > 0) && (i_wr_addr_base < BLOCK_SAMPLES);
  assign wr_lane1_valid = i_wr_en && (i_wr_count > 1) && ((i_wr_addr_base + 10'd1) < BLOCK_SAMPLES);
  assign wr_lane2_valid = i_wr_en && (i_wr_count > 2) && ((i_wr_addr_base + 10'd2) < BLOCK_SAMPLES);
  assign wr_lane3_valid = i_wr_en && (i_wr_count > 3) && ((i_wr_addr_base + 10'd3) < BLOCK_SAMPLES);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      visible_valid <= '0;
    end else if (i_clear) begin
      visible_valid <= '0;
    end else if (i_wr_en) begin
      if (wr_lane0_valid) begin
        visible_valid[wr_addr0] <= 1'b1;
      end
      if (wr_lane1_valid) begin
        visible_valid[wr_addr1] <= 1'b1;
      end
      if (wr_lane2_valid) begin
        visible_valid[wr_addr2] <= 1'b1;
      end
      if (wr_lane3_valid) begin
        visible_valid[wr_addr3] <= 1'b1;
      end
    end
  end

  generate
    genvar cell_idx;
    for (cell_idx = 0; cell_idx < BLOCK_SAMPLES; cell_idx = cell_idx + 1) begin : g_block_cells
      logic        cell_wr_en;
      logic [31:0] cell_wr_data;
      logic [31:0] cell_rd_data;

      assign cell_wr_en =
          (wr_lane0_valid && (wr_addr0 == ADDR_W'(cell_idx))) ||
          (wr_lane1_valid && (wr_addr1 == ADDR_W'(cell_idx))) ||
          (wr_lane2_valid && (wr_addr2 == ADDR_W'(cell_idx))) ||
          (wr_lane3_valid && (wr_addr3 == ADDR_W'(cell_idx)));

      assign cell_wr_data =
          (wr_lane0_valid && (wr_addr0 == ADDR_W'(cell_idx))) ? i_wr_data0 :
          (wr_lane1_valid && (wr_addr1 == ADDR_W'(cell_idx))) ? i_wr_data1 :
          (wr_lane2_valid && (wr_addr2 == ADDR_W'(cell_idx))) ? i_wr_data2 :
          (wr_lane3_valid && (wr_addr3 == ADDR_W'(cell_idx))) ? i_wr_data3 :
          32'd0;

      mrtc_block_sample_mem #(
        .DATA_W(32),
        .DEPTH (1),
        .ADDR_W(1)
      ) u_block_sample_mem (
        .clk    (clk),
        .wr_en  (cell_wr_en),
        .wr_addr(1'b0),
        .wr_data(cell_wr_data),
        .rd_addr(1'b0),
        .rd_data(cell_rd_data)
      );

      assign mem_rd_data[cell_idx] = cell_rd_data;
      assign o_block_mem[cell_idx] = visible_valid[cell_idx] ? mem_rd_data[cell_idx] : 32'd0;
    end
  endgenerate
endmodule
