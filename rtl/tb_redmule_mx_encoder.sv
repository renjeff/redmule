module tb_redmule_mx_encoder;
  // parameters
  parameter int unsigned DATA_W    = 256;
  parameter int unsigned BITW      = 16;
  parameter int unsigned NUM_ELEMS = DATA_W / 8;
  parameter int unsigned NUM_LANES = 8;
  parameter string VECTOR_FILE = "../golden-model/MX/mx_encoder_vectors_mxfp8_e4m3.txt";

  // sanity
  initial begin
    if (NUM_ELEMS % NUM_LANES != 0) begin
      $error("TB: NUM_ELEMS (%0d) must be divisible by NUM_LANES (%0d)",
             NUM_ELEMS, NUM_LANES);
    end
  end

  // signals
  logic                        clk_i;
  logic                        rst_ni;

  // FP16 input stream
  logic                        fp16_valid_i;
  logic                        fp16_ready_o;
  logic [NUM_LANES*BITW-1:0]   fp16_data_i;

  // MX outputs
  logic                        mx_val_valid_o;
  logic                        mx_val_ready_i;
  logic [DATA_W-1:0]           mx_val_data_o;

  logic                        mx_exp_valid_o;
  logic                        mx_exp_ready_i;
  logic [7:0]                  mx_exp_data_o;

  // file I/O
  integer fd;
  integer rc;
  integer test_idx;
  integer error_count = 0;

  // per-element FP16 inputs and FP8 expected outputs (for one block)
  logic [15:0] fp16_in      [NUM_ELEMS];
  logic [7:0]  mx_vals_exp  [NUM_ELEMS];
  logic [7:0]  shared_exp_exp;

  // DUT
  redmule_mx_encoder #(
    .DATA_W   (DATA_W),
    .BITW     (BITW),
    .NUM_LANES(NUM_LANES)
  ) dut (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),

    .fp16_valid_i   (fp16_valid_i),
    .fp16_ready_o   (fp16_ready_o),
    .fp16_data_i    (fp16_data_i),

    .mx_val_valid_o (mx_val_valid_o),
    .mx_val_ready_i (mx_val_ready_i),
    .mx_val_data_o  (mx_val_data_o),

    .mx_exp_valid_o (mx_exp_valid_o),
    .mx_exp_ready_i (mx_exp_ready_i),
    .mx_exp_data_o  (mx_exp_data_o)
  );

  initial begin
    $display("MX ENCODER RTL: NUM_LANES = %0d", NUM_LANES);
  end

  // clock
  initial clk_i = 0;
  always #5 clk_i = ~clk_i; // 100 MHz

  // send one FP16 block and check MX outputs
  task automatic run_block(
    input  logic [15:0] fp16_block [NUM_ELEMS],
    input  logic [7:0]  shared_exp,
    input  logic [7:0]  mx_block   [NUM_ELEMS],
    input  string       name
  );
    int i;
    int group;
    int elem_idx;

    $display("=== ENC TEST: %s ===", name);

    // default outputs ready
    mx_val_ready_i = 1'b1;
    mx_exp_ready_i = 1'b1;

    // ------------- drive FP16 inputs in groups of NUM_LANES -------------
    fp16_valid_i = 1'b0;
    fp16_data_i  = '0;

    elem_idx = 0;
    while (elem_idx < NUM_ELEMS) begin
      @(posedge clk_i);

      if (fp16_ready_o) begin
        // pack up to NUM_LANES FP16s into fp16_data_i
        fp16_data_i = '0;
        fp16_valid_i = 1'b1;

        for (int l = 0; l < NUM_LANES; l++) begin
          int idx = elem_idx + l;
          if (idx < NUM_ELEMS) begin
            fp16_data_i[BITW*l +: BITW] = fp16_block[idx];
          end
        end

        elem_idx += NUM_LANES;
      end else begin
        // backpressure from DUT, hold valid = 0
        fp16_valid_i = 1'b0;
      end
    end

    // done sending inputs
    @(posedge clk_i);
    fp16_valid_i = 1'b0;
    fp16_data_i  = '0;

    // ------------- wait for MX outputs -------------
    // encoder is block-based, expect exactly one MX block + one shared_exp
    wait (mx_val_valid_o && mx_exp_valid_o);
    @(posedge clk_i); // sample outputs

    // check shared exponent
    if (mx_exp_data_o !== shared_exp) begin
      $error("[%s] Shared exp mismatch: got 0x%02h expected 0x%02h",
             name, mx_exp_data_o, shared_exp);
      error_count++;
    end

    // check packed MX bytes
    for (i = 0; i < NUM_ELEMS; i++) begin
      logic [7:0] lane_val;
      lane_val = mx_val_data_o[8*i +: 8];

      if (lane_val !== mx_block[i]) begin
        $error("[%s] MX val mismatch at elem %0d: got 0x%02h expected 0x%02h",
               name, i, lane_val, mx_block[i]);
        $display("DEBUG TB: elem %0d fp16_in=0x%04h shared_exp=0x%02h",
           i, fp16_block[i], shared_exp);
        error_count++;
      end
    end

    $display("=== ENC TEST PASSED: %s ===", name);
  endtask

  // stimuli
  initial begin
    // init 
    rst_ni          = 0;
    fp16_valid_i    = 0;
    fp16_data_i     = '0;
    mx_val_ready_i  = 1'b0;
    mx_exp_ready_i  = 1'b0;

    #20;
    rst_ni = 1;
    #20;

    // open encoder vectors
    fd = $fopen(VECTOR_FILE, "r");
    if (fd == 0) begin
      $fatal(1, "ERROR: could not open vector file: %s", VECTOR_FILE);
    end

    test_idx = 0;
    while (!$feof(fd)) begin
      int i;

      // read 32 FP16 inputs
      rc = $fscanf(fd, "%h", fp16_in[0]);
      if (rc != 1) begin
        break; // maybe empty line at end
      end
      for (i = 1; i < NUM_ELEMS; i++) begin
        rc = $fscanf(fd, " %h", fp16_in[i]);
        if (rc != 1) $fatal(1, "Error reading FP16 value %0d", i);
      end

      // read shared exponent
      rc = $fscanf(fd, " %h", shared_exp_exp);
      if (rc != 1) $fatal(1, "Error reading shared_exp");

      // read 32 expected MXFP8 values
      for (i = 0; i < NUM_ELEMS; i++) begin
        rc = $fscanf(fd, " %h", mx_vals_exp[i]);
        if (rc != 1) $fatal(1, "Error reading MX val %0d", i);
      end

      // run the block
      run_block(fp16_in, shared_exp_exp, mx_vals_exp,
                $sformatf("enc_block_%0d", test_idx));
      test_idx++;
    end

    $fclose(fd);

    if (error_count == 0) begin
      $display("[TB] - Success!");
      $display("[TB] - All encoder tests passed! Ran %0d blocks.", test_idx);
    end else begin
      $display("[TB] - Fail!");
      $display("[TB] - Encoder tests failed with %0d errors. Ran %0d blocks.", error_count, test_idx);
    end
    $finish;
  end

endmodule
