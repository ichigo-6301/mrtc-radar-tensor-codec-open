module mrtc_raw_output_packer #(
  parameter int I_W = mrtc_pkg::MRTC_I_W,
  parameter int Q_W = mrtc_pkg::MRTC_Q_W,
  parameter int COMPLEX_SAMPLE_W = I_W + Q_W,
  parameter int PHASES_PER_BEAT = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int AXIS_DATA_W = COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int BLOCK_SAMPLES = mrtc_pkg::MRTC_COMPLEX_SAMPLES_PER_BLOCK,
  parameter int WORD_IDX_W = $clog2((BLOCK_SAMPLES + PHASES_PER_BEAT - 1) / PHASES_PER_BEAT)
) (
  input  logic [(BLOCK_SAMPLES*32)-1:0] i_sample_mem_flat,
  input  logic [WORD_IDX_W-1:0] i_word_idx,
  input  logic [10:0] i_num_samples,
  output logic [AXIS_DATA_W-1:0] o_tdata,
  output logic [$clog2((AXIS_DATA_W/8)+1)-1:0] o_valid_bytes
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int VALID_BYTE_COUNT_W = $clog2(AXIS_BYTES + 1);
  localparam int I_W_CHECK = 1 / ((I_W == 16) ? 1 : 0);
  localparam int Q_W_CHECK = 1 / ((Q_W == 16) ? 1 : 0);
  localparam int COMPLEX_SAMPLE_W_CHECK = 1 / ((COMPLEX_SAMPLE_W == 32) ? 1 : 0);
  localparam int AXIS_CHECK = 1 / ((AXIS_DATA_W == (COMPLEX_SAMPLE_W * PHASES_PER_BEAT)) ? 1 : 0);

  integer sample_base;
  integer remain_samples;

  function automatic logic [31:0] get_sample_word(input integer sample_index);
    get_sample_word = i_sample_mem_flat[(sample_index*32) +: 32];
  endfunction

  always_comb begin
    o_tdata = '0;
    sample_base = i_word_idx * PHASES_PER_BEAT;
    remain_samples = i_num_samples - sample_base;
    if (remain_samples <= 0) begin
      o_valid_bytes = '0;
    end else if (remain_samples >= PHASES_PER_BEAT) begin
      o_valid_bytes = VALID_BYTE_COUNT_W'(AXIS_BYTES);
    end else begin
      o_valid_bytes = VALID_BYTE_COUNT_W'(remain_samples * (COMPLEX_SAMPLE_W / 8));
    end

    for (int sample_offset = 0; sample_offset < PHASES_PER_BEAT; sample_offset = sample_offset + 1) begin
      if ((sample_base + sample_offset) < BLOCK_SAMPLES) begin
        o_tdata[(sample_offset * COMPLEX_SAMPLE_W) +: COMPLEX_SAMPLE_W] =
          get_sample_word(sample_base + sample_offset);
      end
    end
  end
endmodule
