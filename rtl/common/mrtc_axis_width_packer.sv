module mrtc_axis_width_packer #(
  parameter int AXIS_DATA_W = 128,
  parameter int FRAG_W = 32,
  parameter bit DRAIN_APPEND_LOOKAHEAD = 1'b0,
  parameter bit REGISTERED_INPUT_QUEUE = 1'b0
) (
  input  logic                               clk,
  input  logic                               rst_n,
  input  logic                               s_frag_valid,
  output logic                               s_frag_ready,
  input  logic [FRAG_W-1:0]                  s_frag_data,
  input  logic [$clog2(FRAG_W+1)-1:0]        s_frag_bits,
  input  logic                               s_frag_last,
  output logic [AXIS_DATA_W-1:0]             m_axis_tdata,
  output logic                               m_axis_tvalid,
  input  logic                               m_axis_tready,
  output logic                               m_axis_tlast,
  output logic [$clog2((AXIS_DATA_W/8)+1)-1:0] m_axis_tvalid_bytes_minus1,
  output logic                               o_busy,
  output logic                               o_done,
  output logic                               o_overflow
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int VALID_BYTE_COUNT_W = $clog2(AXIS_BYTES + 1);
  localparam int BUF_W = AXIS_DATA_W + FRAG_W + 8;
  localparam int BUF_BITS_W = $clog2(BUF_W + 1);
  localparam int FRAG_BITS_W = $clog2(FRAG_W + 1);
  localparam logic [BUF_BITS_W-1:0] BUF_ACCEPT_LIMIT = BUF_BITS_W'(BUF_W - FRAG_W);
  localparam logic [BUF_BITS_W-1:0] AXIS_DATA_BITS = BUF_BITS_W'(AXIS_DATA_W);
  localparam logic [VALID_BYTE_COUNT_W-1:0] AXIS_BYTES_MINUS1 =
    VALID_BYTE_COUNT_W'(AXIS_BYTES - 1);
  localparam int AXIS_WIDTH_SUPPORTED_CHECK =
    1 / (((AXIS_DATA_W == 32) ||
          (AXIS_DATA_W == 64) ||
          (AXIS_DATA_W == 128) ||
          (AXIS_DATA_W == 256) ||
          (AXIS_DATA_W == 512)) ? 1 : 0);
  localparam int AXIS_BYTE_ALIGN_CHECK =
    1 / (((AXIS_DATA_W % 8) == 0) ? 1 : 0);
  localparam int FRAG_W_CHECK = 1 / ((FRAG_W > 0) ? 1 : 0);
  localparam int DRAIN_APPEND_LOOKAHEAD_CHECK =
    1 / (((DRAIN_APPEND_LOOKAHEAD == 1'b0) ||
          (DRAIN_APPEND_LOOKAHEAD == 1'b1)) ? 1 : 0);
  localparam int REGISTERED_INPUT_QUEUE_CHECK =
    1 / (((REGISTERED_INPUT_QUEUE == 1'b0) ||
          (REGISTERED_INPUT_QUEUE == 1'b1)) ? 1 : 0);

  logic [BUF_W-1:0]              buf_reg;
  logic [BUF_BITS_W-1:0]         buf_bits_reg;
  logic                          packet_end_reg;
  logic [AXIS_DATA_W-1:0]        out_data_reg;
  logic                          out_valid_reg;
  logic                          out_last_reg;
  logic [VALID_BYTE_COUNT_W-1:0] out_valid_bytes_reg;
  logic                          overflow_reg;
  logic                          norm_valid_reg;
  logic [FRAG_W-1:0]             norm_data_reg;
  logic [FRAG_BITS_W-1:0]        norm_bits_reg;
  logic                          norm_last_reg;
  logic [1:0]                    input_queue_count_reg;
  logic [FRAG_W-1:0]             input_queue_data_reg [0:1];
  logic [FRAG_BITS_W-1:0]        input_queue_bits_reg [0:1];
  logic                          input_queue_last_reg [0:1];
  logic                          input_queue_push;
  logic                          input_queue_pop;
  logic                          input_valid;
  logic [FRAG_W-1:0]             input_data;
  logic [FRAG_BITS_W-1:0]        input_bits;
  logic                          input_last;
  logic                          reservoir_ready;
  logic                          norm_advance;
  logic                          output_advance;
  logic                          drain_full_word;
  logic                          drain_tail_word;
  logic [BUF_BITS_W-1:0]         reservoir_bits_after_drain;

  function automatic logic [AXIS_DATA_W-1:0] logical_to_axis_word(
    input logic [AXIS_DATA_W-1:0] logical_bits
  );
    logic [AXIS_DATA_W-1:0] axis_bits;
    int byte_idx;
    int bit_idx;
    begin
      axis_bits = '0;
      for (byte_idx = 0; byte_idx < AXIS_BYTES; byte_idx = byte_idx + 1) begin
        for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
          axis_bits[(byte_idx * 8) + (7 - bit_idx)] =
            logical_bits[(byte_idx * 8) + bit_idx];
        end
      end
      logical_to_axis_word = axis_bits;
    end
  endfunction

  function automatic logic [FRAG_W-1:0] reverse_all_fragment_bits(
    input logic [FRAG_W-1:0] data
  );
    logic [FRAG_W-1:0] reversed;
    int bit_idx;
    begin
      reversed = '0;
      for (bit_idx = 0; bit_idx < FRAG_W; bit_idx = bit_idx + 1) begin
        reversed[bit_idx] = data[FRAG_W - 1 - bit_idx];
      end
      reverse_all_fragment_bits = reversed;
    end
  endfunction

  function automatic logic [FRAG_W-1:0] fragment_to_logical_bits(
    input logic [FRAG_W-1:0]            data,
    input logic [FRAG_BITS_W-1:0]       bit_count
  );
    logic [FRAG_W-1:0] reversed_all;
    logic [FRAG_W-1:0] shifted_valid;
    int shift_amount;
    begin
      reversed_all = reverse_all_fragment_bits(data);
      shift_amount = FRAG_W - int'(bit_count);
      shifted_valid = reversed_all >> shift_amount;
      fragment_to_logical_bits = shifted_valid;
    end
  endfunction

  function automatic logic [BUF_W-1:0] append_fragment_bits(
    input logic [BUF_W-1:0]             buffer_bits,
    input logic [BUF_BITS_W-1:0]        buffer_count,
    input logic [FRAG_W-1:0]            fragment_bits
  );
    logic [BUF_W-1:0] fragment_ext;
    begin
      fragment_ext = '0;
      fragment_ext[FRAG_W-1:0] = fragment_bits;
      append_fragment_bits = buffer_bits | (fragment_ext << buffer_count);
    end
  endfunction

  assign output_advance = !out_valid_reg || m_axis_tready;
  assign drain_full_word = output_advance && (buf_bits_reg >= AXIS_DATA_BITS);
  assign drain_tail_word = output_advance && !drain_full_word &&
                           packet_end_reg && (buf_bits_reg != 0);
  assign reservoir_bits_after_drain = drain_full_word ?
    (buf_bits_reg - AXIS_DATA_BITS) : buf_bits_reg;
  assign reservoir_ready = !packet_end_reg &&
    ((DRAIN_APPEND_LOOKAHEAD != 0) ?
      (reservoir_bits_after_drain <= BUF_ACCEPT_LIMIT) :
      (buf_bits_reg <= BUF_ACCEPT_LIMIT));
  assign m_axis_tdata = (rst_n && out_valid_reg) ? out_data_reg : '0;
  assign m_axis_tvalid = out_valid_reg;
  assign m_axis_tlast = out_last_reg;
  assign m_axis_tvalid_bytes_minus1 = out_valid_bytes_reg;
  assign o_busy = input_valid || out_valid_reg || (buf_bits_reg != 0) || packet_end_reg;
  assign o_overflow = overflow_reg;

  generate
    if (REGISTERED_INPUT_QUEUE != 0) begin : g_registered_input_queue
      assign s_frag_ready = (input_queue_count_reg != 2);
      assign input_queue_push = s_frag_valid && s_frag_ready;
      assign input_queue_pop = (input_queue_count_reg != 0) && reservoir_ready;
      assign input_valid = (input_queue_count_reg != 0);
      assign input_data = input_queue_data_reg[0];
      assign input_bits = input_queue_bits_reg[0];
      assign input_last = input_queue_last_reg[0];
      assign norm_advance = 1'b0;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          input_queue_count_reg <= '0;
          input_queue_bits_reg[0] <= '0;
          input_queue_bits_reg[1] <= '0;
          input_queue_last_reg[0] <= 1'b0;
          input_queue_last_reg[1] <= 1'b0;
        end else begin
          unique case ({input_queue_push, input_queue_pop})
            2'b10: begin
              if (input_queue_count_reg == 0) begin
                input_queue_data_reg[0] <= fragment_to_logical_bits(s_frag_data, s_frag_bits);
                input_queue_bits_reg[0] <= s_frag_bits;
                input_queue_last_reg[0] <= s_frag_last;
              end else begin
                input_queue_data_reg[1] <= fragment_to_logical_bits(s_frag_data, s_frag_bits);
                input_queue_bits_reg[1] <= s_frag_bits;
                input_queue_last_reg[1] <= s_frag_last;
              end
              input_queue_count_reg <= input_queue_count_reg + 1'b1;
            end
            2'b01: begin
              if (input_queue_count_reg == 2) begin
                input_queue_data_reg[0] <= input_queue_data_reg[1];
                input_queue_bits_reg[0] <= input_queue_bits_reg[1];
                input_queue_last_reg[0] <= input_queue_last_reg[1];
              end
              input_queue_count_reg <= input_queue_count_reg - 1'b1;
            end
            2'b11: begin
              if (input_queue_count_reg == 1) begin
                input_queue_data_reg[0] <= fragment_to_logical_bits(s_frag_data, s_frag_bits);
                input_queue_bits_reg[0] <= s_frag_bits;
                input_queue_last_reg[0] <= s_frag_last;
              end else begin
                input_queue_data_reg[0] <= input_queue_data_reg[1];
                input_queue_bits_reg[0] <= input_queue_bits_reg[1];
                input_queue_last_reg[0] <= input_queue_last_reg[1];
                input_queue_data_reg[1] <= fragment_to_logical_bits(s_frag_data, s_frag_bits);
                input_queue_bits_reg[1] <= s_frag_bits;
                input_queue_last_reg[1] <= s_frag_last;
              end
            end
            default: begin
            end
          endcase
        end
      end
    end else begin : g_single_input_stage
      assign norm_advance = !norm_valid_reg || reservoir_ready;
      assign s_frag_ready = norm_advance;
      assign input_queue_push = 1'b0;
      assign input_queue_pop = 1'b0;
      assign input_valid = norm_valid_reg;
      assign input_data = norm_data_reg;
      assign input_bits = norm_bits_reg;
      assign input_last = norm_last_reg;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          norm_valid_reg <= 1'b0;
          norm_bits_reg <= '0;
          norm_last_reg <= 1'b0;
        end else if (norm_advance) begin
          norm_valid_reg <= s_frag_valid;
          if (s_frag_valid) begin
            norm_data_reg <= fragment_to_logical_bits(s_frag_data, s_frag_bits);
            norm_bits_reg <= s_frag_bits;
            norm_last_reg <= s_frag_last;
          end
        end
      end
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    int final_valid_bytes;
    logic [BUF_W-1:0] work_buf;
    logic [BUF_BITS_W-1:0] work_buf_bits;
    logic work_packet_end;
    logic accept_frag;
    if (!rst_n) begin
      buf_reg <= '0;
      buf_bits_reg <= '0;
      packet_end_reg <= 1'b0;
      out_valid_reg <= 1'b0;
      out_last_reg <= 1'b0;
      out_valid_bytes_reg <= '0;
      overflow_reg <= 1'b0;
      o_done <= 1'b0;
    end else begin
      o_done <= out_valid_reg && m_axis_tready && out_last_reg;

      work_buf = buf_reg;
      work_buf_bits = buf_bits_reg;
      work_packet_end = packet_end_reg;

      if (output_advance) begin
        out_data_reg <= '0;
        out_valid_reg <= 1'b0;
        out_last_reg <= 1'b0;
        out_valid_bytes_reg <= '0;
        if (drain_full_word) begin
          out_data_reg <= logical_to_axis_word(buf_reg[AXIS_DATA_W-1:0]);
          out_valid_reg <= 1'b1;
          out_last_reg <= packet_end_reg && (buf_bits_reg == AXIS_DATA_BITS);
          out_valid_bytes_reg <= AXIS_BYTES_MINUS1;
          work_buf = buf_reg >> AXIS_DATA_W;
          work_buf_bits = buf_bits_reg - AXIS_DATA_BITS;
          if (packet_end_reg && (buf_bits_reg == AXIS_DATA_BITS)) begin
            work_packet_end = 1'b0;
          end
        end else if (drain_tail_word) begin
          final_valid_bytes = (buf_bits_reg + 7) / 8;
          out_data_reg <= logical_to_axis_word(buf_reg[AXIS_DATA_W-1:0]);
          out_valid_reg <= 1'b1;
          out_last_reg <= 1'b1;
          out_valid_bytes_reg <= VALID_BYTE_COUNT_W'(final_valid_bytes - 1);
          work_buf = '0;
          work_buf_bits = '0;
          work_packet_end = 1'b0;
        end
      end

      accept_frag = input_valid && reservoir_ready;
      if (accept_frag) begin
        if ((input_bits == '0) && !input_last) begin
          overflow_reg <= 1'b1;
        end else begin
          work_buf = append_fragment_bits(work_buf, work_buf_bits, input_data);
          work_buf_bits = work_buf_bits + BUF_BITS_W'(input_bits);
          if (input_last) begin
            work_packet_end = 1'b1;
          end
        end
      end

      buf_reg <= work_buf;
      buf_bits_reg <= work_buf_bits;
      packet_end_reg <= work_packet_end;
    end
  end
endmodule
