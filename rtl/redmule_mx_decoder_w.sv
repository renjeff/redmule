// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// MX Decoder for W (weight) matrix data
// This decoder accepts a VECTOR of shared exponents (one per group/column).
// Each group of NUM_LANES elements uses its own scale factor for decoding.
//
// Data flow:
//   MX values + vector of shared exps -> per-group FP8->FP16 decode + scale ->
//   stream out FP16 values

module redmule_mx_decoder_w
#(
  parameter int unsigned DATA_W = 256,
  parameter int unsigned BITW = 16,
  parameter int unsigned NUM_LANES = 1
)(
  input  logic                   clk_i, 
  input  logic                   rst_ni,

  input  logic                   mx_val_valid_i,
  output logic                   mx_val_ready_o,
  input  logic [DATA_W-1:0]      mx_val_data_i,

  // Shared exponent input - VECTOR MODE: one exp per group
  input logic                    mx_exp_valid_i,
  output logic                   mx_exp_ready_o,
  input logic [NUM_LANES*8-1:0]  mx_exp_data_i,  // Vector of shared exponents

  output logic                   fp16_valid_o,
  input logic                    fp16_ready_i,
  output logic [NUM_LANES*BITW-1:0] fp16_data_o
);

// State machine
typedef enum logic [0:0] {
  IDLE,
  DECODE
} redmule_mx_decode_state_e;

redmule_mx_decode_state_e current_state, next_state;

// Biases for FP8/FP16
localparam int BIAS_FP8  = 7;
localparam int BIAS_FP16 = 15;

// Internal registers
localparam int unsigned ELEM_WIDTH = 8;
localparam int unsigned NUM_ELEMS = DATA_W / ELEM_WIDTH;
localparam int unsigned NUM_GROUPS = NUM_ELEMS / NUM_LANES;

logic [DATA_W-1:0] val_reg_q, val_reg_d;

// Per-group shared exponents
logic [7:0] scale_per_group_q [NUM_GROUPS];
logic [7:0] scale_per_group_d [NUM_GROUPS];

logic [$clog2(NUM_GROUPS)-1:0] group_idx_q, group_idx_d;

// MXFP8 datapath signals
logic [ELEM_WIDTH-1:0] elem_mx [NUM_LANES];
logic [BITW-1:0]       elem_fp16_unscaled [NUM_LANES];
logic [BITW-1:0]       elem_fp16_scaled [NUM_LANES];

genvar lane;
generate
  for (lane = 0; lane < NUM_LANES; lane++) begin : gen_lanes
    logic [$clog2(NUM_ELEMS)-1:0] elem_idx_lane;

    assign elem_idx_lane = group_idx_q * NUM_LANES + lane;

    // Slice out the FP8 element for this lane
    assign elem_mx[lane] = val_reg_q[ELEM_WIDTH*elem_idx_lane +: ELEM_WIDTH];

    // Per-lane decode using the GROUP's shared exponent
    always_comb begin
      logic [15:0] tmp;
      logic [7:0] group_scale;
      
      tmp = fp8_e4m3_to_fp16(elem_mx[lane]);
      elem_fp16_unscaled[lane] = tmp;
      
      // Use the current group's shared exponent
      group_scale = scale_per_group_q[group_idx_q];
      elem_fp16_scaled[lane] = mx_scale_fp16(tmp, group_scale);
    end
  end
endgenerate

// Sequential part
always_ff @(posedge clk_i or negedge rst_ni) begin : state_register
  if(!rst_ni) begin
    current_state <= IDLE;
    val_reg_q <= '0;
    group_idx_q <= '0;
    for (int g = 0; g < NUM_GROUPS; g++) begin
      scale_per_group_q[g] <= 8'd127;
    end
  end else begin
    current_state <= next_state;
    val_reg_q <= val_reg_d;
    group_idx_q <= group_idx_d;
    for (int g = 0; g < NUM_GROUPS; g++) begin
      scale_per_group_q[g] <= scale_per_group_d[g];
    end
  end
end

// FP8 E4M3 to FP16 conversion (unscaled)
function automatic logic [15:0] fp8_e4m3_to_fp16 (input logic [7:0] in);
  logic       s;
  logic [3:0] e8;
  logic [2:0] m8;

  logic [4:0]  e16;
  logic [9:0]  m16;
  int          e16_int;

  begin 
    s  = in[7];
    e8 = in[6:3];
    m8 = in[2:0];

    // Zero and subnormals -> signed zero
    if (e8 == 4'b0000) begin
      fp8_e4m3_to_fp16 = {s, 5'b0, 10'b0};

    // Inf / NaN
    end else if (e8 == 4'b1111) begin
      if (m8 == 3'b000) begin
        fp8_e4m3_to_fp16 = {s, 5'b11111, 10'b0};
      end else begin
        fp8_e4m3_to_fp16 = {s, 5'b11111, 10'b1000000000};
      end

    end else begin
      e16_int = int'(e8) - BIAS_FP8 + BIAS_FP16;
      e16     = e16_int[4:0];
      m16     = {m8, 7'b0};

      fp8_e4m3_to_fp16 = {s, e16, m16};
    end
  end
endfunction

// Apply MX shared exp (E8M0) as 2^k scale on FP16 value
function automatic logic [15:0] mx_scale_fp16(
  input logic [15:0] val_fp16,
  input logic [7:0] shared_exp
);
  logic s;
  logic [4:0] e16;
  logic [9:0] m16;

  int signed delta;
  int signed new_e16;

  localparam logic [15:0] FP16_MAX_POS = 16'h7bff;

  begin
    s = val_fp16[15];
    e16 = val_fp16[14:10];
    m16 = val_fp16[9:0];

    // Zero, Inf, NaN: return as is
    if (e16 == 5'b0 || e16 == 5'b11111) begin
      mx_scale_fp16 = val_fp16;

    end else begin
      delta = int'(shared_exp) - 127;
      new_e16 = int'(e16) + delta;

      // Underflow -> flush to signed 0
      if (new_e16 <= 0) begin
        mx_scale_fp16 = {s, 5'b0, 10'b0};
      
      // Overflow -> clamp to max finite with sign
      end else if (new_e16 >= 31) begin
        mx_scale_fp16 = {s, FP16_MAX_POS[14:0]};
      
      // Normal scaled case
      end else begin
        mx_scale_fp16 = {s, new_e16[4:0], m16};
      end
    end
  end
endfunction

// FSM combinational logic
always_comb begin : fsm
  next_state = current_state;
  val_reg_d = val_reg_q;
  group_idx_d = group_idx_q;
  
  for (int g = 0; g < NUM_GROUPS; g++) begin
    scale_per_group_d[g] = scale_per_group_q[g];
  end

  mx_val_ready_o = 1'b0;
  mx_exp_ready_o = 1'b0;
  fp16_valid_o = 1'b0;
  fp16_data_o = '0;
  
  unique case (current_state)
    IDLE: begin
      mx_val_ready_o = 1'b1;
      mx_exp_ready_o = 1'b1;

      if (mx_val_valid_i && mx_exp_valid_i) begin
        // Latch MX values
        val_reg_d = mx_val_data_i;
        
        // Unpack per-group exponents from input vector
        for (int g = 0; g < NUM_GROUPS; g++) begin
          scale_per_group_d[g] = mx_exp_data_i[8*g +: 8];
        end
        
        group_idx_d = '0;
        next_state = DECODE;
      end
    end

    DECODE: begin
      mx_val_ready_o = 1'b0;
      mx_exp_ready_o = 1'b0;

      fp16_valid_o = 1'b1;

      // Pack NUM_LANES outputs (each scaled with its group's exponent)
      for (int lane = 0; lane < NUM_LANES; lane++) begin
        fp16_data_o[BITW*lane +: BITW] = elem_fp16_scaled[lane];
      end

      if (fp16_ready_i) begin
        if (group_idx_q == NUM_GROUPS-1) begin
          group_idx_d = '0;
          next_state = IDLE;
        end else begin
          group_idx_d = group_idx_q + 1;
        end
      end
    end

    default: begin
      next_state = IDLE;
    end
  endcase
end

endmodule : redmule_mx_decoder_w
