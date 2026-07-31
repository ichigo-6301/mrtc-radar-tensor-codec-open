`timescale 1ns/1ps

module tb_mrtc_axis_reg_queue2;
  logic clk;
  logic rst_n;
  logic flush;
  logic [31:0] s_tdata;
  logic [3:0] s_tuser;
  logic s_tvalid;
  logic s_tlast;
  logic s_tready;
  logic [31:0] m_tdata;
  logic [3:0] m_tuser;
  logic m_tvalid;
  logic m_tlast;
  logic m_tready;
  logic [1:0] occupancy;

  logic [31:0] expected_data [0:127];
  logic [3:0] expected_user [0:127];
  logic expected_last [0:127];
  integer expected_wr;
  integer expected_rd;

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (!rst_n || flush) begin
      expected_wr = 0;
      expected_rd = 0;
    end else begin
      if (m_tvalid && m_tready) begin
        if (expected_rd >= expected_wr) begin
          $fatal(1, "queue produced an unexpected beat");
        end
        if ((m_tdata !== expected_data[expected_rd]) ||
            (m_tuser !== expected_user[expected_rd]) ||
            (m_tlast !== expected_last[expected_rd])) begin
          $fatal(1, "queue output mismatch index=%0d", expected_rd);
        end
        expected_rd = expected_rd + 1;
      end
      if (s_tvalid && s_tready) begin
        expected_data[expected_wr] = s_tdata;
        expected_user[expected_wr] = s_tuser;
        expected_last[expected_wr] = s_tlast;
        expected_wr = expected_wr + 1;
      end
    end
  end

  task automatic push_beat(
    input logic [31:0] data,
    input logic [3:0] user,
    input logic last
  );
    begin
      s_tdata = data;
      s_tuser = user;
      s_tlast = last;
      s_tvalid = 1'b1;
      do begin
        @(posedge clk);
      end while (!s_tready);
      #1;
      s_tvalid = 1'b0;
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    flush = 1'b0;
    s_tdata = '0;
    s_tuser = '0;
    s_tvalid = 1'b0;
    s_tlast = 1'b0;
    m_tready = 1'b0;
    expected_wr = 0;
    expected_rd = 0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    #1;
    if (!s_tready || m_tvalid || (occupancy != 0)) begin
      $fatal(1, "queue reset state is invalid");
    end

    push_beat(32'h1000_0001, 4'h1, 1'b0);
    push_beat(32'h1000_0002, 4'h2, 1'b1);
    if (occupancy != 2 || s_tready) begin
      $fatal(1, "queue did not reach full state");
    end

    m_tready = 1'b1;
    #1;
    if (s_tready) begin
      $fatal(1, "downstream ready propagated combinationally to input ready");
    end
    @(posedge clk);
    #1;
    if (!s_tready || (occupancy != 1)) begin
      $fatal(1, "queue did not expose space after registered pop");
    end

    for (int beat = 0; beat < 24; beat = beat + 1) begin
      s_tdata = 32'h2000_0000 + beat;
      s_tuser = beat[3:0];
      s_tlast = (beat == 23);
      s_tvalid = 1'b1;
      @(posedge clk);
      if (!s_tready) begin
        $fatal(1, "continuous push/pop unexpectedly stalled beat=%0d", beat);
      end
    end
    #1;
    s_tvalid = 1'b0;

    while (m_tvalid) begin
      @(posedge clk);
    end
    #1;
    if ((expected_rd != expected_wr) || (occupancy != 0)) begin
      $fatal(1, "queue did not drain expected=%0d observed=%0d occupancy=%0d",
             expected_wr, expected_rd, occupancy);
    end

    m_tready = 1'b0;
    push_beat(32'h3000_0001, 4'h3, 1'b0);
    s_tdata = 32'h3000_0002;
    s_tuser = 4'h4;
    s_tlast = 1'b1;
    s_tvalid = 1'b1;
    @(posedge clk);
    #1;
    s_tvalid = 1'b0;
    if (!m_tvalid || (m_tdata != 32'h3000_0001)) begin
      $fatal(1, "stalled front beat is invalid");
    end
    repeat (3) begin
      #1;
      if ((m_tdata != 32'h3000_0001) || (m_tuser != 4'h3) || m_tlast) begin
        $fatal(1, "queue output changed under backpressure");
      end
      @(posedge clk);
    end

    flush = 1'b1;
    @(posedge clk);
    #1;
    flush = 1'b0;
    if (m_tvalid || (occupancy != 0)) begin
      $fatal(1, "flush did not empty queue");
    end

    $display("PASS tb_mrtc_axis_reg_queue2");
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "TIMEOUT tb_mrtc_axis_reg_queue2");
  end

  mrtc_axis_reg_queue2 #(
    .DATA_W  (32),
    .TUSER_W (4)
  ) u_dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .i_flush     (flush),
    .s_tdata     (s_tdata),
    .s_tuser     (s_tuser),
    .s_tvalid    (s_tvalid),
    .s_tlast     (s_tlast),
    .s_tready    (s_tready),
    .m_tdata     (m_tdata),
    .m_tuser     (m_tuser),
    .m_tvalid    (m_tvalid),
    .m_tlast     (m_tlast),
    .m_tready    (m_tready),
    .o_occupancy (occupancy)
  );
endmodule
