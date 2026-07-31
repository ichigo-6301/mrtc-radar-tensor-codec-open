module mrtc_shallow_way_ring_slice #(
  parameter int AXIS_DATA_W       = 128,
  parameter int WAY_DEPTH_WORDS   = 32,
  parameter int WAY_COUNT         = 3,
  parameter int BLOCK_WORDS       = 256
) (
  input  logic                                   clk,
  input  logic                                   rst_n,
  input  logic                                   i_abort,

  input  logic                                   i_wr_en,
  input  logic [$clog2(BLOCK_WORDS)-1:0]         i_wr_word_index,
  input  logic [AXIS_DATA_W-1:0]                 i_wr_data,

  input  logic                                   i_rd_req,
  input  logic [$clog2(BLOCK_WORDS)-1:0]         i_rd_word_index,
  output logic                                   o_rd_valid,
  output logic [$clog2(BLOCK_WORDS)-1:0]         o_rd_word_index,
  output logic [AXIS_DATA_W-1:0]                 o_rd_data,

  output logic                                   o_way_conflict,
  output logic                                   o_ring_error
);
  localparam int GLOBAL_INDEX_W = $clog2(BLOCK_WORDS);
  localparam int WAY_ADDR_W = $clog2(WAY_DEPTH_WORDS);
  localparam int WAY_SEL_W = $clog2(WAY_COUNT);
  localparam int AXIS_DATA_W_CHECK = 1 / ((AXIS_DATA_W > 0) ? 1 : 0);
  localparam int WAY_DEPTH_CHECK = 1 / ((WAY_DEPTH_WORDS > 1) ? 1 : 0);
  localparam int WAY_COUNT_CHECK =
    1 / (((WAY_COUNT == 3) || (WAY_COUNT == 4)) ? 1 : 0);
  localparam int BLOCK_WORDS_CHECK =
    1 / ((BLOCK_WORDS >= (WAY_COUNT * WAY_DEPTH_WORDS)) ? 1 : 0);

  logic [WAY_DEPTH_WORDS-1:0] valid_bits_reg [0:WAY_COUNT-1];
  logic [WAY_DEPTH_WORDS-1:0] valid_bits_next [0:WAY_COUNT-1];
  logic [WAY_COUNT-1:0] way_cmd_valid;
  logic [WAY_COUNT-1:0] way_cmd_write;
  logic [WAY_ADDR_W-1:0] way_cmd_addr [0:WAY_COUNT-1];
  logic [AXIS_DATA_W-1:0] way_rd_data [0:WAY_COUNT-1];

  logic [WAY_SEL_W-1:0] wr_way_comb;
  logic [WAY_SEL_W-1:0] rd_way_comb;
  logic [WAY_ADDR_W-1:0] wr_offset_comb;
  logic [WAY_ADDR_W-1:0] rd_offset_comb;
  logic                  conflict_comb;
  logic                  overwrite_comb;
  logic                  underflow_comb;
  logic                  wr_accept_comb;
  logic                  rd_accept_comb;

  logic                      rd_pending_reg;
  logic [WAY_SEL_W-1:0]      rd_pending_way_reg;
  logic [GLOBAL_INDEX_W-1:0] rd_pending_index_reg;

  function automatic logic [WAY_SEL_W-1:0] map_way(
    input logic [GLOBAL_INDEX_W-1:0] global_index
  );
    integer segment_index;
    begin
      segment_index = global_index / WAY_DEPTH_WORDS;
      map_way = WAY_SEL_W'(segment_index % WAY_COUNT);
    end
  endfunction

  function automatic logic [WAY_ADDR_W-1:0] map_offset(
    input logic [GLOBAL_INDEX_W-1:0] global_index
  );
    begin
      map_offset = WAY_ADDR_W'(global_index % WAY_DEPTH_WORDS);
    end
  endfunction

  assign wr_way_comb    = map_way(i_wr_word_index);
  assign rd_way_comb    = map_way(i_rd_word_index);
  assign wr_offset_comb = map_offset(i_wr_word_index);
  assign rd_offset_comb = map_offset(i_rd_word_index);

  // Abort makes the old ring contents invalid, but it does not consume a
  // cycle: a new first write on the abort edge is admitted into the empty ring.
  assign conflict_comb = rst_n && i_wr_en && i_rd_req &&
                         (wr_way_comb == rd_way_comb);
  assign overwrite_comb = rst_n && !i_abort && i_wr_en && !conflict_comb &&
                          valid_bits_reg[wr_way_comb][wr_offset_comb];
  assign underflow_comb = rst_n && i_rd_req && !conflict_comb &&
                          (i_abort || !valid_bits_reg[rd_way_comb][rd_offset_comb]);
  assign wr_accept_comb = rst_n && i_wr_en && !conflict_comb && !overwrite_comb;
  assign rd_accept_comb = rst_n && !i_abort && i_rd_req &&
                          !conflict_comb && !underflow_comb;

  integer cmd_way_idx;
  always_comb begin
    way_cmd_valid = '0;
    way_cmd_write = '0;
    for (cmd_way_idx = 0; cmd_way_idx < WAY_COUNT; cmd_way_idx = cmd_way_idx + 1) begin
      way_cmd_addr[cmd_way_idx] = '0;
    end
    if (wr_accept_comb) begin
      way_cmd_valid[wr_way_comb] = 1'b1;
      way_cmd_write[wr_way_comb] = 1'b1;
      way_cmd_addr[wr_way_comb] = wr_offset_comb;
    end
    if (rd_accept_comb) begin
      way_cmd_valid[rd_way_comb] = 1'b1;
      way_cmd_write[rd_way_comb] = 1'b0;
      way_cmd_addr[rd_way_comb] = rd_offset_comb;
    end
  end

  for (genvar way_idx = 0; way_idx < WAY_COUNT; way_idx = way_idx + 1) begin : g_way
    mrtc_shallow_1rw_way #(
      .AXIS_DATA_W     (AXIS_DATA_W),
      .WAY_DEPTH_WORDS (WAY_DEPTH_WORDS)
    ) u_way (
      .clk         (clk),
      .i_cmd_valid (way_cmd_valid[way_idx]),
      .i_cmd_write (way_cmd_write[way_idx]),
      .i_cmd_addr  (way_cmd_addr[way_idx]),
      .i_wr_data   (i_wr_data),
      .o_rd_data   (way_rd_data[way_idx])
    );
  end

  integer next_way_idx;
  always_comb begin
    for (next_way_idx = 0; next_way_idx < WAY_COUNT; next_way_idx = next_way_idx + 1) begin
      valid_bits_next[next_way_idx] = i_abort ? '0 : valid_bits_reg[next_way_idx];
    end
    if (wr_accept_comb) begin
      valid_bits_next[wr_way_comb][wr_offset_comb] = 1'b1;
    end
    if (rd_accept_comb) begin
      valid_bits_next[rd_way_comb][rd_offset_comb] = 1'b0;
    end
  end

  integer state_way_idx;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (state_way_idx = 0; state_way_idx < WAY_COUNT; state_way_idx = state_way_idx + 1) begin
        valid_bits_reg[state_way_idx] <= '0;
      end
    end else begin
      for (state_way_idx = 0; state_way_idx < WAY_COUNT; state_way_idx = state_way_idx + 1) begin
        valid_bits_reg[state_way_idx] <= valid_bits_next[state_way_idx];
      end
    end
  end

  // The selected way captures memory data on the request edge. This boundary
  // register produces the fixed two-clock request-to-response interface.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_pending_reg       <= 1'b0;
      rd_pending_way_reg   <= '0;
      rd_pending_index_reg <= '0;
      o_rd_valid           <= 1'b0;
      o_rd_word_index      <= '0;
      o_rd_data            <= '0;
      o_way_conflict       <= 1'b0;
      o_ring_error         <= 1'b0;
    end else begin
      o_way_conflict <= conflict_comb;
      o_ring_error   <= overwrite_comb || underflow_comb;

      if (i_abort) begin
        rd_pending_reg       <= 1'b0;
        rd_pending_way_reg   <= '0;
        rd_pending_index_reg <= '0;
        o_rd_valid           <= 1'b0;
        o_rd_word_index      <= '0;
        o_rd_data            <= '0;
      end else begin
        o_rd_valid <= rd_pending_reg;
        if (rd_pending_reg) begin
          o_rd_word_index <= rd_pending_index_reg;
          o_rd_data       <= way_rd_data[rd_pending_way_reg];
        end

        rd_pending_reg <= rd_accept_comb;
        if (rd_accept_comb) begin
          rd_pending_way_reg   <= rd_way_comb;
          rd_pending_index_reg <= i_rd_word_index;
        end
      end
    end
  end
endmodule
