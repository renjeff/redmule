module tb_redmule_mx_roundtrip;
  // parameters
  parameter int unsigned DATA_W    = 256;
  parameter int unsigned BITW      = 16;
  parameter int unsigned NUM_ELEMS = DATA_W / 8;
  parameter int unsigned NUM_LANES = 4;
  parameter int unsigned NUM_TESTS = 100; // number of random blocks to test

  // signals
  logic                        clk_i;
  logic                        rst_ni;

  // FP16 input to encoder
  logic                        enc_fp16_valid;
  logic                        enc_fp16_ready;
  logic [NUM_LANES*BITW-1:0]   enc_fp16_data;

  // MX encoder outputs → decoder inputs
  logic                        mx_val_valid;
  logic                        mx_val_ready;
  logic [DATA_W-1:0]           mx_val_data;

  logic                        mx_exp_valid;
  logic                        mx_exp_ready;
  logic [7:0]                  mx_exp_data;

  // FP16 output from decoder
  logic                        dec_fp16_valid;
  logic                        dec_fp16_ready;
  logic [NUM_LANES*BITW-1:0]   dec_fp16_data;

  // test bookkeeping
  integer test_idx;
  integer error_count = 0;

  // per-test data
  logic [15:0] fp16_original [NUM_ELEMS];
  logic [15:0] fp16_roundtrip [NUM_ELEMS];

  // encoder DUT
  redmule_mx_encoder #(
    .DATA_W   (DATA_W),
    .BITW     (BITW),
    .NUM_LANES(NUM_LANES)
  ) i_encoder (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .fp16_valid_i   (enc_fp16_valid),
    .fp16_ready_o   (enc_fp16_ready),
    .fp16_data_i    (enc_fp16_data),
    .mx_val_valid_o (mx_val_valid),
    .mx_val_ready_i (mx_val_ready),
    .mx_val_data_o  (mx_val_data),
    .mx_exp_valid_o (mx_exp_valid),
    .mx_exp_ready_i (mx_exp_ready),
    .mx_exp_data_o  (mx_exp_data)
  );

  // decoder DUT
  redmule_mx_decoder #(
    .DATA_W   (DATA_W),
    .BITW     (BITW),
    .NUM_LANES(NUM_LANES)
  ) i_decoder (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .mx_val_valid_i (mx_val_valid),
    .mx_val_ready_o (mx_val_ready),
    .mx_val_data_i  (mx_val_data),
    .mx_exp_valid_i (mx_exp_valid),
    .mx_exp_ready_o (mx_exp_ready),
    .mx_exp_data_i  (mx_exp_data),
    .fp16_valid_o   (dec_fp16_valid),
    .fp16_ready_i   (dec_fp16_ready),
    .fp16_data_o    (dec_fp16_data)
  );

  initial begin
    $display("=================================================");
    $display("MX ROUNDTRIP TEST: NUM_LANES = %0d", NUM_LANES);
    $display("Testing FP16 -> MXFP8 -> FP16 conversion chain");
    $display("=================================================");
  end

  // clock
  initial clk_i = 0;
  always #5 clk_i = ~clk_i; // 100 MHz

  // generate FP16 test vectors with LIMITED dynamic range (suitable for MX)
  function automatic void generate_fp16_block(output logic [15:0] block [NUM_ELEMS]);
    logic [4:0] base_exp;
    logic [9:0] rand_mant;
    logic sign;
    
    //Pick a random base exponent (avoid extremes)
    base_exp = 5'd10 + ($random % 10); // exponents 10-19
    
    for (int i = 0; i < NUM_ELEMS; i++) begin
      sign = $random & 1;
      rand_mant = $random & 10'h3FF;
      
      case (i % 8)
        0: block[i] = {1'b0, base_exp, 10'h000};           // 1.0 * 2^(base-15)
        1: block[i] = {1'b1, base_exp, 10'h000};           // -1.0 * 2^(base-15)
        2: block[i] = {sign, base_exp, rand_mant};         // random at base exp
        3: block[i] = {sign, base_exp + 5'd1, rand_mant};  // one exp higher
        4: block[i] = {sign, base_exp - 5'd1, rand_mant};  // one exp lower (within MX range)
        5: block[i] = {sign, base_exp + 5'd2, rand_mant};  // two exp higher
        6: block[i] = 16'h0000;                            // zero
        7: block[i] = {sign, base_exp, rand_mant};         // random at base exp
      endcase
    end
  endfunction

  //generate edge case block
  function automatic void generate_edge_case_block(output logic [15:0] block [NUM_ELEMS]);
    for (int i = 0; i < NUM_ELEMS; i++) begin
      case (i % 16)
        0:  block[i] = 16'h0000;  // +zero
        1:  block[i] = 16'h8000;  // -zero
        2:  block[i] = 16'h4000;  // 2.0 (clean)
        3:  block[i] = 16'hC000;  // -2.0 (clean)
        4:  block[i] = 16'h4001;  // 2.0 + 1 ULP (tests rounding)
        5:  block[i] = 16'h403F;  // 2.0 + 63 ULP (tests rounding)
        6:  block[i] = 16'h4040;  // 2.0 + 64 ULP (halfway - RNE)
        7:  block[i] = 16'h407F;  // 2.0 + 127 ULP (max error case)
        8:  block[i] = 16'h4080;  // 2.0 + 128 ULP (next FP8 value)
        9:  block[i] = 16'h48FF;  // 10.xxx with full mantissa
        10: block[i] = 16'hC8FF;  // -10.xxx with full mantissa
        11: block[i] = 16'h4BFF;  // near 16.0 with max mantissa
        12: block[i] = 16'h4C00;  // 16.0 (clean)
        13: block[i] = 16'h4FFF;  // near 32.0 with max mantissa
        14: block[i] = 16'h5000;  // 32.0 (clean)
        15: block[i] = 16'h4AAA;  // alternating mantissa pattern
      endcase
    end
  endfunction

  // roundtrip test: send FP16 block through encoder -> decoder and check output
  task automatic run_roundtrip(
    input  logic [15:0] fp16_block [NUM_ELEMS],
    input  string       name
  );
    int elem_idx;
    int out_count;
    real max_ulp_error;
    real avg_ulp_error;
    real total_ulp;
    
    // Expected max ULP for MXFP8 E4M3 roundtrip:
    // FP16 has 10 mantissa bits, FP8 E4M3 has 3 -> lose 7 bits
    // Max quantization error = 2^7 = 128 ULP
    // Use slightly higher threshold to account for rounding edge cases
    localparam real MAX_ALLOWED_ULP = 128.0;

    $display("--- Running: %s ---", name);

    // send FP16 inputs to encoder
    enc_fp16_valid = 1'b0;
    enc_fp16_data  = '0;
    dec_fp16_ready = 1'b1; // decoder output always ready

    elem_idx = 0;
    while (elem_idx < NUM_ELEMS) begin
      @(posedge clk_i);

      if (enc_fp16_ready) begin
        enc_fp16_data = '0;
        enc_fp16_valid = 1'b1;

        for (int l = 0; l < NUM_LANES; l++) begin
          int idx = elem_idx + l;
          if (idx < NUM_ELEMS) begin
            enc_fp16_data[BITW*l +: BITW] = fp16_block[idx];
          end
        end

        elem_idx += NUM_LANES;
      end else begin
        enc_fp16_valid = 1'b0;
      end
    end

    //done sending inputs
    @(posedge clk_i);
    enc_fp16_valid = 1'b0;
    enc_fp16_data  = '0;

    // collect decoder outputs
    out_count = 0;
    max_ulp_error = 0.0;
    total_ulp = 0.0;

    while (out_count < NUM_ELEMS) begin
      @(posedge clk_i);
      if (dec_fp16_valid) begin
        for (int l = 0; l < NUM_LANES; l++) begin
          if (out_count < NUM_ELEMS) begin
            logic [15:0] original, roundtrip;
            real ulp_err;

            original = fp16_block[out_count];
            roundtrip = dec_fp16_data[BITW*l +: BITW];
            fp16_roundtrip[out_count] = roundtrip;

            // compute ULP error for non-zero/non-inf/non-nan values
            ulp_err = compute_fp16_ulp_error(original, roundtrip);
            total_ulp += ulp_err;
            if (ulp_err > max_ulp_error) begin
              max_ulp_error = ulp_err;
            end

            // flag errors exceeding MX quantization tolerance
            if (ulp_err > MAX_ALLOWED_ULP) begin
              $display("  [ERROR] elem %0d: ULP=%.2f exceeds limit (0x%04h -> 0x%04h)",
                       out_count, ulp_err, original, roundtrip);
              error_count++;
            end else if (ulp_err > 64.0) begin
              // Info for large but acceptable errors
              $display("  [INFO] elem %0d: ULP=%.2f (0x%04h -> 0x%04h)",
                       out_count, ulp_err, original, roundtrip);
            end

            out_count++;
          end
        end
      end
    end

    avg_ulp_error = total_ulp / NUM_ELEMS;
    
    if (max_ulp_error <= MAX_ALLOWED_ULP) begin
      $display(" PASS - Max ULP: %.2f, Avg ULP: %.2f (limit: %.0f)", 
               max_ulp_error, avg_ulp_error, MAX_ALLOWED_ULP);
    end else begin
      $display(" FAIL - Max ULP: %.2f, Avg ULP: %.2f (limit: %.0f)", 
               max_ulp_error, avg_ulp_error, MAX_ALLOWED_ULP);
    end
  endtask

  // compute ULP error between two FP16 values
  function automatic real compute_fp16_ulp_error(
    input logic [15:0] a,
    input logic [15:0] b
  );
    logic [4:0] ea, eb;
    logic [9:0] ma, mb;
    int exp_diff;
    real ulp_size;
    real abs_diff;
    real val_a, val_b;

    begin
      ea = a[14:10];
      eb = b[14:10];
      ma = a[9:0];
      mb = b[9:0];

      // handle special cases
      if (a == b) begin
        return 0.0;
      end

      // zero, inf, nan
      if (ea == 5'b0 || ea == 5'b11111 || eb == 5'b0 || eb == 5'b11111) begin
        return 999.0; // large sentinel value
      end

      // normal case: compute ULP
      exp_diff = int'(ea) - 15 - 10;
      ulp_size = 2.0 ** exp_diff;

      // absolute difference between mantissas
      if (ea == eb) begin
        abs_diff = $itor(ma > mb ? ma - mb : mb - ma);
      end else begin
        // different exponents: use larger exp for ULP base
        if (ea > eb) begin
          exp_diff = int'(ea) - 15 - 10;
        end else begin
          exp_diff = int'(eb) - 15 - 10;
        end
        ulp_size = 2.0 ** exp_diff;

        // approximate: convert both to real and take difference
        val_a = fp16_to_real(a);
        val_b = fp16_to_real(b);
        abs_diff = (val_a > val_b ? val_a - val_b : val_b - val_a) / ulp_size;
        return abs_diff;
      end

      return abs_diff;
    end
  endfunction

  // helper: convert FP16 to real for error calculation
  function automatic real fp16_to_real(input logic [15:0] val);
    logic s;
    logic [4:0] e;
    logic [9:0] m;
    int exp_val;
    real mantissa;

    begin
      s = val[15];
      e = val[14:10];
      m = val[9:0];

      if (e == 5'b0) begin
        return 0.0; // zero/subnormal
      end else if (e == 5'b11111) begin
        return 999999.0; // inf/nan
      end

      exp_val = int'(e) - 15;
      mantissa = 1.0 + ($itor(m) / 1024.0);

      return (s ? -1.0 : 1.0) * mantissa * (2.0 ** exp_val);
    end
  endfunction

  // stimuli
  initial begin
    rst_ni         = 0;
    enc_fp16_valid = 0;
    enc_fp16_data  = '0;
    dec_fp16_ready = 1;

    #20;
    rst_ni = 1;
    #20;

    // First: run edge case test
    generate_edge_case_block(fp16_original);
    run_roundtrip(fp16_original, "edge_cases");

    // Then: run random tests
    for (test_idx = 0; test_idx < NUM_TESTS; test_idx++) begin
      generate_fp16_block(fp16_original);
      run_roundtrip(fp16_original, $sformatf("roundtrip_%0d", test_idx));
    end

    $display("=================================================");
    if (error_count == 0) begin
      $display("SUCCESS: All %0d roundtrip tests passed!", NUM_TESTS);
    end else begin
      $display("WARNING: %0d errors in %0d tests", error_count, NUM_TESTS);
    end
    $display("=================================================");
    $finish;
  end

endmodule
