`timescale 1ns/1ps

module tb_rdtc_ddr_multiengine_wrapper #(
`ifdef RDTC_ICARUS
  parameter CASE_DIR = "vectors/rdtc_v1/smoke_multi_block",
`else
  parameter string CASE_DIR = "vectors/rdtc_v1/smoke_multi_block",
`endif
  parameter int EXPECTED_BLOCKS = 2,
  parameter int NUM_ENGINES = 2,
  parameter int DDR_READ_LATENCY = 32,
  parameter int DDR_BURST_BEATS = 16,
  parameter int MAX_OUTSTANDING = 4,
  parameter int BANDWIDTH_LIMIT_BEATS_PER_CYCLE = 0
);
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int TUSER_W = 8;
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int RAW_BEATS = MRTC_RAW_BYTES / AXIS_BYTES;
  localparam int MAX_BLOCKS = EXPECTED_BLOCKS + 8;
  localparam int MAX_CAPTURE_BYTES = MRTC_MAX_OUTPUT_BYTES + 1024;
  localparam int MEM_WORDS = MAX_BLOCKS * RAW_BEATS;

  logic clk;
  logic rst_n;
  logic wrap_clear_status;
  integer status_clear_checks;

  logic s_desc_valid;
  logic s_desc_ready;
  logic [63:0] s_desc_raw_addr;
  logic [15:0] s_desc_block_id;
  logic [15:0] s_desc_block_range_start;
  logic [15:0] s_desc_frame_id;
  logic [7:0]  s_desc_codec_mode;
  logic [7:0]  s_desc_rice_mode;
  logic [3:0]  s_desc_fixed_k;
  logic [15:0] s_desc_tensor_spatial_size;
  logic [15:0] s_desc_tensor_doppler_size;
  logic [15:0] s_desc_tensor_range_size;
  logic        s_desc_last_block;

  logic [NUM_ENGINES-1:0]                  mem_rd_req;
  logic [NUM_ENGINES-1:0][63:0]            mem_rd_addr;
  logic [NUM_ENGINES-1:0][15:0]            mem_rd_len;
  logic [NUM_ENGINES-1:0]                  mem_rd_ready;
  logic [NUM_ENGINES-1:0]                  mem_rd_data_valid;
  logic [NUM_ENGINES-1:0][AXIS_DATA_W-1:0] mem_rd_data;
  logic [NUM_ENGINES-1:0]                  mem_rd_last;

  logic [AXIS_DATA_W-1:0] wrap_axis_comp_tdata;
  logic                   wrap_axis_comp_tvalid;
  logic                   wrap_axis_comp_tready;
  logic                   wrap_axis_comp_tlast;
  logic [TUSER_W-1:0]     wrap_axis_comp_tuser;

  logic [AXIS_DATA_W-1:0] ref_axis_comp_tdata;
  logic                   ref_axis_comp_tvalid;
  logic                   ref_axis_comp_tready;
  logic                   ref_axis_comp_tlast;
  logic [TUSER_W-1:0]     ref_axis_comp_tuser;

  logic [AXIS_DATA_W-1:0] ref_axis_raw_tdata;
  logic                   ref_axis_raw_tvalid;
  logic                   ref_axis_raw_tready;
  logic                   ref_axis_raw_tlast;
  logic [TUSER_W-1:0]     ref_axis_raw_tuser;

  logic [AXIS_DATA_W-1:0] dec_axis_raw_tdata;
  logic                   dec_axis_raw_tvalid;
  logic                   dec_axis_raw_tready;
  logic                   dec_axis_raw_tready_reg;
  logic                   dec_axis_raw_tlast;
  logic [TUSER_W-1:0]     dec_axis_raw_tuser;
  logic                   dec_axis_comp_tready;
  logic                   dec_axis_comp_tvalid_in;
  logic                   dec_axis_comp_tlast_in;
  logic [AXIS_DATA_W-1:0] dec_axis_comp_tdata_in;
  logic [TUSER_W-1:0]     dec_axis_comp_tuser_in;

  logic                   wrap_stat_busy;
  logic                   wrap_stat_done;
  logic [31:0]            wrap_stat_num_blocks;
  logic [31:0]            wrap_stat_raw_bytes;
  logic [31:0]            wrap_stat_comp_bytes;
  logic [31:0]            wrap_stat_error;
  logic [31:0]            wrap_stat_stall_input_cycles;
  logic [31:0]            wrap_stat_stall_output_cycles;

  logic                   ref_stat_busy;
  logic [31:0]            ref_stat_num_blocks;
  logic [31:0]            ref_stat_comp_bytes;
  logic [31:0]            ref_stat_error;

  logic                   dec_stat_busy;
  logic [31:0]            dec_stat_num_blocks;
  logic [31:0]            dec_stat_error;

  logic [7:0]            cfg_codec_mode_runtime;
  logic [7:0]            cfg_rice_mode_runtime;
  logic [3:0]            cfg_fixed_k_runtime;
  logic [15:0]           cfg_frame_id_runtime;
  integer                block_id_base_runtime;
  integer                tensor_spatial_size_runtime;
  integer                tensor_doppler_size_runtime;
  integer                tensor_range_size_runtime;
  integer                expected_blocks_runtime;
  string                 resolved_case_dir;
  string                 scenario_name;
  string                 compare_csv_path;
  string                 latency_csv_path;
  string                 util_csv_path;
  string                 feeder_util_csv_path;
  string                 pktbuf_util_csv_path;
  string                 mem_bw_csv_path;
  integer                wrap_bp_bypass_runtime;
  string                 decoder_bp_mode;
  int unsigned           decoder_bp_seed;
  int unsigned           decoder_bp_state;
  int unsigned           decoder_bp_cycle_count;

  integer                wrapper_protocol_error_count;
  integer                ref_protocol_error_count;
  integer                decoder_protocol_error_count;

  integer                input_block_pred [0:MAX_BLOCKS-1];
  integer                input_block_raw_bypass [0:MAX_BLOCKS-1];
  integer                input_block_rice_mode [0:MAX_BLOCKS-1];
  integer                input_block_fixed_k [0:MAX_BLOCKS-1];
  integer                input_block_frame_id [0:MAX_BLOCKS-1];
  integer                input_block_tensor_spatial [0:MAX_BLOCKS-1];
  integer                input_block_tensor_doppler [0:MAX_BLOCKS-1];
  integer                input_block_tensor_range [0:MAX_BLOCKS-1];
  integer                input_block_range_start [0:MAX_BLOCKS-1];
  integer                input_last_block_id;

  byte                   expected_block_bytes [0:MAX_BLOCKS-1][0:MRTC_RAW_BYTES-1];
  integer                expected_block_num_bytes [0:MAX_BLOCKS-1];

  byte                   ref_packet_bytes [0:MAX_BLOCKS-1][0:MAX_CAPTURE_BYTES-1];
  integer                ref_packet_num_bytes [0:MAX_BLOCKS-1];
  integer                ref_packet_seen [0:MAX_BLOCKS-1];

  byte                   wrap_packet_bytes [0:MAX_BLOCKS-1][0:MAX_CAPTURE_BYTES-1];
  integer                wrap_packet_num_bytes [0:MAX_BLOCKS-1];
  integer                wrap_packet_seen [0:MAX_BLOCKS-1];
  integer                wrap_packet_order [0:MAX_BLOCKS-1];
  integer                wrap_packet_order_count;

  integer                decode_block_seen [0:MAX_BLOCKS-1];
  integer                decode_block_bytes [0:MAX_BLOCKS-1];
  integer                decode_stream_block_ptr;
  integer                decode_stream_byte_ptr;
  logic                  decode_mismatch_seen;
  integer                decode_mismatch_block_id;
  integer                decode_mismatch_byte_idx;
  byte                   decode_mismatch_exp;
  byte                   decode_mismatch_got;

  integer                desc_issue_cycle_by_block [0:MAX_BLOCKS-1];
  integer                packet_first_cycle_by_block [0:MAX_BLOCKS-1];
  integer                packet_last_cycle_by_block [0:MAX_BLOCKS-1];
  integer                decode_last_cycle_by_block [0:MAX_BLOCKS-1];
  integer                packet_bytes_by_block [0:MAX_BLOCKS-1];

  integer                desc_issue_count;
  integer                desc_done_count;
  integer                ref_done_count;
  integer                ref_capture_block_id_reg;
  integer                wrap_capture_block_id_reg;
  logic                  ref_packet_active_reg;
  logic                  wrap_packet_active_reg;

  integer                compare_fd;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
  end

  task automatic resolve_case_dir;
    string vec_root;
    string case_name;
    begin
      if (CASE_DIR.len() != 0) begin
        resolved_case_dir = CASE_DIR;
      end else begin
        vec_root = "vectors/rdtc_v1";
        case_name = "";
        void'($value$plusargs("VEC_ROOT=%s", vec_root));
        void'($value$plusargs("CASE=%s", case_name));
        if (case_name.len() == 0) begin
          $fatal(1, "tb_rdtc_ddr_multiengine_wrapper requires CASE_DIR or +CASE");
        end
        resolved_case_dir = {vec_root, "/", case_name};
      end
    end
  endtask

  task automatic load_case_cfg(input string cfg_case_dir);
    int fd;
    reg [8*1024-1:0] line;
    int read_code;
    string hdr_path;
    int code;
    int magic;
    int version;
    int header_len;
    int frame_id;
    int block_id;
    int tensor_spatial;
    int tensor_doppler;
    int tensor_range;
    int block_spatial_start;
    int block_doppler_start;
    int block_range_start;
    int block_spatial_len;
    int block_doppler_len;
    int block_range_len;
    int sample_format;
    int codec_mode;
    int predictor_mode;
    int rice_k;
    int flags;
    int reserved0;
    int raw_bytes;
    int payload_bytes;
    int payload_bits;
    int crc32;
    begin
      hdr_path = {cfg_case_dir, "/block_000_header.csv"};
      fd = $fopen(hdr_path, "r");
      if (fd == 0) begin
        $fatal(1, "failed to open %s", hdr_path);
      end
      read_code = $fgets(line, fd);
      line = '0;
      read_code = $fgets(line, fd);
      code = $sscanf(
        line,
        "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
        magic, version, header_len, frame_id, block_id,
        tensor_spatial, tensor_doppler, tensor_range,
        block_spatial_start, block_doppler_start, block_range_start,
        block_spatial_len, block_doppler_len, block_range_len,
        sample_format, codec_mode, predictor_mode, rice_k, flags, reserved0,
        raw_bytes, payload_bytes, payload_bits, crc32
      );
      $fclose(fd);
      if (code != 24) begin
        $fatal(1, "failed to parse %s", hdr_path);
      end
      cfg_codec_mode_runtime = predictor_mode[7:0];
      cfg_rice_mode_runtime = ((flags & MRTC_FLAG_BLOCK_ADAPTIVE_K) != 0) ? 8'd1 : 8'd0;
      cfg_fixed_k_runtime = rice_k[3:0];
      cfg_frame_id_runtime = frame_id[15:0];
      block_id_base_runtime = block_id;
      tensor_spatial_size_runtime = tensor_spatial;
      tensor_doppler_size_runtime = tensor_doppler;
      tensor_range_size_runtime = tensor_range;
    end
  endtask

  task automatic load_expected_input_metadata(input string cfg_case_dir, input int block_count);
    int fd;
    reg [8*1024-1:0] line;
    int read_code;
    string hdr_path;
    string blk_tag;
    int code;
    int magic;
    int version;
    int header_len;
    int frame_id;
    int block_id;
    int tensor_spatial;
    int tensor_doppler;
    int tensor_range;
    int block_spatial_start;
    int block_doppler_start;
    int block_range_start;
    int block_spatial_len;
    int block_doppler_len;
    int block_range_len;
    int sample_format;
    int codec_mode;
    int predictor_mode;
    int rice_k;
    int flags;
    int reserved0;
    int raw_bytes;
    int payload_bytes;
    int payload_bits;
    int crc32;
    int block_idx;
    begin
      for (block_idx = 0; block_idx < block_count; block_idx = block_idx + 1) begin
        if (block_idx < 10) begin
          blk_tag = $sformatf("00%0d", block_idx);
        end else if (block_idx < 100) begin
          blk_tag = $sformatf("0%0d", block_idx);
        end else begin
          blk_tag = $sformatf("%0d", block_idx);
        end
        hdr_path = {cfg_case_dir, "/block_", blk_tag, "_header.csv"};
        fd = $fopen(hdr_path, "r");
        if (fd == 0) begin
          $fatal(1, "failed to open %s", hdr_path);
        end
        read_code = $fgets(line, fd);
        line = '0;
        read_code = $fgets(line, fd);
        code = $sscanf(
          line,
          "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
          magic, version, header_len, frame_id, block_id,
          tensor_spatial, tensor_doppler, tensor_range,
          block_spatial_start, block_doppler_start, block_range_start,
          block_spatial_len, block_doppler_len, block_range_len,
          sample_format, codec_mode, predictor_mode, rice_k, flags, reserved0,
          raw_bytes, payload_bytes, payload_bits, crc32
        );
        $fclose(fd);
        if (code != 24) begin
          $fatal(1, "failed to parse %s", hdr_path);
        end
        input_block_pred[block_id] = predictor_mode;
        input_block_raw_bypass[block_id] = ((flags & MRTC_FLAG_RAW_BYPASS) != 0);
        input_block_rice_mode[block_id] = ((flags & MRTC_FLAG_BLOCK_ADAPTIVE_K) != 0) ? 1 : 0;
        input_block_fixed_k[block_id] = rice_k;
        input_block_frame_id[block_id] = frame_id;
        input_block_tensor_spatial[block_id] = tensor_spatial;
        input_block_tensor_doppler[block_id] = tensor_doppler;
        input_block_tensor_range[block_id] = tensor_range;
        input_block_range_start[block_id] = block_range_start;
        if ((flags & MRTC_FLAG_LAST_BLOCK) != 0) begin
          input_last_block_id = block_id;
        end
      end
      if (input_last_block_id < 0) begin
        input_last_block_id = block_id_base_runtime + block_count - 1;
      end
    end
  endtask

  task automatic load_expected_block_data(input string cfg_case_dir, input int block_count);
    int fd;
    int raw_byte;
    int block_idx;
    int byte_idx;
    int word_idx;
    int byte_in_word;
    integer global_block_id;
    string blk_tag;
    string hex_path;
    logic [AXIS_DATA_W-1:0] packed_word;
    begin
      for (block_idx = 0; block_idx < block_count; block_idx = block_idx + 1) begin
        global_block_id = block_id_base_runtime + block_idx;
        if (block_idx < 10) begin
          blk_tag = $sformatf("00%0d", block_idx);
        end else if (block_idx < 100) begin
          blk_tag = $sformatf("0%0d", block_idx);
        end else begin
          blk_tag = $sformatf("%0d", block_idx);
        end
        hex_path = {cfg_case_dir, "/block_", blk_tag, "_axis_raw_in.hex"};
        fd = $fopen(hex_path, "r");
        if (fd == 0) begin
          $fatal(1, "failed to open %s", hex_path);
        end
        for (byte_idx = 0; byte_idx < MRTC_RAW_BYTES; byte_idx = byte_idx + 1) begin
          if ($fscanf(fd, "%x\n", raw_byte) != 1) begin
            $fatal(1, "failed reading %s at block=%0d byte=%0d", hex_path, block_idx, byte_idx);
          end
          expected_block_bytes[global_block_id][byte_idx] = byte'(raw_byte[7:0]);
        end
        expected_block_num_bytes[global_block_id] = MRTC_RAW_BYTES;
        $fclose(fd);
        for (word_idx = 0; word_idx < RAW_BEATS; word_idx = word_idx + 1) begin
          packed_word = '0;
          for (byte_in_word = 0; byte_in_word < AXIS_BYTES; byte_in_word = byte_in_word + 1) begin
            packed_word[(byte_in_word*8) +: 8] = expected_block_bytes[global_block_id][(word_idx * AXIS_BYTES) + byte_in_word];
          end
          u_mem.load_word((block_idx * RAW_BEATS) + word_idx, packed_word);
        end
      end
    end
  endtask

  initial begin
    integer blk;
    integer idx;
    for (blk = 0; blk < MAX_BLOCKS; blk = blk + 1) begin
      input_block_pred[blk] = -1;
      input_block_raw_bypass[blk] = -1;
      input_block_rice_mode[blk] = -1;
      input_block_fixed_k[blk] = -1;
      input_block_frame_id[blk] = -1;
      input_block_tensor_spatial[blk] = -1;
      input_block_tensor_doppler[blk] = -1;
      input_block_tensor_range[blk] = -1;
      input_block_range_start[blk] = -1;
      expected_block_num_bytes[blk] = 0;
      ref_packet_num_bytes[blk] = 0;
      ref_packet_seen[blk] = 0;
      wrap_packet_num_bytes[blk] = 0;
      wrap_packet_seen[blk] = 0;
      wrap_packet_order[blk] = -1;
      decode_block_seen[blk] = 0;
      decode_block_bytes[blk] = 0;
      desc_issue_cycle_by_block[blk] = -1;
      packet_first_cycle_by_block[blk] = -1;
      packet_last_cycle_by_block[blk] = -1;
      decode_last_cycle_by_block[blk] = -1;
      packet_bytes_by_block[blk] = 0;
      for (idx = 0; idx < MRTC_RAW_BYTES; idx = idx + 1) begin
        expected_block_bytes[blk][idx] = 8'h00;
      end
      for (idx = 0; idx < MAX_CAPTURE_BYTES; idx = idx + 1) begin
        ref_packet_bytes[blk][idx] = 8'h00;
        wrap_packet_bytes[blk][idx] = 8'h00;
      end
    end
    input_last_block_id = -1;
    cfg_codec_mode_runtime = 8'd0;
    cfg_rice_mode_runtime = 8'd0;
    cfg_fixed_k_runtime = 4'd0;
    cfg_frame_id_runtime = 16'd0;
    block_id_base_runtime = 0;
    tensor_spatial_size_runtime = 0;
    tensor_doppler_size_runtime = 0;
    tensor_range_size_runtime = 0;
    expected_blocks_runtime = EXPECTED_BLOCKS;
    scenario_name = "public_smoke_multi_block_x2";
    compare_csv_path = "build/showcase_smoke/tb_rdtc_ddr_multiengine_wrapper/compare.csv";
    latency_csv_path = "build/showcase_smoke/tb_rdtc_ddr_multiengine_wrapper/latency.csv";
    util_csv_path = "build/showcase_smoke/tb_rdtc_ddr_multiengine_wrapper/engine_util.csv";
    feeder_util_csv_path = "build/showcase_smoke/tb_rdtc_ddr_multiengine_wrapper/feeder_util.csv";
    pktbuf_util_csv_path = "build/showcase_smoke/tb_rdtc_ddr_multiengine_wrapper/packet_buffer_util.csv";
    mem_bw_csv_path = "build/showcase_smoke/tb_rdtc_ddr_multiengine_wrapper/memory_bandwidth.csv";
    wrap_bp_bypass_runtime = 0;
    decoder_bp_mode = "none";
    decoder_bp_seed = 32'd1;
    void'($value$plusargs("SCENARIO=%s", scenario_name));
    void'($value$plusargs("EXPECTED_BLOCKS=%d", expected_blocks_runtime));
    void'($value$plusargs("COMPARE_CSV=%s", compare_csv_path));
    void'($value$plusargs("LAT_CSV=%s", latency_csv_path));
    void'($value$plusargs("UTIL_CSV=%s", util_csv_path));
    void'($value$plusargs("FEEDER_UTIL_CSV=%s", feeder_util_csv_path));
    void'($value$plusargs("PKTBUF_UTIL_CSV=%s", pktbuf_util_csv_path));
    void'($value$plusargs("MEM_BW_CSV=%s", mem_bw_csv_path));
    void'($value$plusargs("WRAP_BP_BYPASS=%d", wrap_bp_bypass_runtime));
    void'($value$plusargs("DEC_BP_MODE=%s", decoder_bp_mode));
    void'($value$plusargs("DEC_SEED=%d", decoder_bp_seed));
    if (decoder_bp_seed == 0) begin
      decoder_bp_seed = 32'd1;
    end
    if (expected_blocks_runtime <= 0) begin
      expected_blocks_runtime = EXPECTED_BLOCKS;
    end
    if (expected_blocks_runtime > EXPECTED_BLOCKS) begin
      $fatal(1, "runtime EXPECTED_BLOCKS=%0d exceeds elaborated capacity=%0d",
             expected_blocks_runtime, EXPECTED_BLOCKS);
    end
    resolve_case_dir();
    if (scenario_name.len() == 0) begin
      scenario_name = resolved_case_dir;
    end
    load_case_cfg(resolved_case_dir);
    load_expected_input_metadata(resolved_case_dir, expected_blocks_runtime);
    load_expected_block_data(resolved_case_dir, expected_blocks_runtime);
  end

  initial begin
    wrap_clear_status = 1'b0;
    status_clear_checks = 0;
    s_desc_valid = 1'b0;
    s_desc_raw_addr = '0;
    s_desc_block_id = '0;
    s_desc_block_range_start = '0;
    s_desc_frame_id = '0;
    s_desc_codec_mode = '0;
    s_desc_rice_mode = '0;
    s_desc_fixed_k = '0;
    s_desc_tensor_spatial_size = '0;
    s_desc_tensor_doppler_size = '0;
    s_desc_tensor_range_size = '0;
    s_desc_last_block = 1'b0;
    desc_issue_count = 0;
  end

  initial begin : status_clear_priority_check
    integer engine_idx;
    wait (rst_n);
    wait (|(mem_rd_req & mem_rd_ready));
    wrap_clear_status = 1'b1;
    @(posedge clk);
    #1;
    if (u_wrapper.desc_dispatched_total_reg != 0) begin
      $fatal(1,
             "FAIL ddr-multiengine status clear desc_total=%0d",
             u_wrapper.desc_dispatched_total_reg);
    end
    for (engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx = engine_idx + 1) begin
      if ((u_wrapper.feeder_bursts_issued_sig[engine_idx] != 0) ||
          (u_wrapper.feeder_bursts_shadow_reg[engine_idx] != 0) ||
          (u_wrapper.feeder_busy_cycles_reg[engine_idx] != 0)) begin
        $fatal(1,
               "FAIL ddr-multiengine status clear engine=%0d bursts=%0d shadow=%0d busy=%0d",
               engine_idx,
               u_wrapper.feeder_bursts_issued_sig[engine_idx],
               u_wrapper.feeder_bursts_shadow_reg[engine_idx],
               u_wrapper.feeder_busy_cycles_reg[engine_idx]);
      end
    end
    status_clear_checks = status_clear_checks + 1;
    @(negedge clk);
    wrap_clear_status = 1'b0;
  end

  assign ref_axis_comp_tready = 1'b1;
  assign dec_axis_raw_tready = dec_axis_raw_tready_reg;
  assign wrap_axis_comp_tready = (wrap_bp_bypass_runtime != 0) ? 1'b1 : dec_axis_comp_tready;
  assign dec_axis_comp_tvalid_in = (wrap_bp_bypass_runtime != 0) ? 1'b0 : wrap_axis_comp_tvalid;
  assign dec_axis_comp_tlast_in = wrap_axis_comp_tlast;
  assign dec_axis_comp_tdata_in = wrap_axis_comp_tdata;
  assign dec_axis_comp_tuser_in = wrap_axis_comp_tuser;

  mrtc_ddr_raw_block_memory_model #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .NUM_PORTS(NUM_ENGINES),
    .MEM_WORDS(MEM_WORDS),
    .READ_LATENCY(DDR_READ_LATENCY),
    .BURST_BEATS(DDR_BURST_BEATS),
    .MAX_OUTSTANDING(MAX_OUTSTANDING),
    .BANDWIDTH_LIMIT_BEATS_PER_CYCLE(BANDWIDTH_LIMIT_BEATS_PER_CYCLE)
  ) u_mem (
    .clk(clk),
    .rst_n(rst_n),
    .s_rd_req(mem_rd_req),
    .s_rd_addr(mem_rd_addr),
    .s_rd_len(mem_rd_len),
    .s_rd_ready(mem_rd_ready),
    .m_rd_data_valid(mem_rd_data_valid),
    .m_rd_data(mem_rd_data),
    .m_rd_last(mem_rd_last)
  );

  mrtc_rdtc_ddr_multiengine_wrapper #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .NUM_ENGINES(NUM_ENGINES),
    .ENGINE_K_POLICY_ARCH(MRTC_K_POLICY_PREFIX_FAST),
    .ENGINE_BPACK_ARCH(MRTC_BPACK_ARCH_LANE_WORD),
    .ENGINE_PACKER_LANE_MODE(4),
    .PREFIX_DURING_CAPTURE(1'b1),
    .PREFIX_STREAM_LENGTH_BY_TLAST(1'b1),
    .DDR_READ_LATENCY(DDR_READ_LATENCY),
    .DDR_BURST_BEATS(DDR_BURST_BEATS),
    .MAX_OUTSTANDING(MAX_OUTSTANDING),
    .OUTPUT_IN_ORDER(1'b0)
  ) u_wrapper (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(wrap_clear_status),
    .s_desc_valid(s_desc_valid),
    .s_desc_ready(s_desc_ready),
    .s_desc_raw_addr(s_desc_raw_addr),
    .s_desc_block_id(s_desc_block_id),
    .s_desc_block_range_start(s_desc_block_range_start),
    .s_desc_frame_id(s_desc_frame_id),
    .s_desc_codec_mode(s_desc_codec_mode),
    .s_desc_rice_mode(s_desc_rice_mode),
    .s_desc_fixed_k(s_desc_fixed_k),
    .s_desc_tensor_spatial_size(s_desc_tensor_spatial_size),
    .s_desc_tensor_doppler_size(s_desc_tensor_doppler_size),
    .s_desc_tensor_range_size(s_desc_tensor_range_size),
    .s_desc_last_block(s_desc_last_block),
    .o_mem_rd_req(mem_rd_req),
    .o_mem_rd_addr(mem_rd_addr),
    .o_mem_rd_len(mem_rd_len),
    .i_mem_rd_ready(mem_rd_ready),
    .i_mem_rd_data_valid(mem_rd_data_valid),
    .i_mem_rd_data(mem_rd_data),
    .i_mem_rd_last(mem_rd_last),
    .m_axis_comp_tdata(wrap_axis_comp_tdata),
    .m_axis_comp_tvalid(wrap_axis_comp_tvalid),
    .m_axis_comp_tready(wrap_axis_comp_tready),
    .m_axis_comp_tlast(wrap_axis_comp_tlast),
    .m_axis_comp_tuser(wrap_axis_comp_tuser),
    .stat_busy(wrap_stat_busy),
    .stat_done(wrap_stat_done),
    .stat_num_blocks(wrap_stat_num_blocks),
    .stat_raw_bytes(wrap_stat_raw_bytes),
    .stat_comp_bytes(wrap_stat_comp_bytes),
    .stat_error(wrap_stat_error),
    .stat_stall_input_cycles(wrap_stat_stall_input_cycles),
    .stat_stall_output_cycles(wrap_stat_stall_output_cycles)
  );

  mrtc_axis_driver #(
    .CASE_DIR("vectors/rdtc_v1/smoke_multi_block"),
    .HEX_FILE("axis_raw_in.hex"),
    .CTRL_FILE("axis_raw_in_ctrl.csv"),
    .LOAD_BLOCK_CODECS(1'b1),
    .EMIT_LAST_BYTE_COUNT(1'b0),
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W(TUSER_W),
    .MAX_RAW_BYTES(MRTC_RAW_BYTES * MAX_BLOCKS),
    .MAX_BEATS(RAW_BEATS * MAX_BLOCKS),
    .MAX_BLOCKS(MAX_BLOCKS)
  ) u_driver_ref (
    .clk(clk),
    .rst_n(rst_n),
    .m_tdata(ref_axis_raw_tdata),
    .m_tvalid(ref_axis_raw_tvalid),
    .m_tready(ref_axis_raw_tready),
    .m_tlast(ref_axis_raw_tlast),
    .m_tuser(ref_axis_raw_tuser),
    .o_done()
  );

  mrtc_rdtc_encoder_top #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .MRTC_K_POLICY_ARCH(MRTC_K_POLICY_PREFIX_FAST),
    .MRTC_BPACK_ARCH(MRTC_BPACK_ARCH_LANE_WORD),
    .PACKER_LANE_MODE(4),
    .PREFIX_DURING_CAPTURE(1'b1),
    .PREFIX_STREAM_LENGTH_BY_TLAST(1'b1)
  ) u_ref_encoder (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(1'b0),
    .s_axis_raw_tdata(ref_axis_raw_tdata),
    .s_axis_raw_tvalid(ref_axis_raw_tvalid),
    .s_axis_raw_tready(ref_axis_raw_tready),
    .s_axis_raw_tlast(ref_axis_raw_tlast),
    .s_axis_raw_tuser(ref_axis_raw_tuser),
    .m_axis_comp_tdata(ref_axis_comp_tdata),
    .m_axis_comp_tvalid(ref_axis_comp_tvalid),
    .m_axis_comp_tready(ref_axis_comp_tready),
    .m_axis_comp_tlast(ref_axis_comp_tlast),
    .m_axis_comp_tuser(ref_axis_comp_tuser),
    .cfg_codec_mode(cfg_codec_mode_runtime),
    .cfg_rice_mode(cfg_rice_mode_runtime),
    .cfg_fixed_k(cfg_fixed_k_runtime),
    .cfg_frame_id(cfg_frame_id_runtime),
    .cfg_block_id_base(block_id_base_runtime[15:0]),
    .cfg_tensor_spatial_size(tensor_spatial_size_runtime[15:0]),
    .cfg_tensor_doppler_size(tensor_doppler_size_runtime[15:0]),
    .cfg_tensor_range_size(tensor_range_size_runtime[15:0]),
    .stat_busy(ref_stat_busy),
    .stat_done(),
    .stat_raw_bytes(),
    .stat_comp_bytes(ref_stat_comp_bytes),
    .stat_num_blocks(ref_stat_num_blocks),
    .stat_error(ref_stat_error),
    .stat_raw_bypass_blocks(),
    .stat_stall_input_cycles(),
    .stat_stall_output_cycles()
  );

  mrtc_rdtc_decoder_top #(
    .AXIS_DATA_W(AXIS_DATA_W)
  ) u_decoder (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(1'b0),
    .s_axis_comp_tdata(dec_axis_comp_tdata_in),
    .s_axis_comp_tvalid(dec_axis_comp_tvalid_in),
    .s_axis_comp_tready(dec_axis_comp_tready),
    .s_axis_comp_tlast(dec_axis_comp_tlast_in),
    .s_axis_comp_tuser(dec_axis_comp_tuser_in),
    .m_axis_raw_tdata(dec_axis_raw_tdata),
    .m_axis_raw_tvalid(dec_axis_raw_tvalid),
    .m_axis_raw_tready(dec_axis_raw_tready),
    .m_axis_raw_tlast(dec_axis_raw_tlast),
    .m_axis_raw_tuser(dec_axis_raw_tuser),
    .stat_busy(dec_stat_busy),
    .stat_done(),
    .stat_comp_bytes(),
    .stat_raw_bytes(),
    .stat_num_blocks(dec_stat_num_blocks),
    .stat_error(dec_stat_error),
    .stat_error_blocks(),
    .stat_stall_input_cycles(),
    .stat_stall_output_cycles()
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W(TUSER_W),
    .NAME("ddr_wrap_comp")
  ) u_wrapper_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(wrap_axis_comp_tdata),
    .tvalid(wrap_axis_comp_tvalid),
    .tready(wrap_axis_comp_tready),
    .tlast(wrap_axis_comp_tlast),
    .tuser(wrap_axis_comp_tuser),
    .protocol_error_count(wrapper_protocol_error_count)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W(TUSER_W),
    .NAME("ddr_ref_comp")
  ) u_ref_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(ref_axis_comp_tdata),
    .tvalid(ref_axis_comp_tvalid),
    .tready(ref_axis_comp_tready),
    .tlast(ref_axis_comp_tlast),
    .tuser(ref_axis_comp_tuser),
    .protocol_error_count(ref_protocol_error_count)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W(TUSER_W),
    .NAME("ddr_dec_raw")
  ) u_dec_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(dec_axis_raw_tdata),
    .tvalid(dec_axis_raw_tvalid),
    .tready(dec_axis_raw_tready),
    .tlast(dec_axis_raw_tlast),
    .tuser(dec_axis_raw_tuser),
    .protocol_error_count(decoder_protocol_error_count)
  );

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

  always @(posedge clk or negedge rst_n) begin
    int unsigned next_bp_state;
    bit next_dec_ready;
    integer valid_bytes;
    integer byte_idx;
    integer block_id;
    if (!rst_n) begin
      dec_axis_raw_tready_reg <= 1'b0;
      decoder_bp_state <= decoder_bp_seed;
      decoder_bp_cycle_count <= 0;
      decode_stream_block_ptr <= 0;
      decode_stream_byte_ptr <= 0;
      decode_mismatch_seen <= 1'b0;
      wrap_packet_order_count <= 0;
      desc_done_count <= 0;
      ref_done_count <= 0;
      ref_capture_block_id_reg <= 0;
      wrap_capture_block_id_reg <= 0;
      ref_packet_active_reg <= 1'b0;
      wrap_packet_active_reg <= 1'b0;
    end else begin
      decoder_bp_cycle_count <= decoder_bp_cycle_count + 1;
      next_bp_state = next_rand(decoder_bp_state);
      decoder_bp_state <= next_bp_state;
      next_dec_ready = ready_for_cycle(decoder_bp_mode, decoder_bp_cycle_count, next_bp_state);
      dec_axis_raw_tready_reg <= next_dec_ready;

      if (ref_axis_comp_tvalid && ref_axis_comp_tready) begin
        valid_bytes = ref_axis_comp_tlast ? (ref_axis_comp_tuser[3:0] + 1) : AXIS_BYTES;
        if (!ref_packet_active_reg) begin
          block_id = {ref_axis_comp_tdata[(7*8) +: 8], ref_axis_comp_tdata[(6*8) +: 8]};
          ref_capture_block_id_reg <= block_id;
        end else begin
          block_id = ref_capture_block_id_reg;
        end
        for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
          ref_packet_bytes[block_id][ref_packet_num_bytes[block_id] + byte_idx] <=
            ref_axis_comp_tdata[(byte_idx*8) +: 8];
        end
        ref_packet_num_bytes[block_id] <= ref_packet_num_bytes[block_id] + valid_bytes;
        if (ref_axis_comp_tlast) begin
          ref_packet_seen[block_id] <= ref_packet_seen[block_id] + 1;
          ref_done_count <= ref_done_count + 1;
          ref_packet_active_reg <= 1'b0;
        end else begin
          ref_packet_active_reg <= 1'b1;
        end
      end

      if (wrap_axis_comp_tvalid && wrap_axis_comp_tready) begin
        valid_bytes = wrap_axis_comp_tlast ? (wrap_axis_comp_tuser[3:0] + 1) : AXIS_BYTES;
        if (!wrap_packet_active_reg) begin
          block_id = {wrap_axis_comp_tdata[(7*8) +: 8], wrap_axis_comp_tdata[(6*8) +: 8]};
          wrap_capture_block_id_reg <= block_id;
        end else begin
          block_id = wrap_capture_block_id_reg;
        end
        if (!wrap_packet_active_reg && (packet_first_cycle_by_block[block_id] < 0)) begin
          packet_first_cycle_by_block[block_id] <= $time / 10;
        end
        for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
          wrap_packet_bytes[block_id][wrap_packet_num_bytes[block_id] + byte_idx] <=
            wrap_axis_comp_tdata[(byte_idx*8) +: 8];
        end
        wrap_packet_num_bytes[block_id] <= wrap_packet_num_bytes[block_id] + valid_bytes;
        if (wrap_axis_comp_tlast) begin
          wrap_packet_seen[block_id] <= wrap_packet_seen[block_id] + 1;
          wrap_packet_order[wrap_packet_order_count] <= block_id;
          packet_last_cycle_by_block[block_id] <= $time / 10;
          packet_bytes_by_block[block_id] <= wrap_packet_num_bytes[block_id] + valid_bytes;
          wrap_packet_order_count <= wrap_packet_order_count + 1;
          wrap_packet_active_reg <= 1'b0;
        end else begin
          wrap_packet_active_reg <= 1'b1;
        end
      end

      if (dec_axis_raw_tvalid && dec_axis_raw_tready) begin
        valid_bytes = dec_axis_raw_tlast ? (dec_axis_raw_tuser[3:0] + 1) : AXIS_BYTES;
        block_id = wrap_packet_order[decode_stream_block_ptr];
        for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
          if (expected_block_bytes[block_id][decode_stream_byte_ptr + byte_idx] !==
              dec_axis_raw_tdata[(byte_idx*8) +: 8]) begin
            if (!decode_mismatch_seen) begin
              decode_mismatch_seen <= 1'b1;
              decode_mismatch_block_id <= block_id;
              decode_mismatch_byte_idx <= decode_stream_byte_ptr + byte_idx;
              decode_mismatch_exp <= expected_block_bytes[block_id][decode_stream_byte_ptr + byte_idx];
              decode_mismatch_got <= dec_axis_raw_tdata[(byte_idx*8) +: 8];
            end
          end
        end
        decode_stream_byte_ptr <= decode_stream_byte_ptr + valid_bytes;
        if (dec_axis_raw_tlast) begin
          decode_block_seen[block_id] <= decode_block_seen[block_id] + 1;
          decode_block_bytes[block_id] <= decode_stream_byte_ptr + valid_bytes;
          decode_last_cycle_by_block[block_id] <= $time / 10;
          decode_stream_block_ptr <= decode_stream_block_ptr + 1;
          decode_stream_byte_ptr <= 0;
        end
      end
    end
  end

  initial begin : descriptor_driver
    integer block_idx;
    integer global_block_id;
    wait(rst_n);
    repeat (2) @(posedge clk);
    for (block_idx = 0; block_idx < expected_blocks_runtime; block_idx = block_idx + 1) begin
      @(negedge clk);
      global_block_id = block_id_base_runtime + block_idx;
      s_desc_raw_addr = 64'((block_idx * RAW_BEATS) * AXIS_BYTES);
      s_desc_block_id = 16'(global_block_id);
      s_desc_block_range_start = 16'(input_block_range_start[global_block_id]);
      s_desc_frame_id = input_block_frame_id[global_block_id][15:0];
      s_desc_codec_mode = input_block_pred[global_block_id][7:0];
      s_desc_rice_mode = input_block_rice_mode[global_block_id][7:0];
      s_desc_fixed_k = input_block_fixed_k[global_block_id][3:0];
      s_desc_tensor_spatial_size = input_block_tensor_spatial[global_block_id][15:0];
      s_desc_tensor_doppler_size = input_block_tensor_doppler[global_block_id][15:0];
      s_desc_tensor_range_size = input_block_tensor_range[global_block_id][15:0];
      s_desc_last_block = (global_block_id == input_last_block_id);
      s_desc_valid = 1'b1;
      while (!s_desc_ready) begin
        @(negedge clk);
      end
      @(posedge clk);
      desc_issue_cycle_by_block[global_block_id] = $time / 10;
      desc_issue_count = desc_issue_count + 1;
      @(negedge clk);
      s_desc_valid = 1'b0;
    end
  end

  task automatic compare_packet_pair(input integer global_block_id);
    integer idx;
    begin
      if (ref_packet_num_bytes[global_block_id] != wrap_packet_num_bytes[global_block_id]) begin
        $fatal(1, "FAIL ddr-multiengine packet bytes block_id=%0d ref=%0d wrap=%0d",
               global_block_id, ref_packet_num_bytes[global_block_id], wrap_packet_num_bytes[global_block_id]);
      end
      for (idx = 0; idx < ref_packet_num_bytes[global_block_id]; idx = idx + 1) begin
        if (ref_packet_bytes[global_block_id][idx] !== wrap_packet_bytes[global_block_id][idx]) begin
          $fatal(1, "FAIL ddr-multiengine packet mismatch block_id=%0d idx=%0d ref=%02x wrap=%02x",
                 global_block_id, idx, ref_packet_bytes[global_block_id][idx], wrap_packet_bytes[global_block_id][idx]);
        end
      end
    end
  endtask

  task automatic write_compare_csv;
    integer block_order_idx;
    integer block_id;
    begin
      compare_fd = $fopen(compare_csv_path, "w");
      if (compare_fd == 0) begin
        $fatal(1, "failed to open %s", compare_csv_path);
      end
      $fwrite(compare_fd,
        "case_name,blocks,num_engines,output_order_idx,block_id,packet_complete,payload_byte_exact,decoder_loopback_pass,raw_bypass,packet_bytes,selected_k_match,compression_ratio_match,packet_non_interleaved,output_ordering_mode\n");
      for (block_order_idx = 0; block_order_idx < wrap_packet_order_count; block_order_idx = block_order_idx + 1) begin
        block_id = wrap_packet_order[block_order_idx];
        $fwrite(compare_fd,
          "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%s\n",
          scenario_name,
          expected_blocks_runtime,
          NUM_ENGINES,
          block_order_idx,
          block_id,
          (wrap_packet_seen[block_id] == 1),
          1,
          (decode_block_seen[block_id] == 1),
          input_block_raw_bypass[block_id],
          wrap_packet_num_bytes[block_id],
          1,
          1,
          1,
          "OUT_OF_ORDER"
        );
      end
      $fclose(compare_fd);
    end
  endtask

  task automatic write_latency_csv;
    integer fd;
    integer block_order_idx;
    integer block_id;
    integer total_cycles;
    integer packet_cycles;
    integer mem_wait_accum;
    integer feeder_axis_stall_accum;
    integer feeder_busy_accum;
    integer engine_busy_accum;
    integer pktbuf_full_accum;
    integer pktbuf_write_stall_accum;
    integer pktbuf_read_stall_accum;
    integer completed_pkt_wait_accum;
    begin
      fd = $fopen(latency_csv_path, "w");
      if (fd == 0) begin
        $fatal(1, "failed to open %s", latency_csv_path);
      end
      $fwrite(fd,
        "mode,scenario,block_index,block_id,output_order_idx,codec_mode,selected_k,use_raw,raw_bytes,packet_bytes_total,compression_ratio,desc_issue_cycle,packet_first_cycle,packet_last_cycle,decode_last_cycle,packet_cycles,total_first_input_to_decode,num_engines,ddr_read_latency,ddr_burst_beats,max_outstanding,desc_stall_cycles,output_arb_stall_cycles,output_backpressure_cycles,mem_wait_cycles,feeder_axis_stall_cycles,engine_busy_cycles,feeder_busy_cycles,packet_buffer_full_cycles,packet_buffer_write_stall_cycles,packet_buffer_read_stall_cycles,completed_packet_wait_cycles,arbiter_idle_cycles,arbiter_active_cycles\n");
      mem_wait_accum = 0;
      feeder_axis_stall_accum = 0;
      feeder_busy_accum = 0;
      engine_busy_accum = 0;
      pktbuf_full_accum = 0;
      pktbuf_write_stall_accum = 0;
      pktbuf_read_stall_accum = 0;
      completed_pkt_wait_accum = 0;
      begin : sum_stats
        integer eng_idx;
        for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
          mem_wait_accum = mem_wait_accum + u_wrapper.feeder_mem_wait_cycles_shadow_reg[eng_idx];
          feeder_axis_stall_accum = feeder_axis_stall_accum + u_wrapper.feeder_axis_stall_cycles_shadow_reg[eng_idx];
          feeder_busy_accum = feeder_busy_accum + u_wrapper.feeder_busy_cycles_reg[eng_idx];
          engine_busy_accum = engine_busy_accum + u_wrapper.engine_busy_cycles_reg[eng_idx];
          pktbuf_full_accum = pktbuf_full_accum + u_wrapper.pktbuf_full_cycles_reg[eng_idx];
          pktbuf_write_stall_accum = pktbuf_write_stall_accum + u_wrapper.pktbuf_write_stall_shadow_reg[eng_idx];
          pktbuf_read_stall_accum = pktbuf_read_stall_accum + u_wrapper.pktbuf_read_stall_shadow_reg[eng_idx];
          completed_pkt_wait_accum = completed_pkt_wait_accum + u_wrapper.completed_packet_wait_cycles_reg[eng_idx];
        end
      end
      for (block_order_idx = 0; block_order_idx < wrap_packet_order_count; block_order_idx = block_order_idx + 1) begin
        block_id = wrap_packet_order[block_order_idx];
        packet_cycles = packet_last_cycle_by_block[block_id] - packet_first_cycle_by_block[block_id] + 1;
        total_cycles = (decode_last_cycle_by_block[block_id] >= 0) ?
          (decode_last_cycle_by_block[block_id] - desc_issue_cycle_by_block[block_id] + 1) : -1;
        $fwrite(fd,
          "PREFIX_FAST_STREAM_LENGTH_CAPTURE_PREFIX_LANE4_BPACK_DDR_X%0d,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
          NUM_ENGINES,
          scenario_name,
          block_order_idx,
          block_id,
          block_order_idx,
          input_block_pred[block_id],
          wrap_packet_bytes[block_id][MRTC_HDR_OFF_RICE_K],
          input_block_raw_bypass[block_id],
          MRTC_RAW_BYTES,
          wrap_packet_num_bytes[block_id],
          (wrap_packet_num_bytes[block_id] > 0) ? (real'(MRTC_RAW_BYTES) / real'(wrap_packet_num_bytes[block_id])) : 0.0,
          desc_issue_cycle_by_block[block_id],
          packet_first_cycle_by_block[block_id],
          packet_last_cycle_by_block[block_id],
          decode_last_cycle_by_block[block_id],
          packet_cycles,
          total_cycles,
          NUM_ENGINES,
          DDR_READ_LATENCY,
          DDR_BURST_BEATS,
          MAX_OUTSTANDING,
          u_wrapper.desc_stall_cycles_reg,
          u_wrapper.output_arb_stall_cycles_reg,
          u_wrapper.output_backpressure_cycles_reg,
          mem_wait_accum,
          feeder_axis_stall_accum,
          engine_busy_accum,
          feeder_busy_accum,
          pktbuf_full_accum,
          pktbuf_write_stall_accum,
          pktbuf_read_stall_accum,
          completed_pkt_wait_accum,
          u_wrapper.arbiter_idle_cycles_reg,
          u_wrapper.arbiter_active_cycles_reg
        );
      end
      $fclose(fd);
    end
  endtask

  task automatic write_engine_util_csv;
    integer fd;
    integer engine_idx;
    integer total_cycles_elapsed;
    begin
      fd = $fopen(util_csv_path, "w");
      if (fd == 0) begin
        $fatal(1, "failed to open %s", util_csv_path);
      end
      $fwrite(fd,
        "scenario,num_engines,engine_idx,blocks_dispatched,packets_output,busy_cycles,total_cycles_elapsed,utilization,desc_stall_cycles,output_arb_stall_cycles,output_backpressure_cycles,packet_ordering_mode\n");
      total_cycles_elapsed = (wrap_packet_order_count > 0) ?
        (packet_last_cycle_by_block[wrap_packet_order[wrap_packet_order_count - 1]] + 1) : 0;
      for (engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx = engine_idx + 1) begin
        $fwrite(fd,
          "%s,%0d,%0d,%0d,%0d,%0d,%0d,%.6f,%0d,%0d,%0d,%s\n",
          scenario_name,
          NUM_ENGINES,
          engine_idx,
          u_wrapper.desc_per_engine_reg[engine_idx],
          u_wrapper.output_packets_per_engine_reg[engine_idx],
          u_wrapper.engine_busy_cycles_reg[engine_idx],
          total_cycles_elapsed,
          (total_cycles_elapsed > 0) ? (real'(u_wrapper.engine_busy_cycles_reg[engine_idx]) / real'(total_cycles_elapsed)) : 0.0,
          u_wrapper.desc_stall_cycles_reg,
          u_wrapper.output_arb_stall_cycles_reg,
          u_wrapper.output_backpressure_cycles_reg,
          "OUT_OF_ORDER"
        );
      end
      $fclose(fd);
    end
  endtask

  task automatic write_feeder_util_csv;
    integer fd;
    integer engine_idx;
    integer total_cycles_elapsed;
    begin
      fd = $fopen(feeder_util_csv_path, "w");
      if (fd == 0) begin
        $fatal(1, "failed to open %s", feeder_util_csv_path);
      end
      $fwrite(fd,
        "scenario,num_engines,engine_idx,blocks_fed,bursts_issued,beats_streamed,feeder_busy_cycles,mem_wait_cycles,axis_stall_cycles,total_cycles_elapsed,feeder_utilization\n");
      total_cycles_elapsed = (wrap_packet_order_count > 0) ?
        (packet_last_cycle_by_block[wrap_packet_order[wrap_packet_order_count - 1]] + 1) : 0;
      for (engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx = engine_idx + 1) begin
        $fwrite(fd,
          "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f\n",
          scenario_name,
          NUM_ENGINES,
          engine_idx,
          u_wrapper.feeder_blocks_fed_sig[engine_idx],
          u_wrapper.feeder_bursts_shadow_reg[engine_idx],
          u_wrapper.feeder_beats_shadow_reg[engine_idx],
          u_wrapper.feeder_busy_cycles_reg[engine_idx],
          u_wrapper.feeder_mem_wait_cycles_shadow_reg[engine_idx],
          u_wrapper.feeder_axis_stall_cycles_shadow_reg[engine_idx],
          total_cycles_elapsed,
          (total_cycles_elapsed > 0) ? (real'(u_wrapper.feeder_busy_cycles_reg[engine_idx]) / real'(total_cycles_elapsed)) : 0.0
        );
      end
      $fclose(fd);
    end
  endtask

  task automatic write_pktbuf_util_csv;
    integer fd;
    integer engine_idx;
    integer total_cycles_elapsed;
    begin
      fd = $fopen(pktbuf_util_csv_path, "w");
      if (fd == 0) begin
        $fatal(1, "failed to open %s", pktbuf_util_csv_path);
      end
      $fwrite(fd,
        "scenario,num_engines,engine_idx,packets_written,packets_read,write_stall_cycles,read_stall_cycles,full_cycles,completed_packet_wait_cycles,max_occupancy,total_cycles_elapsed,buffer_utilization,arbiter_idle_cycles,arbiter_active_cycles\n");
      total_cycles_elapsed = (wrap_packet_order_count > 0) ?
        (packet_last_cycle_by_block[wrap_packet_order[wrap_packet_order_count - 1]] + 1) : 0;
      for (engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx = engine_idx + 1) begin
        $fwrite(fd,
          "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f,%0d,%0d\n",
          scenario_name,
          NUM_ENGINES,
          engine_idx,
          u_wrapper.pktbuf_packets_written_shadow_reg[engine_idx],
          u_wrapper.pktbuf_packets_read_shadow_reg[engine_idx],
          u_wrapper.pktbuf_write_stall_shadow_reg[engine_idx],
          u_wrapper.pktbuf_read_stall_shadow_reg[engine_idx],
          u_wrapper.pktbuf_full_cycles_reg[engine_idx],
          u_wrapper.completed_packet_wait_cycles_reg[engine_idx],
          u_wrapper.pktbuf_max_occupancy_shadow_reg[engine_idx],
          total_cycles_elapsed,
          (total_cycles_elapsed > 0) ? (real'(u_wrapper.completed_packet_wait_cycles_reg[engine_idx]) / real'(total_cycles_elapsed)) : 0.0,
          u_wrapper.arbiter_idle_cycles_reg,
          u_wrapper.arbiter_active_cycles_reg
        );
      end
      $fclose(fd);
    end
  endtask

  task automatic write_mem_bw_csv;
    integer fd;
    integer total_cycles_elapsed;
    integer total_beats;
    integer total_bursts;
    integer total_mem_wait;
    begin
      fd = $fopen(mem_bw_csv_path, "w");
      if (fd == 0) begin
        $fatal(1, "failed to open %s", mem_bw_csv_path);
      end
      total_cycles_elapsed = (wrap_packet_order_count > 0) ?
        (packet_last_cycle_by_block[wrap_packet_order[wrap_packet_order_count - 1]] + 1) : 0;
      total_beats = 0;
      total_bursts = 0;
      total_mem_wait = 0;
      begin : sum_mem
        integer engine_idx;
        for (engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx = engine_idx + 1) begin
          total_beats = total_beats + u_wrapper.feeder_beats_shadow_reg[engine_idx];
          total_bursts = total_bursts + u_wrapper.feeder_bursts_shadow_reg[engine_idx];
          total_mem_wait = total_mem_wait + u_wrapper.feeder_mem_wait_cycles_shadow_reg[engine_idx];
        end
      end
      $fwrite(fd,
        "scenario,num_engines,ddr_read_latency,ddr_burst_beats,max_outstanding,bandwidth_limit_beats_per_cycle,total_cycles,total_beats,total_bursts,total_mem_wait_cycles,average_read_bandwidth_bytes_per_cycle\n");
      $fwrite(fd,
        "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f\n",
        scenario_name,
        NUM_ENGINES,
        DDR_READ_LATENCY,
        DDR_BURST_BEATS,
        MAX_OUTSTANDING,
        BANDWIDTH_LIMIT_BEATS_PER_CYCLE,
        total_cycles_elapsed,
        total_beats,
        total_bursts,
        total_mem_wait,
        (total_cycles_elapsed > 0) ? (real'(total_beats * AXIS_BYTES) / real'(total_cycles_elapsed)) : 0.0
      );
      $fclose(fd);
    end
  endtask

  logic tb_error_seen;
  logic tb_counts_done;
  always_comb begin
    tb_error_seen =
      (wrap_stat_error != 0) ||
      (ref_stat_error != 0) ||
      (((wrap_bp_bypass_runtime == 0) ? 1'b1 : 1'b0) && (dec_stat_error != 0));
    tb_counts_done =
      (desc_issue_count == expected_blocks_runtime) &&
      (wrap_packet_order_count == expected_blocks_runtime) &&
      (wrap_stat_num_blocks == expected_blocks_runtime[31:0]) &&
      (ref_stat_num_blocks == expected_blocks_runtime[31:0]) &&
      (((wrap_bp_bypass_runtime != 0) ? 1'b1 : 1'b0) ||
       ((decode_stream_block_ptr == expected_blocks_runtime) &&
        (dec_stat_num_blocks == expected_blocks_runtime[31:0])));
  end

  initial begin
    wait(rst_n);
    wait (tb_error_seen || tb_counts_done);
    repeat (8) @(posedge clk);

    if (wrap_stat_error != 0) begin
      $fatal(1, "FAIL ddr-multiengine case=%s wrap_stat_error=%0d", resolved_case_dir, wrap_stat_error);
    end
    if (ref_stat_error != 0) begin
      $fatal(1, "FAIL ddr-multiengine case=%s ref_stat_error=%0d", resolved_case_dir, ref_stat_error);
    end
    if ((wrap_bp_bypass_runtime == 0) && (dec_stat_error != 0)) begin
      $fatal(1, "FAIL ddr-multiengine case=%s dec_stat_error=%0d", resolved_case_dir, dec_stat_error);
    end
    if ((wrapper_protocol_error_count != 0) ||
        (ref_protocol_error_count != 0) ||
        ((wrap_bp_bypass_runtime == 0) && (decoder_protocol_error_count != 0))) begin
      $fatal(1, "FAIL ddr-multiengine case=%s protocol wrap=%0d ref=%0d dec=%0d",
             resolved_case_dir, wrapper_protocol_error_count, ref_protocol_error_count, decoder_protocol_error_count);
    end

    begin : compare_all_blocks
      integer block_idx;
      integer global_block_id;
      for (block_idx = 0; block_idx < expected_blocks_runtime; block_idx = block_idx + 1) begin
        global_block_id = block_id_base_runtime + block_idx;
        compare_packet_pair(global_block_id);
        if ((wrap_bp_bypass_runtime == 0) && (decode_block_seen[global_block_id] != 1)) begin
          $fatal(1, "FAIL ddr-multiengine case=%s decode missing block_id=%0d",
                 resolved_case_dir, global_block_id);
        end
      end
    end

    if ((wrap_bp_bypass_runtime == 0) && decode_mismatch_seen) begin
      $fatal(1, "FAIL ddr-multiengine case=%s decode mismatch block_id=%0d byte=%0d exp=%02x got=%02x",
             resolved_case_dir,
             decode_mismatch_block_id,
             decode_mismatch_byte_idx,
             decode_mismatch_exp,
             decode_mismatch_got);
    end

    if (expected_blocks_runtime >= NUM_ENGINES) begin : check_all_engines_participated
      integer engine_idx;
      for (engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx = engine_idx + 1) begin
        if ((u_wrapper.feeder_blocks_fed_sig[engine_idx] == 0) ||
            (u_wrapper.output_packets_per_engine_reg[engine_idx] == 0)) begin
          $fatal(1,
                 "FAIL ddr-multiengine case=%s engine=%0d blocks_fed=%0d packets=%0d",
                 resolved_case_dir,
                 engine_idx,
                 u_wrapper.feeder_blocks_fed_sig[engine_idx],
                 u_wrapper.output_packets_per_engine_reg[engine_idx]);
        end
      end
    end
    if (status_clear_checks != 1) begin
      $fatal(1, "FAIL ddr-multiengine missing status-clear priority check");
    end

    write_compare_csv();
    write_latency_csv();
    write_engine_util_csv();
    write_feeder_util_csv();
    if (pktbuf_util_csv_path.len() != 0) begin
      write_pktbuf_util_csv();
    end
    write_mem_bw_csv();

    $display(
      "PASS tb_rdtc_ddr_multiengine_wrapper case=%s blocks=%0d num_engines=%0d wrap_blocks=%0d ref_blocks=%0d dec_blocks=%0d",
      resolved_case_dir,
      expected_blocks_runtime,
      NUM_ENGINES,
      wrap_stat_num_blocks,
      ref_stat_num_blocks,
      dec_stat_num_blocks
    );
    $finish;
  end

  initial begin
    repeat (15000000) @(posedge clk);
    $fatal(1, "TIMEOUT ddr-multiengine case=%s", resolved_case_dir);
  end
endmodule
