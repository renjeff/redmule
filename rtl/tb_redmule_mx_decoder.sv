module tb_redmule_mx_decoder;
  //parameters
  localparam int unsigned DATA_W = 256;
  localparam int unsigned BITW = 16;

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

  //clk
  initial clk_i = 0;
  always #5 clk_i = ~clk_i; // 100Mhz

  //stimuli
  initial begin
    //init 
    rst_ni          = 0;
    mx_val_valid_i  = 0;
    mx_val_data_i   = '0;
    mx_exp_valid_i  = 0;
    mx_exp_data_i   = '0;
    fp16_ready_i    = 1; // always ready for now

    // reset
    #20;
    rst_ni = 1;

    // wait a bit
    #20;

    // drive one MX block
    mx_val_data_i  = 'hDEADBEEF_CAFE0000_C001C0DE_00010203; // some random pattern
    mx_exp_data_i  = 8'd169; // random exponent
    mx_val_valid_i = 1;
    mx_exp_valid_i = 1;

    // handshake
    @(posedge clk_i);
    mx_val_valid_i = 0;
    mx_exp_valid_i = 0;

    repeat (40) @(posedge clk_i);

    $finish;
  end

endmodule