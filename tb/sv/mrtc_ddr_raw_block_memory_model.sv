module mrtc_ddr_raw_block_memory_model #(
  parameter int AXIS_DATA_W = 128,
  parameter int NUM_PORTS = 2,
  parameter int MEM_WORDS = 65536,
  parameter int ADDR_W = 64,
  parameter int READ_LATENCY = 32,
  parameter int BURST_BEATS = 16,
  parameter int MAX_OUTSTANDING = 4,
  parameter int BANDWIDTH_LIMIT_BEATS_PER_CYCLE = 0
) (
  input  logic                                      clk,
  input  logic                                      rst_n,
  input  logic [NUM_PORTS-1:0]                      s_rd_req,
  input  wire [NUM_PORTS-1:0][ADDR_W-1:0]           s_rd_addr,
  input  wire [NUM_PORTS-1:0][15:0]                 s_rd_len,
  output logic [NUM_PORTS-1:0]                      s_rd_ready,
  output logic [NUM_PORTS-1:0]                      m_rd_data_valid,
  output logic [NUM_PORTS-1:0][AXIS_DATA_W-1:0]     m_rd_data,
  output logic [NUM_PORTS-1:0]                      m_rd_last
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int WORD_IDX_W = (MEM_WORDS <= 1) ? 1 : $clog2(MEM_WORDS);
  localparam int SLOT_PTR_W = (MAX_OUTSTANDING <= 1) ? 1 : $clog2(MAX_OUTSTANDING);

  logic [AXIS_DATA_W-1:0] mem_words [0:MEM_WORDS-1];
  logic                   slot_valid_reg [0:NUM_PORTS-1][0:MAX_OUTSTANDING-1];
  logic [WORD_IDX_W-1:0]  slot_word_idx_reg [0:NUM_PORTS-1][0:MAX_OUTSTANDING-1];
  logic [15:0]            slot_beats_left_reg [0:NUM_PORTS-1][0:MAX_OUTSTANDING-1];
  integer                 slot_delay_reg [0:NUM_PORTS-1][0:MAX_OUTSTANDING-1];
  logic [SLOT_PTR_W-1:0]  issue_ptr_reg [0:NUM_PORTS-1];
  logic [SLOT_PTR_W-1:0]  service_ptr_reg [0:NUM_PORTS-1];
  integer                 active_count_reg [0:NUM_PORTS-1];
  integer                 beats_sent_this_cycle;

  genvar gi;
  generate
    for (gi = 0; gi < NUM_PORTS; gi = gi + 1) begin : g_ports
      assign s_rd_ready[gi] = (active_count_reg[gi] < MAX_OUTSTANDING);
    end
  endgenerate

  task automatic load_word(
    input int word_idx,
    input logic [AXIS_DATA_W-1:0] value
  );
    begin
      if ((word_idx < 0) || (word_idx >= MEM_WORDS)) begin
        $fatal(1, "mrtc_ddr_raw_block_memory_model load_word idx=%0d out of range MEM_WORDS=%0d",
               word_idx, MEM_WORDS);
      end
      mem_words[word_idx] = value;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    integer port_idx;
    integer slot_idx;
    integer next_word_idx;
    integer next_issue_ptr;
    integer next_service_ptr;
    integer selected_slot;
    integer beats_sent_next;
    integer active_count_next;
    if (!rst_n) begin
      beats_sent_this_cycle <= 0;
      for (port_idx = 0; port_idx < NUM_PORTS; port_idx = port_idx + 1) begin
        issue_ptr_reg[port_idx] <= '0;
        service_ptr_reg[port_idx] <= '0;
        active_count_reg[port_idx] <= 0;
        m_rd_data_valid[port_idx] <= 1'b0;
        m_rd_data[port_idx] <= '0;
        m_rd_last[port_idx] <= 1'b0;
        for (slot_idx = 0; slot_idx < MAX_OUTSTANDING; slot_idx = slot_idx + 1) begin
          slot_valid_reg[port_idx][slot_idx] <= 1'b0;
          slot_word_idx_reg[port_idx][slot_idx] <= '0;
          slot_beats_left_reg[port_idx][slot_idx] <= '0;
          slot_delay_reg[port_idx][slot_idx] <= 0;
        end
      end
    end else begin
      beats_sent_next = 0;
      for (port_idx = 0; port_idx < NUM_PORTS; port_idx = port_idx + 1) begin
        m_rd_data_valid[port_idx] <= 1'b0;
        m_rd_data[port_idx] <= '0;
        m_rd_last[port_idx] <= 1'b0;
        active_count_next = active_count_reg[port_idx];

        if (s_rd_req[port_idx] && s_rd_ready[port_idx]) begin
          slot_valid_reg[port_idx][issue_ptr_reg[port_idx]] <= 1'b1;
          slot_word_idx_reg[port_idx][issue_ptr_reg[port_idx]] <=
            WORD_IDX_W'((s_rd_addr[port_idx] / AXIS_BYTES));
          slot_beats_left_reg[port_idx][issue_ptr_reg[port_idx]] <= s_rd_len[port_idx];
          slot_delay_reg[port_idx][issue_ptr_reg[port_idx]] <= READ_LATENCY;
          next_issue_ptr = issue_ptr_reg[port_idx] + 1;
          if (next_issue_ptr >= MAX_OUTSTANDING) begin
            next_issue_ptr = 0;
          end
          issue_ptr_reg[port_idx] <= SLOT_PTR_W'(next_issue_ptr);
          active_count_next = active_count_next + 1;
        end

        for (slot_idx = 0; slot_idx < MAX_OUTSTANDING; slot_idx = slot_idx + 1) begin
          if (slot_valid_reg[port_idx][slot_idx] && (slot_delay_reg[port_idx][slot_idx] > 0)) begin
            slot_delay_reg[port_idx][slot_idx] <= slot_delay_reg[port_idx][slot_idx] - 1;
          end
        end

        selected_slot = service_ptr_reg[port_idx];
        if (!(slot_valid_reg[port_idx][selected_slot] &&
              (slot_delay_reg[port_idx][selected_slot] == 0))) begin
          selected_slot = -1;
        end

        if ((selected_slot >= 0) &&
            ((BANDWIDTH_LIMIT_BEATS_PER_CYCLE == 0) ||
             (beats_sent_next < BANDWIDTH_LIMIT_BEATS_PER_CYCLE))) begin
          if (slot_word_idx_reg[port_idx][selected_slot] >= MEM_WORDS) begin
            $fatal(1, "mrtc_ddr_raw_block_memory_model read word_idx=%0d out of range MEM_WORDS=%0d",
                   slot_word_idx_reg[port_idx][selected_slot], MEM_WORDS);
          end
          m_rd_data_valid[port_idx] <= 1'b1;
          m_rd_data[port_idx] <= mem_words[slot_word_idx_reg[port_idx][selected_slot]];
          m_rd_last[port_idx] <= (slot_beats_left_reg[port_idx][selected_slot] == 16'd1);
          beats_sent_next = beats_sent_next + 1;
          if (slot_beats_left_reg[port_idx][selected_slot] == 16'd1) begin
            slot_valid_reg[port_idx][selected_slot] <= 1'b0;
            slot_beats_left_reg[port_idx][selected_slot] <= '0;
            active_count_next = active_count_next - 1;
            next_service_ptr = selected_slot + 1;
            if (next_service_ptr >= MAX_OUTSTANDING) begin
              next_service_ptr = 0;
            end
            service_ptr_reg[port_idx] <= SLOT_PTR_W'(next_service_ptr);
          end else begin
            next_word_idx = slot_word_idx_reg[port_idx][selected_slot] + 1;
            slot_word_idx_reg[port_idx][selected_slot] <= WORD_IDX_W'(next_word_idx);
            slot_beats_left_reg[port_idx][selected_slot] <=
              slot_beats_left_reg[port_idx][selected_slot] - 16'd1;
          end
        end

        active_count_reg[port_idx] <= active_count_next;
      end
      beats_sent_this_cycle <= beats_sent_next;
    end
  end
endmodule
