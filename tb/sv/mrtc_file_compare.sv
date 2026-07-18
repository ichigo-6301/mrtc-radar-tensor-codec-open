module mrtc_file_compare #(
  parameter string CASE_DIR = "",
  parameter string EXPECTED_HEX_FILE = "axis_comp_expected.hex",
  parameter string EXPECTED_CTRL_FILE = "axis_comp_expected_ctrl.csv"
) (
  input logic i_start,
  input integer i_actual_byte_count,
  input integer i_actual_beat_count,
  input byte i_actual_bytes [0:32767],
  output logic o_pass,
  output integer o_first_mismatch,
  output byte o_expected_byte,
  output byte o_actual_byte
);
  localparam int MAX_EXPECTED_BYTES = 32768;
  localparam int MAX_EXPECTED_BEATS = 4096;

  byte expected_bytes [0:MAX_EXPECTED_BYTES-1];
  int expected_byte_count;
  int expected_beat_count;
  int last_expected_num_bytes;
  string resolved_case_dir;

  task automatic load_expected_hex(input string path, output int count);
    int fd;
    int code;
    int value;
    begin
      count = 0;
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $fatal(1, "compare failed to open %s", path);
      end
      while (!$feof(fd) && count < MAX_EXPECTED_BYTES) begin
        code = $fscanf(fd, "%h\n", value);
        if (code == 1) begin
          expected_bytes[count] = value[7:0];
          count = count + 1;
        end
      end
      $fclose(fd);
    end
  endtask

  task automatic load_expected_ctrl(input string path, output int count, output int last_num_bytes);
    int fd;
    string line;
    int code;
    int blk;
    int word_idx;
    int num_bytes;
    int tlast;
    begin
      count = 0;
      last_num_bytes = 0;
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $fatal(1, "compare failed to open %s", path);
      end
      void'($fgets(line, fd));
      while (!$feof(fd) && count < MAX_EXPECTED_BEATS) begin
        line = "";
        void'($fgets(line, fd));
        if (line.len() == 0) begin
          continue;
        end
        code = $sscanf(line, "%d,%d,%d,%d", blk, word_idx, num_bytes, tlast);
        if (code == 4) begin
          last_num_bytes = num_bytes;
          count = count + 1;
        end
      end
      $fclose(fd);
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
          $fatal(1, "compare requires CASE_DIR parameter or +CASE plusarg");
        end
        case_dir = {vec_root, "/", case_name};
      end
    end
  endtask

  always_comb begin
    o_pass = 1'b0;
    o_first_mismatch = -1;
    o_expected_byte = 8'h00;
    o_actual_byte = 8'h00;

    if (i_start) begin
      int idx;
      string hex_path;
      string ctrl_path;
      resolve_case_dir(resolved_case_dir);
      hex_path = {resolved_case_dir, "/", EXPECTED_HEX_FILE};
      ctrl_path = {resolved_case_dir, "/", EXPECTED_CTRL_FILE};
      load_expected_hex(hex_path, expected_byte_count);
      load_expected_ctrl(ctrl_path, expected_beat_count, last_expected_num_bytes);
      o_pass = (expected_byte_count == i_actual_byte_count) && (expected_beat_count == i_actual_beat_count);
      if (o_pass) begin
        for (idx = 0; idx < expected_byte_count; idx = idx + 1) begin
          if (expected_bytes[idx] !== i_actual_bytes[idx]) begin
            o_pass = 1'b0;
            o_first_mismatch = idx;
            o_expected_byte = expected_bytes[idx];
            o_actual_byte = i_actual_bytes[idx];
            break;
          end
        end
      end
    end
  end
endmodule
