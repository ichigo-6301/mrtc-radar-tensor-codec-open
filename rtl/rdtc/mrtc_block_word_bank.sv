module mrtc_block_word_bank #(
  parameter int AXIS_DATA_W   = 128,
  parameter int LANES         = 4,
  parameter int BLOCK_SAMPLES = 1024,
`ifdef MRTC_FPGA_XILINX
  parameter string MEM_STYLE  = "block",
`endif
  parameter int READ_LATENCY  = 1
) (
  input  logic                                   clk,
  input  logic                                   rst_n,
  input  logic                                   i_clear,
  input  logic                                   i_wr_en,
  input  logic [$clog2(BLOCK_SAMPLES/LANES)-1:0] i_wr_word_addr,
  input  logic [AXIS_DATA_W-1:0]                 i_wr_word_data,
  input  logic                                   i_rd_req,
  input  logic [$clog2(BLOCK_SAMPLES/LANES)-1:0] i_rd_word_addr,
  output logic                                   o_rd_valid,
  output logic [AXIS_DATA_W-1:0]                 o_rd_word_data
);
  localparam int BLOCK_WORDS = BLOCK_SAMPLES / LANES;
  localparam int WORD_ADDR_W = (BLOCK_WORDS <= 1) ? 1 : $clog2(BLOCK_WORDS);
  localparam int LANES_SUPPORTED_CHECK =
    1 / (((LANES == 1) ||
          (LANES == 2) ||
          (LANES == 4) ||
          (LANES == 8) ||
          (LANES == 16)) ? 1 : 0);
  localparam int AXIS_DATA_W_CHECK =
    1 / ((AXIS_DATA_W == (LANES * 32)) ? 1 : 0);
  localparam int BLOCK_SAMPLES_CHECK =
    1 / (((BLOCK_SAMPLES % LANES) == 0) ? 1 : 0);
  localparam int READ_LATENCY_CHECK =
    1 / (((READ_LATENCY == 1) || (READ_LATENCY == 2)) ? 1 : 0);

  logic                   rd_valid_reg;
  logic                   rd_valid_stage1_reg;
  logic                   rd_accept;

`ifdef RDTC_USE_OPENRAM_BLOCK_SRAM_1RW32X4
  localparam int OPENRAM_DATA_W = 32;
  localparam int OPENRAM_WORDS  = 256;
  localparam int OPENRAM_LANES  = 4;

  logic                   macro_csb;
  logic                   macro_web;
  logic [WORD_ADDR_W-1:0] macro_addr;
  logic                   macro_csb_next;
  logic                   macro_web_next;
  logic [WORD_ADDR_W-1:0] macro_addr_next;
  logic [AXIS_DATA_W-1:0] macro_wr_word_data;
  logic [AXIS_DATA_W-1:0] macro_wr_word_data_next;
  logic [AXIS_DATA_W-1:0] macro_rd_word_data;
  logic [AXIS_DATA_W-1:0] block_sram_dout_response_reg;

`ifdef RDTC_PIPELINE_BLOCK_SRAM_DOUT
`ifdef RDTC_PIPELINE_BLOCK_SRAM_INPUT
  localparam int SRAM_PIPELINE_MODE_EXCLUSIVE_CHECK = 1 / 0;
`endif
`endif

`ifdef RDTC_PIPELINE_BLOCK_SRAM_DOUT
  localparam int OPENRAM_READ_LATENCY_CHECK =
    1 / ((READ_LATENCY == 2) ? 1 : 0);
`elsif RDTC_PIPELINE_BLOCK_SRAM_INPUT
  localparam int OPENRAM_READ_LATENCY_CHECK =
    1 / ((READ_LATENCY == 2) ? 1 : 0);
`else
  localparam int OPENRAM_READ_LATENCY_CHECK =
    1 / ((READ_LATENCY == 1) ? 1 : 0);
`endif

  assign macro_csb_next          = ~(i_wr_en || i_rd_req);
  assign macro_web_next          = ~i_wr_en;
  assign macro_addr_next         = i_wr_en ? i_wr_word_addr : i_rd_word_addr;
  assign macro_wr_word_data_next = i_wr_word_data;
  assign rd_accept  = i_rd_req && !i_wr_en;

`ifdef RDTC_PIPELINE_BLOCK_SRAM_INPUT
  // The FPGA BRAM replacement uses an unreset input boundary. This preserves
  // the two-cycle interface latency while keeping asynchronously reset
  // controller state off the inferred RAM address and control pins.
  always_ff @(posedge clk) begin
    macro_csb          <= macro_csb_next;
    macro_web          <= macro_web_next;
    macro_addr         <= macro_addr_next;
    macro_wr_word_data <= macro_wr_word_data_next;
  end
`else
  assign macro_csb          = macro_csb_next;
  assign macro_web          = macro_web_next;
  assign macro_addr         = macro_addr_next;
  assign macro_wr_word_data = macro_wr_word_data_next;
`endif

  for (genvar lane = 0; lane < OPENRAM_LANES; lane = lane + 1) begin : g_sram_lane
    mrtc_rdtc_block_1rw_256x32
`ifdef RDTC_OPENRAM_MODEL_QUIET
    #(.VERBOSE(0))
`endif
    u_sram (
      .clk0 (clk),
      .csb0 (macro_csb),
      .web0 (macro_web),
      .addr0(macro_addr),
      .din0 (macro_wr_word_data[(lane*OPENRAM_DATA_W) +: OPENRAM_DATA_W]),
      .dout0(macro_rd_word_data[(lane*OPENRAM_DATA_W) +: OPENRAM_DATA_W])
    );
  end

  generate
`ifdef RDTC_PIPELINE_BLOCK_SRAM_INPUT
    if (READ_LATENCY == 2) begin : g_input_isolated_response
      assign o_rd_word_data =
        (rst_n && rd_valid_reg) ? macro_rd_word_data : '0;
    end else begin : g_invalid_input_isolated_latency
      assign o_rd_word_data = '0;
    end
`else
    if (READ_LATENCY == 2) begin : g_dout_response_pipeline
      // Capture every cycle so synthesis cannot insert a clock-enable data mux
      // back onto the SRAM half-cycle output path.
      always_ff @(posedge clk) begin
        block_sram_dout_response_reg <= macro_rd_word_data;
      end

      // Consumers qualify this payload with o_rd_valid. Invalid-cycle data is
      // don't-care, avoiding a 128-bit valid mux after the boundary register.
      assign o_rd_word_data = block_sram_dout_response_reg;
    end else begin : g_direct_dout_response
      assign o_rd_word_data =
        (rst_n && rd_valid_reg) ? macro_rd_word_data : '0;
    end
`endif
  endgenerate

  initial begin
    if ((AXIS_DATA_W != (OPENRAM_DATA_W * OPENRAM_LANES)) ||
        (BLOCK_WORDS != OPENRAM_WORDS)) begin
      $fatal(1,
             "OpenRAM 1RW32X4 block bank requires AXIS_DATA_W=128 and BLOCK_WORDS=256");
    end
  end

`ifdef RDTC_BLOCK_WORD_BANK_ASSERTIONS
  always_ff @(posedge clk) begin
    if (rst_n && i_wr_en && i_rd_req) begin
      $fatal(1, "mrtc_block_word_bank single-port read/write collision");
    end
  end
`endif
`else
  localparam int REGISTER_READ_LATENCY_CHECK =
    1 / ((READ_LATENCY == 1) ? 1 : 0);
`ifdef MRTC_FPGA_XILINX
  (* ram_style = MEM_STYLE *)
`endif
  logic [AXIS_DATA_W-1:0] mem [0:BLOCK_WORDS-1];
  logic [AXIS_DATA_W-1:0] rd_word_data_reg;

  assign rd_accept      = i_rd_req;
  assign o_rd_word_data = (rst_n && rd_valid_reg) ? rd_word_data_reg : '0;

  always_ff @(posedge clk) begin
    if (i_wr_en) begin
      mem[i_wr_word_addr] <= i_wr_word_data;
    end
    if (i_rd_req) begin
      rd_word_data_reg <= mem[i_rd_word_addr];
    end
  end
`endif

  assign o_rd_valid = rst_n && rd_valid_reg;

  generate
    if (READ_LATENCY == 2) begin : g_two_cycle_valid
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          rd_valid_stage1_reg <= 1'b0;
          rd_valid_reg        <= 1'b0;
        end else if (i_clear) begin
          rd_valid_stage1_reg <= 1'b0;
          rd_valid_reg        <= 1'b0;
        end else begin
          rd_valid_stage1_reg <= rd_accept;
          rd_valid_reg        <= rd_valid_stage1_reg;
        end
      end
    end else begin : g_one_cycle_valid
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          rd_valid_reg <= 1'b0;
        end else if (i_clear) begin
          rd_valid_reg <= 1'b0;
        end else begin
          rd_valid_reg <= rd_accept;
        end
      end
    end
  endgenerate
endmodule
