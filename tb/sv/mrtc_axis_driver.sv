module mrtc_axis_driver #(
  parameter string CASE_DIR = "",
  parameter string HEX_FILE = "axis_raw_in.hex",
  parameter string CTRL_FILE = "axis_raw_in_ctrl.csv",
  parameter bit LOAD_BLOCK_CODECS = 1'b1,
  parameter bit EMIT_LAST_BYTE_COUNT = 1'b0,
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W = 8,
  parameter int MAX_RAW_BYTES = 16384,
  parameter int MAX_BEATS = 2048,
  parameter int MAX_BLOCKS = 64
) (
  input  logic                   clk,
  input  logic                   rst_n,
  output logic [AXIS_DATA_W-1:0] m_tdata,
  output logic                   m_tvalid,
  input  logic                   m_tready,
  output logic                   m_tlast,
  output logic [TUSER_W-1:0]     m_tuser,
  output logic                   o_done
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;

  byte raw_bytes   [0:MAX_RAW_BYTES-1];
  int  raw_byte_count;
  int  beat_block_idx [0:MAX_BEATS-1];
  int  beat_num_bytes [0:MAX_BEATS-1];
  int  beat_tlast     [0:MAX_BEATS-1];
  int  beat_count;
  int  block_codec    [0:MAX_BLOCKS-1];
  int  block_count;

  int current_beat;
  int current_byte_ptr;
  logic loaded;
  string resolved_case_dir;
  string cfg_valid_gap_mode;
  int unsigned cfg_gap_seed;
  int unsigned gap_rand_state;
  int unsigned gap_cycle_count;

  function automatic int unsigned next_rand(input int unsigned cur_state);
    next_rand = (cur_state * 32'd1664525) + 32'd1013904223;
  endfunction

  task automatic load_hex_file(input string path, output int count);
    int fd;
    int code;
    int value;
    begin
      count = 0;
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $fatal(1, "driver failed to open %s", path);
      end
      while (!$feof(fd) && count < MAX_RAW_BYTES) begin
        code = $fscanf(fd, "%h\n", value);
        if (code == 1) begin
          raw_bytes[count] = value[7:0];
          count = count + 1;
        end
      end
      if (!$feof(fd)) begin
        $fatal(1, "driver raw byte storage overflow for %s (MAX_RAW_BYTES=%0d)", path, MAX_RAW_BYTES);
      end
      $fclose(fd);
    end
  endtask

  task automatic load_ctrl_file(input string path, output int count);
    int fd;
    int code;
    string line;
    int blk;
    int word_idx;
    int num_bytes;
    int tlast;
    begin
      count = 0;
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $fatal(1, "driver failed to open %s", path);
      end
      void'($fgets(line, fd));
      while (!$feof(fd) && count < MAX_BEATS) begin
        line = "";
        void'($fgets(line, fd));
        if (line.len() == 0) begin
          continue;
        end
        code = $sscanf(line, "%d,%d,%d,%d", blk, word_idx, num_bytes, tlast);
        if (code == 4) begin
          beat_block_idx[count] = blk;
          beat_num_bytes[count] = num_bytes;
          beat_tlast[count] = tlast;
          count = count + 1;
        end
      end
      if (!$feof(fd)) begin
        $fatal(1, "driver beat storage overflow for %s (MAX_BEATS=%0d)", path, MAX_BEATS);
      end
      $fclose(fd);
    end
  endtask

  task automatic parse_header_predictor(input string path, output int predictor_mode);
    int fd;
    string line;
    int code;
    int magic;
    int version;
    int header_len;
    int frame_id;
    int block_id;
    int tensor_spatial_size;
    int tensor_doppler_size;
    int tensor_range_size;
    int block_spatial_start;
    int block_doppler_start;
    int block_range_start;
    int block_spatial_len;
    int block_doppler_len;
    int block_range_len;
    int sample_format;
    int codec_mode;
    int rice_k;
    int flags;
    int reserved0;
    int raw_bytes;
    int payload_bytes;
    int payload_bits;
    int crc32;
    begin
      predictor_mode = 0;
      fd = $fopen(path, "r");
      if (fd == 0) begin
        return;
      end
      void'($fgets(line, fd));
      line = "";
      void'($fgets(line, fd));
      if (line.len() != 0) begin
        code = $sscanf(
          line,
          "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
          magic, version, header_len, frame_id, block_id,
          tensor_spatial_size, tensor_doppler_size, tensor_range_size,
          block_spatial_start, block_doppler_start, block_range_start,
          block_spatial_len, block_doppler_len, block_range_len,
          sample_format, codec_mode, predictor_mode, rice_k, flags, reserved0,
          raw_bytes, payload_bytes, payload_bits, crc32
        );
        if (code != 24) begin
          predictor_mode = 0;
        end
      end
      $fclose(fd);
    end
  endtask

  task automatic load_block_codecs(input string case_dir, input int expected_blocks, output int count);
    string hdr_path;
    string blk_tag;
    int predictor_mode;
    int blk_idx;
    begin
      count = 0;
      for (blk_idx = 0; blk_idx < expected_blocks; blk_idx = blk_idx + 1) begin
        if (blk_idx >= MAX_BLOCKS) begin
          $fatal(1, "driver block codec storage overflow for %s (MAX_BLOCKS=%0d)", case_dir, MAX_BLOCKS);
        end
        if (blk_idx < 10) begin
          blk_tag = $sformatf("00%0d", blk_idx);
        end else if (blk_idx < 100) begin
          blk_tag = $sformatf("0%0d", blk_idx);
        end else begin
          blk_tag = $sformatf("%0d", blk_idx);
        end
        hdr_path = {case_dir, "/block_", blk_tag, "_header.csv"};
        parse_header_predictor(hdr_path, predictor_mode);
        block_codec[blk_idx] = predictor_mode;
        count = blk_idx + 1;
      end
    end
  endtask

  task automatic resolve_case_dir(output string case_dir);
    string vec_root;
    string case_name;
    begin
      if (CASE_DIR.len() != 0) begin
        case_dir = CASE_DIR;
      end else begin
        vec_root = "vectors/rdtc_v1";
        case_name = "";
        void'($value$plusargs("VEC_ROOT=%s", vec_root));
        void'($value$plusargs("CASE=%s", case_name));
        if (case_name.len() == 0) begin
          $fatal(1, "driver requires CASE_DIR parameter or +CASE plusarg");
        end
        case_dir = {vec_root, "/", case_name};
      end
    end
  endtask

  function automatic bit gap_allows_launch(
    input string mode,
    input int unsigned cycle_count,
    input int unsigned rand_value
  );
    begin
      gap_allows_launch = 1'b1;
      if (mode == "periodic") begin
        gap_allows_launch = ((cycle_count % 7) < 5);
      end else if (mode == "random") begin
        gap_allows_launch = (rand_value[7:0] >= 8'd51);
      end
    end
  endfunction

  initial begin
    int seed;
    cfg_valid_gap_mode = "none";
    seed = 32'd1;
    void'($value$plusargs("VALID_GAP_MODE=%s", cfg_valid_gap_mode));
    void'($value$plusargs("SEED=%d", seed));
    if (seed == 0) begin
      seed = 32'd1;
    end
    cfg_gap_seed = seed;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    int byte_idx;
    int unsigned next_gap_rand_state;
    bit allow_launch;
    if (!rst_n) begin
      m_tdata <= '0;
      m_tvalid <= 1'b0;
      m_tlast <= 1'b0;
      m_tuser <= '0;
      o_done <= 1'b0;
      current_beat <= 0;
      current_byte_ptr <= 0;
      loaded <= 1'b0;
      gap_rand_state <= cfg_gap_seed;
      gap_cycle_count <= 0;
    end else begin
      gap_cycle_count <= gap_cycle_count + 1;
      if (!loaded) begin
        string hex_path;
        string ctrl_path;
        int max_block_idx;
        int beat_idx;
        resolve_case_dir(resolved_case_dir);
        hex_path = {resolved_case_dir, "/", HEX_FILE};
        ctrl_path = {resolved_case_dir, "/", CTRL_FILE};
        load_hex_file(hex_path, raw_byte_count);
        load_ctrl_file(ctrl_path, beat_count);
        if (LOAD_BLOCK_CODECS) begin
          max_block_idx = 0;
          for (beat_idx = 0; beat_idx < beat_count; beat_idx = beat_idx + 1) begin
            if (beat_block_idx[beat_idx] > max_block_idx) begin
              max_block_idx = beat_block_idx[beat_idx];
            end
          end
          load_block_codecs(resolved_case_dir, max_block_idx + 1, block_count);
        end else begin
          block_count = 0;
        end
        loaded <= 1'b1;
      end

      if (!o_done) begin
        if (!m_tvalid && loaded && (current_beat < beat_count)) begin
          next_gap_rand_state = next_rand(gap_rand_state);
          gap_rand_state <= next_gap_rand_state;
          allow_launch = gap_allows_launch(cfg_valid_gap_mode, gap_cycle_count, next_gap_rand_state);
          if (allow_launch) begin
            m_tdata <= '0;
            for (byte_idx = 0; byte_idx < AXIS_BYTES; byte_idx = byte_idx + 1) begin
              if (byte_idx < beat_num_bytes[current_beat]) begin
                m_tdata[byte_idx*8 +: 8] <= raw_bytes[current_byte_ptr + byte_idx];
              end
            end
            m_tvalid <= 1'b1;
            m_tlast <= (beat_tlast[current_beat] != 0);
            m_tuser <= '0;
            if (current_beat == 0 && LOAD_BLOCK_CODECS) begin
              m_tuser[0] <= 1'b1;
            end
            if (LOAD_BLOCK_CODECS && (beat_block_idx[current_beat] < block_count)) begin
              m_tuser[2:1] <= block_codec[beat_block_idx[current_beat]][1:0];
              if (beat_block_idx[current_beat] == (block_count - 1)) begin
                m_tuser[3] <= 1'b1;
              end
            end
            if (EMIT_LAST_BYTE_COUNT && (beat_tlast[current_beat] != 0)) begin
              m_tuser[3:0] <= beat_num_bytes[current_beat][3:0] - 4'd1;
            end
          end
        end else if (m_tvalid && m_tready) begin
          current_byte_ptr <= current_byte_ptr + beat_num_bytes[current_beat];
          current_beat <= current_beat + 1;
          m_tvalid <= 1'b0;
          m_tlast <= 1'b0;
          m_tuser <= '0;
          if (current_beat + 1 >= beat_count) begin
            o_done <= 1'b1;
          end
        end
      end
    end
  end
endmodule
