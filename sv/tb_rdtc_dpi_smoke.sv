`timescale 1ns/1ps

module tb_rdtc_dpi_smoke;
  import mrtc_dpi_pkg::*;

  localparam int N = 1024;
  localparam int OUT_MAX = 16384;

  shortint i_data [N];
  shortint q_data [N];
  shortint dec_i  [N];
  shortint dec_q  [N];
  byte unsigned comp [OUT_MAX];
  int out_num_bytes;
  int raw_bypass;
  int selected_k;
  int out_num_samples;
  int rc;

  initial begin
    for (int k = 0; k < N; k++) begin
      i_data[k] = 0;
      q_data[k] = 0;
    end
    i_data[100] = 7;
    q_data[100] = -3;
    i_data[512] = -12;
    q_data[700] = 9;

    rc = dpi_mrtc_rdtc_encode_block(i_data, q_data, N, MRTC_CODEC_ZERO_RICE,
      MRTC_RICE_BLOCK_ADAPTIVE_K, 0, 1, 1, 0, 0, 0, comp, OUT_MAX,
      out_num_bytes, raw_bypass, selected_k);
    if (rc != 0) begin
      $display("FAIL encode rc=%0d", rc);
      $finish(1);
    end
    $display("encoded bytes=%0d raw_bypass=%0d selected_k=%0d", out_num_bytes, raw_bypass, selected_k);

    rc = dpi_mrtc_rdtc_decode_block(comp, out_num_bytes, dec_i, dec_q, N, out_num_samples);
    if (rc != 0 || out_num_samples != N) begin
      $display("FAIL decode rc=%0d samples=%0d", rc, out_num_samples);
      $finish(1);
    end

    for (int k = 0; k < N; k++) begin
      if (dec_i[k] !== i_data[k] || dec_q[k] !== q_data[k]) begin
        $display("FAIL mismatch idx=%0d i exp=%0d got=%0d q exp=%0d got=%0d",
          k, i_data[k], dec_i[k], q_data[k], dec_q[k]);
        $finish(1);
      end
    end
    $display("PASS tb_rdtc_dpi_smoke");
    $finish(0);
  end
endmodule
