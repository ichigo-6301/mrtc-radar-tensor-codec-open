`timescale 1ns/1ps

module tb_mrtc_prefix_sample_buffer;
  localparam int DATA_W = 128;
  localparam int WORDS  = 64;
  localparam int ADDR_W = $clog2(WORDS);

  logic              clk;
  logic              rst_n;
  logic              wr_en;
  logic [ADDR_W-1:0] wr_addr;
  logic [DATA_W-1:0] wr_data;
  logic              rd_en;
  logic [ADDR_W-1:0] rd_addr;
  logic              rd_valid;
  logic [DATA_W-1:0] rd_data;

  mrtc_prefix_sample_buffer #(
    .AXIS_DATA_W (DATA_W),
    .PREFIX_WORDS(WORDS)
  ) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .i_wr_en   (wr_en),
    .i_wr_addr (wr_addr),
    .i_wr_data (wr_data),
    .i_rd_en   (rd_en),
    .i_rd_addr (rd_addr),
    .o_rd_valid(rd_valid),
    .o_rd_data (rd_data)
  );

  always #5 clk = ~clk;

  task automatic write_word(
    input logic [ADDR_W-1:0] address,
    input logic [DATA_W-1:0] data
  );
    begin
      @(negedge clk);
      wr_en   = 1'b1;
      wr_addr = address;
      wr_data = data;
      @(negedge clk);
      wr_en   = 1'b0;
    end
  endtask

  task automatic read_check(
    input logic [ADDR_W-1:0] address,
    input logic [DATA_W-1:0] expected
  );
    begin
      @(negedge clk);
      rd_en   = 1'b1;
      rd_addr = address;
      @(posedge clk);
      #1;
      if (!rd_valid || (rd_data !== expected)) begin
        $fatal(1, "read mismatch addr=%0d valid=%0b data=%032h expected=%032h",
               address, rd_valid, rd_data, expected);
      end
      @(negedge clk);
      rd_en = 1'b0;
    end
  endtask

  initial begin
    clk     = 1'b0;
    rst_n   = 1'b0;
    wr_en   = 1'b0;
    wr_addr = '0;
    wr_data = '0;
    rd_en   = 1'b0;
    rd_addr = '0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    write_word(6'd3, 128'h00112233445566778899aabbccddeeff);
    write_word(6'd4, 128'hfedcba98765432100123456789abcdef);
    read_check(6'd3, 128'h00112233445566778899aabbccddeeff);
    read_check(6'd4, 128'hfedcba98765432100123456789abcdef);

    @(negedge clk);
    wr_en   = 1'b1;
    wr_addr = 6'd8;
    wr_data = 128'h11112222333344445555666677778888;
    rd_en   = 1'b1;
    rd_addr = 6'd3;
    @(posedge clk);
    #1;
    if (!rd_valid || (rd_data !== 128'h00112233445566778899aabbccddeeff)) begin
      $fatal(1, "simultaneous different-address access failed");
    end

    @(negedge clk);
    wr_addr = 6'd9;
    wr_data = 128'h9999aaaabbbbccccddddeeeeffff0000;
    rd_addr = 6'd8;
    @(posedge clk);
    #1;
    if (!rd_valid || (rd_data !== 128'h11112222333344445555666677778888)) begin
      $fatal(1, "consecutive access failed");
    end

    @(negedge clk);
    wr_en = 1'b0;
    rd_en = 1'b0;
    @(posedge clk);
    #1;
    if (rd_valid) begin
      $fatal(1, "read valid did not deassert");
    end

    $display("PASS tb_mrtc_prefix_sample_buffer");
    $finish;
  end
endmodule
