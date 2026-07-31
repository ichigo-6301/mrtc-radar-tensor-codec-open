module mrtc_axis_reg_queue2 #(
  parameter int DATA_W = 128,
  parameter int TUSER_W = 8
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               i_flush,

  input  logic [DATA_W-1:0]  s_tdata,
  input  logic [TUSER_W-1:0] s_tuser,
  input  logic               s_tvalid,
  input  logic               s_tlast,
  output logic               s_tready,

  output logic [DATA_W-1:0]  m_tdata,
  output logic [TUSER_W-1:0] m_tuser,
  output logic               m_tvalid,
  output logic               m_tlast,
  input  logic               m_tready,

  output logic [1:0]         o_occupancy
);
  logic [DATA_W-1:0]  data_0_reg;
  logic [DATA_W-1:0]  data_1_reg;
  logic [TUSER_W-1:0] user_0_reg;
  logic [TUSER_W-1:0] user_1_reg;
  logic               last_0_reg;
  logic               last_1_reg;
  logic [1:0]         count_reg;

  logic push;
  logic pop;

  assign s_tready = rst_n && !i_flush && (count_reg != 2'd2);
  assign m_tvalid = (count_reg != 2'd0);
  assign m_tdata = data_0_reg;
  assign m_tuser = user_0_reg;
  assign m_tlast = last_0_reg;
  assign o_occupancy = count_reg;

  assign push = s_tvalid && s_tready;
  assign pop = m_tvalid && m_tready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      count_reg <= 2'd0;
    end else if (i_flush) begin
      count_reg <= 2'd0;
    end else begin
      case ({push, pop})
        2'b10: begin
          if (count_reg == 2'd0) begin
            data_0_reg <= s_tdata;
            user_0_reg <= s_tuser;
            last_0_reg <= s_tlast;
          end else begin
            data_1_reg <= s_tdata;
            user_1_reg <= s_tuser;
            last_1_reg <= s_tlast;
          end
          count_reg <= count_reg + 2'd1;
        end

        2'b01: begin
          if (count_reg == 2'd2) begin
            data_0_reg <= data_1_reg;
            user_0_reg <= user_1_reg;
            last_0_reg <= last_1_reg;
          end
          count_reg <= count_reg - 2'd1;
        end

        2'b11: begin
          if (count_reg == 2'd1) begin
            data_0_reg <= s_tdata;
            user_0_reg <= s_tuser;
            last_0_reg <= s_tlast;
          end else begin
            data_0_reg <= data_1_reg;
            user_0_reg <= user_1_reg;
            last_0_reg <= last_1_reg;
            data_1_reg <= s_tdata;
            user_1_reg <= s_tuser;
            last_1_reg <= s_tlast;
          end
        end

        default: begin
        end
      endcase
    end
  end
endmodule
