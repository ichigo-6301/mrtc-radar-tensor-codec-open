module mrtc_axis_payload_bram #(
  parameter int DATA_W = 128,
  parameter int DEPTH = 512,
  parameter int ADDR_W = $clog2(DEPTH)
) (
  input  logic              clk,
  input  logic              i_wr_en,
  input  logic [ADDR_W-1:0] i_wr_addr,
  input  logic [DATA_W-1:0] i_wr_data,
  input  logic              i_rd_en,
  input  logic [ADDR_W-1:0] i_rd_addr,
  output logic [DATA_W-1:0] o_rd_data,
  output logic              o_conflict
);
  localparam int DATA_W_CHECK = 1 / ((DATA_W > 0) ? 1 : 0);
  localparam int DEPTH_CHECK = 1 / ((DEPTH > 1) ? 1 : 0);

`ifdef RDTC_BOUNDED_ASIC_REGISTER_EXPANDED
`ifdef RDTC_BOUNDED_ASIC_SRAM
  initial $fatal(1, "bounded ASIC register and SRAM profiles are mutually exclusive");
`endif
`endif

`ifdef RDTC_BOUNDED_ASIC_REGISTER_EXPANDED
  localparam bit USE_ASIC_SLOT_STORAGE = 1'b1;
`elsif RDTC_BOUNDED_ASIC_SRAM
  localparam bit USE_ASIC_SLOT_STORAGE = 1'b1;
`else
  localparam bit USE_ASIC_SLOT_STORAGE = 1'b0;
`endif

  generate
    if (USE_ASIC_SLOT_STORAGE) begin : g_asic_slots
      localparam int SLOT_COUNT = 2;
      localparam int SLOT_DEPTH = 256;
      localparam int SLOT_ADDR_W = $clog2(SLOT_DEPTH);
      logic [SLOT_COUNT-1:0] slot_cmd_valid;
      logic [SLOT_COUNT-1:0] slot_cmd_write;
      logic [SLOT_ADDR_W-1:0] slot_cmd_addr [0:SLOT_COUNT-1];
      logic [DATA_W-1:0] slot_rd_data [0:SLOT_COUNT-1];
      logic rd_slot_reg;
      logic wr_slot;
      logic rd_slot;
      logic conflict;

      assign wr_slot = i_wr_addr[ADDR_W-1];
      assign rd_slot = i_rd_addr[ADDR_W-1];
      assign conflict = i_wr_en && i_rd_en && (wr_slot == rd_slot);
      assign o_conflict = conflict;
      assign o_rd_data = slot_rd_data[rd_slot_reg];

      always_comb begin
        slot_cmd_valid = '0;
        slot_cmd_write = '0;
        for (integer slot = 0; slot < SLOT_COUNT; slot = slot + 1) begin
          slot_cmd_addr[slot] = '0;
        end
        if (i_wr_en && !conflict) begin
          slot_cmd_valid[wr_slot] = 1'b1;
          slot_cmd_write[wr_slot] = 1'b1;
          slot_cmd_addr[wr_slot] = i_wr_addr[SLOT_ADDR_W-1:0];
        end
        if (i_rd_en && !conflict) begin
          slot_cmd_valid[rd_slot] = 1'b1;
          slot_cmd_write[rd_slot] = 1'b0;
          slot_cmd_addr[rd_slot] = i_rd_addr[SLOT_ADDR_W-1:0];
        end
      end

      for (genvar slot = 0; slot < SLOT_COUNT; slot = slot + 1) begin : g_slot
        mrtc_bounded_payload_slot_mem #(
          .DATA_W (DATA_W),
          .DEPTH  (SLOT_DEPTH)
        ) u_slot_mem (
          .clk         (clk),
          .i_cmd_valid (slot_cmd_valid[slot]),
          .i_cmd_write (slot_cmd_write[slot]),
          .i_cmd_addr  (slot_cmd_addr[slot]),
          .i_wr_data   (i_wr_data),
          .o_rd_data   (slot_rd_data[slot])
        );
      end

      always_ff @(posedge clk) begin
        if (i_rd_en && !conflict) begin
          rd_slot_reg <= rd_slot;
        end
      end

`ifndef SYNTHESIS
      always_ff @(posedge clk) begin
        if (conflict) begin
          $error("bounded payload storage forbids same-slot read/write");
        end
      end
`endif

      initial begin
        if ((DATA_W != 128) || (DEPTH != 512) || (ADDR_W != 9)) begin
          $fatal(1, "bounded ASIC payload storage requires 512x128 organization");
        end
      end
    end else begin : g_fpga_bram
      (* ram_style = "block" *)
  logic [DATA_W-1:0] mem [0:DEPTH-1];

      assign o_conflict = 1'b0;

  always_ff @(posedge clk) begin
    if (i_wr_en) begin
      mem[i_wr_addr] <= i_wr_data;
    end
  end

  always_ff @(posedge clk) begin
    if (i_rd_en) begin
      o_rd_data <= mem[i_rd_addr];
    end
  end
    end
  endgenerate

  logic unused_static_checks;
  assign unused_static_checks = DATA_W_CHECK[0] ^ DEPTH_CHECK[0];
endmodule
