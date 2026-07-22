module mrtc_axis_protocol_checker #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W = 8,
`ifdef RDTC_ICARUS
  parameter NAME = "axis"
`else
  parameter string NAME = "axis"
`endif
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic [AXIS_DATA_W-1:0] tdata,
  input  logic                   tvalid,
  input  logic                   tready,
  input  logic                   tlast,
  input  logic [TUSER_W-1:0]     tuser,
  output integer                 protocol_error_count
);
  logic [AXIS_DATA_W-1:0] prev_tdata;
  logic                   prev_tvalid;
  logic                   prev_tready;
  logic                   prev_tlast;
  logic [TUSER_W-1:0]     prev_tuser;

  task automatic report_error(input string err_type);
    begin
      protocol_error_count = protocol_error_count + 1;
      $display(
        "[%0t] %s %s prev_valid=%0b prev_ready=%0b prev_data=%0h prev_last=%0b prev_user=%0h curr_valid=%0b curr_ready=%0b curr_data=%0h curr_last=%0b curr_user=%0h",
        $time, NAME, err_type,
        prev_tvalid, prev_tready, prev_tdata, prev_tlast, prev_tuser,
        tvalid, tready, tdata, tlast, tuser
      );
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      protocol_error_count <= 0;
      prev_tdata <= '0;
      prev_tvalid <= 1'b0;
      prev_tready <= 1'b0;
      prev_tlast <= 1'b0;
      prev_tuser <= '0;
    end else begin
      if ($isunknown(tvalid)) begin
        report_error("ERR_TVALID_X");
      end
      if ($isunknown(tready)) begin
        report_error("ERR_TREADY_X");
      end
      if (tvalid) begin
        if ($isunknown(tdata)) begin
          report_error("ERR_TDATA_X");
        end
        if ($isunknown(tlast)) begin
          report_error("ERR_TLAST_X");
        end
        if ($isunknown(tuser)) begin
          report_error("ERR_TUSER_X");
        end
      end
      if (prev_tvalid && !prev_tready) begin
        if (!tvalid) begin
          report_error("ERR_TVALID_DROPPED_WHILE_STALLED");
        end else begin
          if (tdata !== prev_tdata) begin
            report_error("ERR_TDATA_CHANGED_WHILE_STALLED");
          end
          if (tlast !== prev_tlast) begin
            report_error("ERR_TLAST_CHANGED_WHILE_STALLED");
          end
          if (tuser !== prev_tuser) begin
            report_error("ERR_TUSER_CHANGED_WHILE_STALLED");
          end
        end
      end
      prev_tdata <= tdata;
      prev_tvalid <= tvalid;
      prev_tready <= tready;
      prev_tlast <= tlast;
      prev_tuser <= tuser;
    end
  end
endmodule
