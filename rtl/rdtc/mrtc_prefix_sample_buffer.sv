module mrtc_prefix_sample_buffer #(
  parameter int AXIS_DATA_W  = 128,
  parameter int PREFIX_WORDS = 64
) (
  input  logic                                      clk,
  input  logic                                      rst_n,
  input  logic                                      i_wr_en,
  input  logic [$clog2(PREFIX_WORDS)-1:0]           i_wr_addr,
  input  logic [AXIS_DATA_W-1:0]                    i_wr_data,
  input  logic                                      i_rd_en,
  input  logic [$clog2(PREFIX_WORDS)-1:0]           i_rd_addr,
  output logic                                      o_rd_valid,
  output logic [AXIS_DATA_W-1:0]                    o_rd_data
);
`ifdef RDTC_USE_OPENRAM_PREFIX_SRAM_1RW1R
  localparam int OPENRAM_DATA_W = 128;
  localparam int OPENRAM_WORDS  = 64;

  logic [AXIS_DATA_W-1:0] macro_rd_data;

  mrtc_rdtc_prefix_1rw1r_64x128 u_sram (
    .clk0 (clk),
    .csb0 (~i_wr_en),
    .web0 (1'b0),
    .addr0(i_wr_addr),
    .din0 (i_wr_data),
    .dout0(),
    .clk1 (clk),
    .csb1 (~i_rd_en),
    .addr1(i_rd_addr),
    .dout1(macro_rd_data)
  );

  assign o_rd_data = rst_n ? macro_rd_data : '0;
`elsif RDTC_USE_OPENRAM_PREFIX_SRAM
  localparam int OPENRAM_DATA_W = 128;
  localparam int OPENRAM_WORDS  = 64;

  logic [AXIS_DATA_W-1:0] macro_rd_data;

  mrtc_rdtc_prefix_1r1w_64x128 u_sram (
    .clk0 (clk),
    .csb0 (~i_wr_en),
    .addr0(i_wr_addr),
    .din0 (i_wr_data),
    .clk1 (clk),
    .csb1 (~i_rd_en),
    .addr1(i_rd_addr),
    .dout1(macro_rd_data)
  );

  assign o_rd_data = rst_n ? macro_rd_data : '0;
`elsif RDTC_USE_SKY130_PREFIX_SRAM
  localparam int SKY130_DATA_W = 128;
  localparam int SKY130_WORDS  = 64;
  localparam int SKY130_LANES  = 4;

  logic [AXIS_DATA_W-1:0] macro_rd_data;
  logic [7:0] macro_wr_addr;
  logic [7:0] macro_rd_addr;

  assign macro_wr_addr = {2'b00, i_wr_addr};
  assign macro_rd_addr = {2'b00, i_rd_addr};

  for (genvar lane = 0; lane < SKY130_LANES; lane++) begin : g_sram_lane
    sky130_sram_1kbyte_1rw1r_32x256_8 u_sram (
      .clk0  (clk),
      .csb0  (~i_wr_en),
      .web0  (1'b0),
      .wmask0(4'b1111),
      .addr0 (macro_wr_addr),
      .din0  (i_wr_data[lane*32 +: 32]),
      .dout0 (),
      .clk1  (clk),
      .csb1  (~i_rd_en),
      .addr1 (macro_rd_addr),
      .dout1 (macro_rd_data[lane*32 +: 32])
    );
  end

  assign o_rd_data = rst_n ? macro_rd_data : '0;
`elsif RDTC_USE_TSMC90_PREFIX_SRAM_DP_128X128
  localparam int TSMC90_DATA_W = 128;
  localparam int TSMC90_LOGICAL_WORDS = 64;

  logic [AXIS_DATA_W-1:0] macro_rd_data;

  // The physical macro has 128 rows; the adapter ties its upper address bit
  // low so the externally visible prefix-buffer contract remains 64x128.
  mrtc_rdtc_prefix_1r1w_64x128 u_sram (
    .clk0 (clk),
    .csb0 (~i_wr_en),
    .addr0(i_wr_addr),
    .din0 (i_wr_data),
    .clk1 (clk),
    .csb1 (~i_rd_en),
    .addr1(i_rd_addr),
    .dout1(macro_rd_data)
  );

  assign o_rd_data = rst_n ? macro_rd_data : '0;
`elsif RDTC_USE_TSMC90_PREFIX_RF
  localparam int TSMC90_DATA_W = 128;
  localparam int TSMC90_WORDS  = 64;

  logic [AXIS_DATA_W-1:0] macro_rd_data;

  // The tracked adapter keeps the RTL contract stable while the local setup
  // supplies the generated TSMC90 two-port register-file model.
  mrtc_rdtc_prefix_1r1w_64x128 u_sram (
    .clk0 (clk),
    .csb0 (~i_wr_en),
    .addr0(i_wr_addr),
    .din0 (i_wr_data),
    .clk1 (clk),
    .csb1 (~i_rd_en),
    .addr1(i_rd_addr),
    .dout1(macro_rd_data)
  );

  assign o_rd_data = rst_n ? macro_rd_data : '0;
`else
  logic [AXIS_DATA_W-1:0] mem [0:PREFIX_WORDS-1];
  logic [AXIS_DATA_W-1:0] rd_data_reg;

  assign o_rd_data = rst_n ? rd_data_reg : '0;

  always_ff @(posedge clk) begin
    if (i_wr_en) begin
      mem[i_wr_addr] <= i_wr_data;
    end
    if (i_rd_en) begin
      rd_data_reg <= mem[i_rd_addr];
    end
  end
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_rd_valid <= 1'b0;
    end else begin
      o_rd_valid <= i_rd_en;
    end
  end

`ifdef RDTC_USE_OPENRAM_PREFIX_SRAM_1RW1R
  initial begin
    if ((AXIS_DATA_W != OPENRAM_DATA_W) || (PREFIX_WORDS != OPENRAM_WORDS)) begin
      $fatal(1, "OpenRAM 1RW1R prefix SRAM requires AXIS_DATA_W=128 and PREFIX_WORDS=64");
    end
  end
`elsif RDTC_USE_OPENRAM_PREFIX_SRAM
  initial begin
    if ((AXIS_DATA_W != OPENRAM_DATA_W) || (PREFIX_WORDS != OPENRAM_WORDS)) begin
      $fatal(1, "OpenRAM prefix SRAM requires AXIS_DATA_W=128 and PREFIX_WORDS=64");
    end
  end
`elsif RDTC_USE_SKY130_PREFIX_SRAM
  initial begin
    if ((AXIS_DATA_W != SKY130_DATA_W) || (PREFIX_WORDS != SKY130_WORDS)) begin
      $fatal(1, "SKY130 prefix SRAM requires AXIS_DATA_W=128 and PREFIX_WORDS=64");
    end
  end
`elsif RDTC_USE_TSMC90_PREFIX_SRAM_DP_128X128
  initial begin
    if ((AXIS_DATA_W != TSMC90_DATA_W) ||
        (PREFIX_WORDS != TSMC90_LOGICAL_WORDS)) begin
      $fatal(1, "TSMC90 128x128 SRAM adapter requires AXIS_DATA_W=128 and PREFIX_WORDS=64");
    end
  end
`elsif RDTC_USE_TSMC90_PREFIX_RF
  initial begin
    if ((AXIS_DATA_W != TSMC90_DATA_W) || (PREFIX_WORDS != TSMC90_WORDS)) begin
      $fatal(1, "TSMC90 prefix RF requires AXIS_DATA_W=128 and PREFIX_WORDS=64");
    end
  end
`endif

`ifdef RDTC_PREFIX_BUFFER_ASSERTIONS
  always_ff @(posedge clk) begin
    if (rst_n && i_wr_en && i_rd_en && (i_wr_addr == i_rd_addr)) begin
      $fatal(1, "mrtc_prefix_sample_buffer forbids same-cycle same-address read/write");
    end
  end
`endif
endmodule
