module mrtc_axis_monitor #(
  parameter int AXIS_DATA_W = 128,
  parameter bit USE_TUSER_BYTE_COUNT_ON_TLAST = 1'b1,
  parameter int TUSER_W = 8
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic [AXIS_DATA_W-1:0] s_tdata,
  input  logic                   s_tvalid,
  output logic                   s_tready,
  input  logic                   s_tlast,
  input  logic [TUSER_W-1:0]     s_tuser,
  output logic                   o_done,
  output integer                 o_byte_count,
  output integer                 o_beat_count,
  output byte                    o_bytes [0:32767]
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  integer byte_idx;
  integer valid_bytes;
  string cfg_bp_mode;
  int unsigned cfg_bp_seed;
  int unsigned bp_rand_state;
  int unsigned bp_cycle_count;

  function automatic int unsigned next_rand(input int unsigned cur_state);
    next_rand = (cur_state * 32'd1664525) + 32'd1013904223;
  endfunction

  function automatic bit ready_for_cycle(
    input string mode,
    input int unsigned cycle_count,
    input int unsigned rand_value
  );
    begin
      ready_for_cycle = 1'b1;
      if (mode == "periodic") begin
        ready_for_cycle = ((cycle_count % 7) < 5);
      end else if (mode == "random") begin
        ready_for_cycle = (rand_value[7:0] >= 8'd51);
      end else if (mode == "burst") begin
        ready_for_cycle = ((cycle_count % 50) < 40);
      end
    end
  endfunction

  initial begin
    int seed;
    cfg_bp_mode = "none";
    seed = 32'd1;
    void'($value$plusargs("BP_MODE=%s", cfg_bp_mode));
    void'($value$plusargs("SEED=%d", seed));
    if (seed == 0) begin
      seed = 32'd1;
    end
    cfg_bp_seed = seed ^ 32'h6d2b79f5;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    int unsigned next_bp_rand_state;
    bit next_ready;
    if (!rst_n) begin
      s_tready <= 1'b0;
      o_done <= 1'b0;
      o_byte_count <= 0;
      o_beat_count <= 0;
      bp_rand_state <= cfg_bp_seed;
      bp_cycle_count <= 0;
    end else begin
      bp_cycle_count <= bp_cycle_count + 1;
      next_bp_rand_state = next_rand(bp_rand_state);
      bp_rand_state <= next_bp_rand_state;
      next_ready = ready_for_cycle(cfg_bp_mode, bp_cycle_count, next_bp_rand_state);
      s_tready <= next_ready;
      if (s_tvalid && s_tready) begin
        if (s_tlast && USE_TUSER_BYTE_COUNT_ON_TLAST) begin
          valid_bytes = s_tuser[3:0] + 1;
        end else begin
          valid_bytes = AXIS_BYTES;
        end
        for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
          o_bytes[o_byte_count + byte_idx] <= s_tdata[byte_idx*8 +: 8];
        end
        o_byte_count <= o_byte_count + valid_bytes;
        o_beat_count <= o_beat_count + 1;
        if (s_tlast) begin
          o_done <= 1'b1;
        end
      end
    end
  end
endmodule
