module redmule_mx_encoder
#(
    parameter int unsigned DATA_W = 256,
    parameter int unsigned BITW = 16,
    parameter int unsigned NUM_LANES = 4
)(
    input logic                    clk_i,
    input logic                   rst_ni,

    // FP16 input stream
    input logic                  fp16_valid_i
    output logic                 fp16_ready_o,
    input logic [NUM_LANES*BITW-1:0]       fp16_data_i,

    // Shared exponent 
);