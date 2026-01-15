module tb_redmule_mx_decoder_w;
  // parameters
  parameter int unsigned DATA_W    = 256;
  parameter int unsigned BITW      = 16;
  parameter int unsigned NUM_ELEMS = DATA_W / 8;  // 32 elements
  parameter int unsigned NUM_LANES = 8;
  parameter int unsigned NUM_GROUPS = NUM_ELEMS / NUM_LANES;  // 4 groups
  parameter int unsigned NUM_TESTS = 20;

  // sanity
  initial begin
    if (NUM_ELEMS % NUM_LANES != 0) begin
      $error("TB: NUM_ELEMS (%0d) must be divisible by NUM_LANES (%0d)",
             NUM_ELEMS, NUM_LANES);
    end
    $display("=================================================");
    $display("MX DECODER W (per-group exp) TESTBENCH");
    $display("DATA_W=%0d, NUM_ELEMS=%0d, NUM_LANES=%0d, NUM_GROUPS=%0d",
             DATA_W, NUM_ELEMS, NUM_LANES, NUM_GROUPS);
    $display("=================================================");
  end

  // signals
  logic                        clk_i;
  logic                        rst_ni;

  // MX inputs
  logic                        mx_val_valid_i;
  logic                        mx_val_ready_o;
  logic [DATA_W-1:0]           mx_val_data_i;

  logic                        mx_exp_valid_i;
  logic                        mx_exp_ready_o;
  logic [NUM_GROUPS*8-1:0]     mx_exp_data_i;  // Vector of per-group exponents

  // FP16 outputs
  logic                        fp16_valid_o;
  logic                        fp16_ready_i;
  logic [NUM_LANES*BITW-1:0]   fp16_data_o;

  // test bookkeeping
  integer test_idx;
  integer error_count = 0;

  // DUT
  redmule_mx_decoder #(
    .DATA_W    (DATA_W),
    .BITW      (BITW),
    .NUM_LANES (NUM_LANES)
  ) dut (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),

    .mx_val_valid_i (mx_val_valid_i),
    .mx_val_ready_o (mx_val_ready_o),
    .mx_val_data_i  (mx_val_data_i),

    .mx_exp_valid_i (mx_exp_valid_i),
    .mx_exp_ready_o (mx_exp_ready_o),
    .mx_exp_data_i  (mx_exp_data_i),
    .vector_shared_exp_i (1'b1),

    .fp16_valid_o   (fp16_valid_o),
    .fp16_ready_i   (fp16_ready_i),
    .fp16_data_o    (fp16_data_o)
  );

  // clock
  initial clk_i = 0;
  always #5 clk_i = ~clk_i; // 100 MHz

  // Generate test block with different exponents per group
  task automatic generate_test_block(
    output logic [7:0]  mx_vals [NUM_ELEMS],
    output logic [7:0]  exp_per_group [NUM_GROUPS]
  );
    // Assign different shared exponents per group
    for (int g = 0; g < NUM_GROUPS; g++) begin
      exp_per_group[g] = 8'd120 + g * 4;  // 120, 124, 128, 132
    end
    
    // Generate some FP8 values (simple patterns)
    for (int i = 0; i < NUM_ELEMS; i++) begin
      // FP8 E4M3: s[7], e[6:3], m[2:0]
      // Create values like 1.0, 1.5, 2.0, etc.
      case (i % 8)
        0: mx_vals[i] = 8'h38;  // +1.0 (e=7, m=0)
        1: mx_vals[i] = 8'h3C;  // +1.5 (e=7, m=4)
        2: mx_vals[i] = 8'h40;  // +2.0 (e=8, m=0)
        3: mx_vals[i] = 8'hB8;  // -1.0 (e=7, m=0, s=1)
        4: mx_vals[i] = 8'h30;  // +0.5 (e=6, m=0)
        5: mx_vals[i] = 8'h00;  // +0.0
        6: mx_vals[i] = 8'h44;  // +2.5 (e=8, m=4)
        7: mx_vals[i] = 8'h34;  // +0.75 (e=6, m=4)
      endcase
    end
  endtask

  // Run one test block
  task automatic run_block_test(
    input  logic [7:0] mx_vals [NUM_ELEMS],
    input  logic [7:0] exp_per_group [NUM_GROUPS],
    input  string      name
  );
    int group_idx;
    logic [7:0] received_exp_per_group [NUM_GROUPS];
    
    $display("=== W DEC TEST: %s ===", name);
    
    // Show input exponents
    $display("  Input exponents per group:");
    for (int g = 0; g < NUM_GROUPS; g++) begin
      $display("    Group %0d: exp=0x%02h", g, exp_per_group[g]);
    end

    // Ready to receive outputs
    fp16_ready_i = 1'b1;

    // Pack MX values into input
    mx_val_data_i = '0;
    for (int i = 0; i < NUM_ELEMS; i++) begin
      mx_val_data_i[8*i +: 8] = mx_vals[i];
    end
    
    // Pack exponents into vector
    mx_exp_data_i = '0;
    for (int g = 0; g < NUM_GROUPS; g++) begin
      mx_exp_data_i[8*g +: 8] = exp_per_group[g];
    end

    // Drive inputs valid
    @(posedge clk_i);
    mx_val_valid_i = 1'b1;
    mx_exp_valid_i = 1'b1;

    // Wait for DUT to accept inputs
    wait (mx_val_ready_o && mx_exp_ready_o);
    @(posedge clk_i);
    mx_val_valid_i = 1'b0;
    mx_exp_valid_i = 1'b0;

    // Receive FP16 outputs (NUM_GROUPS outputs)
    $display("  Received FP16 outputs:");
    for (group_idx = 0; group_idx < NUM_GROUPS; group_idx++) begin
      wait (fp16_valid_o);
      @(posedge clk_i);
      
      $display("    Group %0d (exp=0x%02h):", group_idx, exp_per_group[group_idx]);
      for (int l = 0; l < NUM_LANES; l++) begin
        logic [15:0] fp16_val;
        fp16_val = fp16_data_o[BITW*l +: BITW];
        $display("      Lane %0d: MX=0x%02h -> FP16=0x%04h", 
                 l, mx_vals[group_idx*NUM_LANES + l], fp16_val);
      end
    end

    // Extra cycle to let FSM return to IDLE
    @(posedge clk_i);
    @(posedge clk_i);

    $display("=== W DEC TEST DONE: %s ===\n", name);
  endtask

  // Main test sequence
  initial begin
    logic [7:0] mx_vals [NUM_ELEMS];
    logic [7:0] exp_per_group [NUM_GROUPS];
    
    // Init
    rst_ni          = 0;
    mx_val_valid_i  = 0;
    mx_val_data_i   = '0;
    mx_exp_valid_i  = 0;
    mx_exp_data_i   = '0;
    fp16_ready_i    = 1'b0;

    #20;
    rst_ni = 1;
    #20;

    // Run test blocks
    for (test_idx = 0; test_idx < NUM_TESTS; test_idx++) begin
      $display("\n--- Generating test block %0d ---", test_idx);
      generate_test_block(mx_vals, exp_per_group);
      run_block_test(mx_vals, exp_per_group, $sformatf("block_%0d", test_idx));
    end

    // Summary
    $display("\n=================================================");
    if (error_count == 0) begin
      $display("[TB] SUCCESS! All %0d W decoder tests completed.", NUM_TESTS);
    end else begin
      $display("[TB] FAILED! %0d errors in %0d tests.", error_count, NUM_TESTS);
    end
    $display("=================================================");
    $finish;
  end

endmodule
