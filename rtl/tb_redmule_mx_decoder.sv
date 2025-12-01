module tb_redmule_mx_decoder;
  //parameters
  localparam int unsigned DATA_W    = 256;
  localparam int unsigned BITW      = 16;
  localparam int unsigned NUM_ELEMS = DATA_W / 8;

  //Signals
  logic                   clk_i;
  logic                   rst_ni;

  logic                   mx_val_valid_i;
  logic                   mx_val_ready_o;
  logic [DATA_W-1:0]      mx_val_data_i;

  logic                   mx_exp_valid_i;
  logic                   mx_exp_ready_o;
  logic [7:0]             mx_exp_data_i;

  logic                   fp16_valid_o;
  logic                   fp16_ready_i;
  logic [BITW-1:0]        fp16_data_o;

  // File I/O for golden model vectors
  integer fd;
  integer rc;
  integer test_idx;

  // Per-element FP8 inputs and FP16 expected outputs
  logic [7:0]  fp8_vals      [NUM_ELEMS];
  logic [15:0] fp16_expected [NUM_ELEMS];

  // DUT 
  redmule_mx_decoder #(
    .DATA_W(DATA_W),
    .BITW(BITW)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .mx_val_valid_i(mx_val_valid_i),
    .mx_val_ready_o(mx_val_ready_o),
    .mx_val_data_i(mx_val_data_i),
    .mx_exp_valid_i(mx_exp_valid_i),
    .mx_exp_ready_o(mx_exp_ready_o),
    .mx_exp_data_i(mx_exp_data_i),
    .fp16_valid_o(fp16_valid_o),
    .fp16_ready_i(fp16_ready_i),
    .fp16_data_o(fp16_data_o)
  );

  // clock
  initial clk_i = 0;
  always #5 clk_i = ~clk_i; // 100 MHz

  // send one MX block and check all 32 outputs
  task automatic run_block(
    input  logic [7:0]  fp8_block   [NUM_ELEMS],
    input  logic [7:0]  shared_exp,
    input  logic [15:0] fp16_block  [NUM_ELEMS],
    input  string       name
  );
    int out_count;
    int i;

    $display("=== TEST: %s ===", name);

    // pack 32 FP8 values into the 256-bit word
    mx_val_data_i = '0;
    for (i = 0; i < NUM_ELEMS; i++) begin
      // must match elem_mx = val_reg_q[8*elem_idx_q +: 8];
      mx_val_data_i[8*i +: 8] = fp8_block[i];
    end

    mx_exp_data_i  = shared_exp;
    mx_val_valid_i = 1'b1;
    mx_exp_valid_i = 1'b1;

    @(posedge clk_i);
    mx_val_valid_i = 1'b0;
    mx_exp_valid_i = 1'b0;

    // collect and check outputs
    out_count = 0;
    while (out_count < NUM_ELEMS) begin
      @(posedge clk_i);
      if (fp16_valid_o) begin
        assert (fp16_data_o === fp16_block[out_count])
          else $error("[%s] Mismatch at elem %0d: got 0x%04h expected 0x%04h",
                      name, out_count, fp16_data_o, fp16_block[out_count]);
        out_count++;
      end
    end

    $display("=== TEST PASSED: %s ===", name);
  endtask

  // stimuli
  initial begin
    // init 
    rst_ni          = 0;
    mx_val_valid_i  = 0;
    mx_val_data_i   = '0;
    mx_exp_valid_i  = 0;
    mx_exp_data_i   = '0;
    fp16_ready_i    = 1; // always ready

    // reset
    #20;
    rst_ni = 1;
    #20;

    // ---------------------- TESTS FROM PYTHON GOLDEN MODEL ----------------------
    // File format, one block per line (all hex):
    //   <shared_exp> <32×fp8_vals> <32×fp16_expected>

    fd = $fopen("../golden-model/MX/mx_decoder_vectors.txt", "r");
    if (fd == 0) begin
      $fatal(1, "ERROR: could not open mx_decoder_vectors.txt");
    end

    test_idx = 0;
    while (!$feof(fd)) begin
      int i;

      // read shared exponent
      rc = $fscanf(fd, "%h", mx_exp_data_i);
      if (rc != 1) begin
        break; // maybe empty line at end
      end

      // read 32 FP8 values
      for (i = 0; i < NUM_ELEMS; i++) begin
        rc = $fscanf(fd, " %h", fp8_vals[i]);
        if (rc != 1) $fatal(1, "Error reading FP8 value %0d", i);
      end

      // read 32 expected FP16 values
      for (i = 0; i < NUM_ELEMS; i++) begin
        rc = $fscanf(fd, " %h", fp16_expected[i]);
        if (rc != 1) $fatal(1, "Error reading FP16 expected %0d", i);
      end

      // run the block
      run_block(fp8_vals, mx_exp_data_i, fp16_expected,
                $sformatf("block_%0d", test_idx));
      test_idx++;
    end

    $fclose(fd);

    $display("All tests done. Ran %0d blocks.", test_idx);
    $finish;
  end

endmodule
