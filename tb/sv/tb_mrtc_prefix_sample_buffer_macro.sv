`timescale 1ns/1ps

module tb_mrtc_prefix_sample_buffer_macro;
  localparam int DATA_W = 128;
  localparam int WORDS  = 64;
  localparam int ADDR_W = $clog2(WORDS);

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic wr_en = 1'b0;
  logic [ADDR_W-1:0] wr_addr = '0;
  logic [DATA_W-1:0] wr_data = '0;
  logic rd_en = 1'b0;
  logic [ADDR_W-1:0] rd_addr = '0;
  logic rd_valid;
  logic [DATA_W-1:0] rd_data;

  always #5 clk = ~clk;

  mrtc_prefix_sample_buffer #(.AXIS_DATA_W(DATA_W), .PREFIX_WORDS(WORDS)) dut (
    .clk(clk), .rst_n(rst_n),
    .i_wr_en(wr_en), .i_wr_addr(wr_addr), .i_wr_data(wr_data),
    .i_rd_en(rd_en), .i_rd_addr(rd_addr),
    .o_rd_valid(rd_valid), .o_rd_data(rd_data)
  );

  task automatic write_word(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] data);
    @(negedge clk);
    wr_en = 1'b1;
    wr_addr = addr;
    wr_data = data;
    @(negedge clk);
    wr_en = 1'b0;
  endtask

  task automatic read_check(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] expected);
    @(negedge clk);
    rd_en = 1'b1;
    rd_addr = addr;
    @(posedge clk);
    #9;
    if (!rd_valid || (rd_data !== expected)) begin
      $fatal(1, "macro read mismatch addr=%0d valid=%0b data=%032h expected=%032h",
             addr, rd_valid, rd_data, expected);
    end
    @(negedge clk);
    rd_en = 1'b0;
  endtask

`ifdef RDTC_TEST_SAME_ADDRESS_COLLISION
  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    wr_en = 1'b1;
    wr_addr = 6'd12;
    wr_data = 128'hc0111de0c0111de0c0111de0c0111de0;
    rd_en = 1'b1;
    rd_addr = 6'd12;
    repeat (3) @(posedge clk);
    $fatal(1, "same-address collision assertion did not fire");
  end
`else
  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    write_word(6'd3, 128'h00112233445566778899aabbccddeeff);
    write_word(6'd4, 128'hfedcba98765432100123456789abcdef);
    read_check(6'd3, 128'h00112233445566778899aabbccddeeff);
    read_check(6'd4, 128'hfedcba98765432100123456789abcdef);

    @(negedge clk);
    wr_en = 1'b1;
    wr_addr = 6'd8;
    wr_data = 128'h11112222333344445555666677778888;
    rd_en = 1'b1;
    rd_addr = 6'd3;
    @(posedge clk);
    #9;
    if (!rd_valid || (rd_data !== 128'h00112233445566778899aabbccddeeff)) begin
      $fatal(1, "macro different-address concurrent access failed");
    end
    @(negedge clk);
    wr_en = 1'b0;
    rd_en = 1'b0;
    read_check(6'd8, 128'h11112222333344445555666677778888);

    rst_n = 1'b0;
    #1;
    if (rd_valid || (rd_data !== '0)) $fatal(1, "macro reset masking failed");
    $display("PASS tb_mrtc_prefix_sample_buffer_macro");
    $finish;
  end
`endif

  initial begin
    #200000;
    $fatal(1, "TIMEOUT tb_mrtc_prefix_sample_buffer_macro");
  end
endmodule
