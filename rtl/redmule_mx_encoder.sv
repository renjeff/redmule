module redmule_mx_encoder
  import redmule_pkg::*;
#(
    parameter int unsigned DATA_W = 256,
    parameter int unsigned BITW = 16,
    parameter int unsigned NUM_LANES = 8
)(
    input logic                    clk_i,
    input logic                   rst_ni,
    input mx_format_e              mx_format_i,

    // FP16 input stream
    input logic                  fp16_valid_i,
    output logic                 fp16_ready_o,
    input logic [NUM_LANES*BITW-1:0]       fp16_data_i,

    output logic                         mx_val_valid_o,
    input  logic                         mx_val_ready_i,
    output logic [DATA_W-1:0]            mx_val_data_o,

    // Shared exponent
    output logic                         mx_exp_valid_o,
    input  logic                         mx_exp_ready_i,
    output logic [7:0]                   mx_exp_data_o
);

// Block parameters
localparam int unsigned ELEM_WIDTH = 8;
localparam int unsigned NUM_ELEMS = DATA_W / ELEM_WIDTH;
localparam int unsigned NUM_GROUPS = NUM_ELEMS / NUM_LANES;

localparam int BIAS_FP8_E4M3 = 7;
localparam int BIAS_FP8_E5M2 = 15;
localparam int BIAS_FP16     = 15;

// This pipelined implementation is specialized to NUM_GROUPS == 1, i.e. one
// MX block per input beat (the configuration produced by redmule_mx_output_stage,
// which sets MX_NUM_LANES = Width = NUM_ELEMS). The legacy FSM with multi-group
// reuse is gone — the new design accepts one block per cycle in steady state and
// pipelines max-find → scale → per-lane exp → mantissa pack across four registered
// stages (S1..S4). Each stage uses a standard valid/ready handshake; downstream
// back-pressure stalls upstream stages cleanly.
//
// NOTE: NUM_GROUPS > 1 is no longer supported; assertion below.
initial begin
  if (NUM_GROUPS != 1) begin
    $fatal(1, "redmule_mx_encoder: pipelined version requires NUM_GROUPS==1 (got %0d). Set NUM_LANES = NUM_ELEMS at instantiation.",
           NUM_GROUPS);
  end
end

// ---------------------------------------------------------------
//  Per-lane FP16 views (combinational from input bus)
// ---------------------------------------------------------------
logic [BITW-1:0]  fp16_lane [NUM_LANES];
logic [4:0]       e16_lane  [NUM_LANES];

genvar lane;
generate
  for (lane = 0; lane < NUM_LANES; lane++) begin : gen_lanes
    assign fp16_lane[lane] = fp16_data_i[BITW*lane +: BITW];
    assign e16_lane[lane]  = fp16_lane[lane][14:10];
  end
endgenerate

// ---------------------------------------------------------------
//  Helper functions (unchanged from pre-pipeline version)
// ---------------------------------------------------------------

function automatic logic [7:0] compute_shared_exp(input logic [4:0] max_e16, input mx_format_e fmt);
  int signed eM_unbiased;
  int signed scale_needed;
  int signed e8m0;
  int signed max_unbiased_e8;
  begin
    if (max_e16 == 5'd0) begin
      compute_shared_exp = 8'd127;
    end else begin
      case (fmt)
        MX_FMT_E5M2:  max_unbiased_e8 = 15;
        MX_FMT_E3M2:  max_unbiased_e8 = 3;
        MX_FMT_E2M3:  max_unbiased_e8 = 2;
        MX_FMT_E2M1:  max_unbiased_e8 = 2;
        default:       max_unbiased_e8 = 7;
      endcase
      eM_unbiased  = int'(max_e16) - BIAS_FP16;
      scale_needed = eM_unbiased - max_unbiased_e8;
      e8m0 = scale_needed + 127;
      if (e8m0 < 0)        compute_shared_exp = 8'd0;
      else if (e8m0 > 255) compute_shared_exp = 8'd255;
      else                 compute_shared_exp = e8m0[7:0];
    end
  end
endfunction

function automatic logic rne_round_up(
    input logic lsb, input logic round_bit, input logic sticky_bit
);
  logic [1:0] rs;
  begin
    rs = {round_bit, sticky_bit};
    unique case (rs)
      2'b00, 2'b01: rne_round_up = 1'b0;
      2'b10:        rne_round_up = lsb;
      2'b11:        rne_round_up = 1'b1;
      default:      rne_round_up = 1'b0;
    endcase
  end
endfunction

function automatic logic [ELEM_WIDTH-1:0] mx_max_finite(input logic s, input mx_format_e fmt);
  case (fmt)
    MX_FMT_E5M2: return {s, 5'b11110, 2'b11};
    MX_FMT_E3M2: return {2'b0, s, 3'b110, 2'b11};
    MX_FMT_E2M3: return {2'b0, s, 2'b11, 3'b111};
    MX_FMT_E2M1: return {4'b0, s, 2'b11, 1'b1};
    default:      return {s, 4'hE, 3'b111};
  endcase
endfunction

function automatic logic [ELEM_WIDTH-1:0] mx_inf(input logic s, input mx_format_e fmt);
  case (fmt)
    MX_FMT_E5M2: return {s, 5'b11111, 2'b00};
    MX_FMT_E3M2: return {2'b0, s, 3'b111, 2'b00};
    MX_FMT_E2M3: return {2'b0, s, 2'b11, 3'b111};
    MX_FMT_E2M1: return {4'b0, s, 2'b11, 1'b1};
    default:      return {s, 4'hF, 3'b000};
  endcase
endfunction

function automatic logic [ELEM_WIDTH-1:0] mx_nan(input logic s, input mx_format_e fmt);
  case (fmt)
    MX_FMT_E5M2: return {s, 5'b11111, 2'b01};
    MX_FMT_E3M2: return {2'b0, s, 3'b111, 2'b01};
    MX_FMT_E2M3: return {2'b0, s, 2'b11, 3'b111};
    MX_FMT_E2M1: return {4'b0, s, 2'b11, 1'b1};
    default:      return {s, 4'hF, 3'b001};
  endcase
endfunction

function automatic logic [ELEM_WIDTH-1:0] mx_normal_pack(
    input logic s,
    input logic signed [5:0] e8_biased,
    input logic [9:0] m16,
    input mx_format_e fmt
);
  logic rbit, sbit, round_up;
  begin
    case (fmt)
      MX_FMT_E5M2: begin
        logic [4:0] e_out; logic [1:0] m_trunc, m_round; logic carry;
        e_out = e8_biased[4:0]; m_trunc = m16[9:8];
        rbit = m16[7]; sbit = |m16[6:0];
        round_up = rne_round_up(m_trunc[0], rbit, sbit);
        {carry, m_round} = {1'b0, m_trunc} + round_up;
        if (carry) begin
          if (e_out >= 5'b11110) begin e_out = 5'b11110; m_round = 2'b11; end
          else                   e_out = e_out + 5'd1;
        end
        return {s, e_out, m_round};
      end
      MX_FMT_E3M2: begin
        logic [2:0] e_out; logic [1:0] m_trunc, m_round; logic carry;
        e_out = e8_biased[2:0]; m_trunc = m16[9:8];
        rbit = m16[7]; sbit = |m16[6:0];
        round_up = rne_round_up(m_trunc[0], rbit, sbit);
        {carry, m_round} = {1'b0, m_trunc} + round_up;
        if (carry) begin
          if (e_out >= 3'b110) begin e_out = 3'b110; m_round = 2'b11; end
          else                  e_out = e_out + 3'd1;
        end
        return {2'b0, s, e_out, m_round};
      end
      MX_FMT_E2M3: begin
        logic [1:0] e_out; logic [2:0] m_trunc, m_round; logic carry;
        e_out = e8_biased[1:0]; m_trunc = m16[9:7];
        rbit = m16[6]; sbit = |m16[5:0];
        round_up = rne_round_up(m_trunc[0], rbit, sbit);
        {carry, m_round} = {1'b0, m_trunc} + round_up;
        if (carry) begin
          if (e_out >= 2'b11) begin e_out = 2'b11; m_round = 3'b111; end
          else                 e_out = e_out + 2'd1;
        end
        return {2'b0, s, e_out, m_round};
      end
      MX_FMT_E2M1: begin
        logic [1:0] e_out; logic m_trunc, m_round; logic carry;
        e_out = e8_biased[1:0]; m_trunc = m16[9];
        rbit = m16[8]; sbit = |m16[7:0];
        round_up = rne_round_up(m_trunc, rbit, sbit);
        {carry, m_round} = {1'b0, m_trunc} + round_up;
        if (carry) begin
          if (e_out >= 2'b11) begin e_out = 2'b11; m_round = 1'b1; end
          else                 e_out = e_out + 2'd1;
        end
        return {4'b0, s, e_out, m_round};
      end
      default: begin // E4M3
        logic [3:0] e_out; logic [2:0] m_trunc, m_round; logic carry;
        e_out = e8_biased[3:0]; m_trunc = m16[9:7];
        rbit = m16[6]; sbit = |m16[5:0];
        round_up = rne_round_up(m_trunc[0], rbit, sbit);
        {carry, m_round} = {1'b0, m_trunc} + round_up;
        if (carry) begin
          if (e_out >= 4'hE) begin e_out = 4'hE; m_round = 3'b111; end
          else                e_out = e_out + 4'd1;
        end
        return {s, e_out, m_round};
      end
    endcase
  end
endfunction

// ---------------------------------------------------------------
//  Pipeline registers (4 stages, 1 block/cycle steady-state throughput)
// ---------------------------------------------------------------

// S1 — input latch + e16_max
logic                   s1_v_q;
logic [BITW-1:0]        s1_buf_q   [NUM_LANES];
logic [4:0]             s1_e16_max_q;

// S2 — shared scale computed from S1's e16_max
logic                   s2_v_q;
logic [BITW-1:0]        s2_buf_q   [NUM_LANES];
logic [7:0]             s2_scale_q;

// S3 — per-lane exponent + special-case computed from S2
logic                   s3_v_q;
logic [7:0]             s3_scale_q;
logic                   s3_sign_q      [NUM_LANES];
logic [9:0]             s3_mant_q      [NUM_LANES];
logic [2:0]             s3_special_q   [NUM_LANES];
logic signed [5:0]      s3_e8_biased_q [NUM_LANES];

// S4 — packed MX block + scale (drives outputs)
logic                   s4_v_q;
logic [DATA_W-1:0]      s4_val_q;
logic [7:0]             s4_scale_q;

// ---------------------------------------------------------------
//  Combinational computation between stages
// ---------------------------------------------------------------

// At S1 input boundary: e16_max from current input lanes
logic [4:0] e16_max_in;
always_comb begin
  e16_max_in = 5'd0;
  for (int l = 0; l < NUM_LANES; l++) begin
    if (e16_lane[l] != 5'b0 && e16_lane[l] != 5'b11111)
      if (e16_lane[l] > e16_max_in)
        e16_max_in = e16_lane[l];
  end
end

// At S1→S2 boundary: shared exp from registered S1 max
logic [7:0] s2_scale_next;
assign s2_scale_next = compute_shared_exp(s1_e16_max_q, mx_format_i);

// At S2→S3 boundary: per-lane exponent + special-case from registered S2 buf and scale
logic [2:0]             s3_special_next   [NUM_LANES];
logic signed [5:0]      s3_e8_biased_next [NUM_LANES];
logic                   s3_sign_next      [NUM_LANES];
logic [9:0]             s3_mant_next      [NUM_LANES];

always_comb begin
  for (int l = 0; l < NUM_LANES; l++) begin
    logic [BITW-1:0] fp16_val;
    logic        s_bit;
    logic [4:0]  e16;
    logic [9:0]  m16;
    int signed   delta, e8_unbiased, e8_biased_tmp;
    int signed   fp8_bias, max_unbiased;

    fp16_val = s2_buf_q[l];
    s_bit = fp16_val[15];
    e16   = fp16_val[14:10];
    m16   = fp16_val[9:0];

    case (mx_format_i)
      MX_FMT_E5M2: begin fp8_bias = BIAS_FP8_E5M2; max_unbiased = 15; end
      MX_FMT_E3M2: begin fp8_bias = 3;             max_unbiased = 3;  end
      MX_FMT_E2M3: begin fp8_bias = 1;             max_unbiased = 2;  end
      MX_FMT_E2M1: begin fp8_bias = 1;             max_unbiased = 2;  end
      default:      begin fp8_bias = BIAS_FP8_E4M3; max_unbiased = 7;  end
    endcase

    delta         = int'(s2_scale_q) - 127;
    e8_unbiased   = int'(e16) - BIAS_FP16 - delta;
    e8_biased_tmp = e8_unbiased + fp8_bias;

    s3_sign_next[l] = s_bit;
    s3_mant_next[l] = m16;

    if (e16 == 5'b0) begin
      s3_special_next[l]   = 3'd1;
      s3_e8_biased_next[l] = '0;
    end else if (e16 == 5'b11111) begin
      s3_special_next[l]   = (m16 == 0) ? 3'd2 : 3'd3;
      s3_e8_biased_next[l] = '0;
    end else if (e8_unbiased < -fp8_bias) begin
      s3_special_next[l]   = 3'd4;
      s3_e8_biased_next[l] = '0;
    end else if (e8_unbiased > max_unbiased) begin
      s3_special_next[l]   = 3'd5;
      s3_e8_biased_next[l] = '0;
    end else if (e8_biased_tmp <= 0) begin
      s3_special_next[l]   = 3'd4;
      s3_e8_biased_next[l] = '0;
    end else begin
      s3_special_next[l]   = 3'd0;
      s3_e8_biased_next[l] = 6'(e8_biased_tmp);
    end
  end
end

// At S3→S4 boundary: format-specific mantissa pack from registered S3
logic [DATA_W-1:0] s4_val_next;
always_comb begin
  s4_val_next = '0;
  for (int l = 0; l < NUM_LANES; l++) begin
    logic [ELEM_WIDTH-1:0] fp8_val;
    case (s3_special_q[l])
      3'd1:    fp8_val = {s3_sign_q[l], 7'b0};
      3'd2:    fp8_val = mx_inf(s3_sign_q[l], mx_format_i);
      3'd3:    fp8_val = mx_nan(s3_sign_q[l], mx_format_i);
      3'd4:    fp8_val = {s3_sign_q[l], 7'b0};
      3'd5:    fp8_val = mx_max_finite(s3_sign_q[l], mx_format_i);
      default: fp8_val = mx_normal_pack(s3_sign_q[l], s3_e8_biased_q[l], s3_mant_q[l], mx_format_i);
    endcase
    s4_val_next[ELEM_WIDTH*l +: ELEM_WIDTH] = fp8_val;
  end
end

// ---------------------------------------------------------------
//  Pipeline ready/valid (skid-buffer style)
//
//  Stage N is "ready" to accept new data this cycle iff it's empty (v_q=0)
//  or its data is being consumed by stage N+1 this cycle (advance_{N+1}).
//  An advance happens on (v_q[N] && ready[N+1]).
// ---------------------------------------------------------------

logic out_handshake;
assign out_handshake = mx_val_valid_o && mx_val_ready_i && mx_exp_ready_i;

logic s4_ready, s3_ready, s2_ready, s1_ready;
assign s4_ready = !s4_v_q || out_handshake;
assign s3_ready = !s3_v_q || s4_ready;
assign s2_ready = !s2_v_q || s3_ready;
assign s1_ready = !s1_v_q || s2_ready;

assign fp16_ready_o = s1_ready;

logic s1_load, s2_advance, s3_advance, s4_advance;
assign s1_load    = fp16_valid_i && fp16_ready_o;
assign s2_advance = s1_v_q && s2_ready;
assign s3_advance = s2_v_q && s3_ready;
assign s4_advance = s3_v_q && s4_ready;

// ---------------------------------------------------------------
//  Sequential pipeline registers
// ---------------------------------------------------------------

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    s1_v_q <= 1'b0;
    s2_v_q <= 1'b0;
    s3_v_q <= 1'b0;
    s4_v_q <= 1'b0;
    s1_e16_max_q <= 5'd0;
    s2_scale_q   <= 8'd0;
    s3_scale_q   <= 8'd0;
    s4_scale_q   <= 8'd0;
    s4_val_q     <= '0;
    for (int i = 0; i < NUM_LANES; i++) begin
      s1_buf_q[i]       <= '0;
      s2_buf_q[i]       <= '0;
      s3_sign_q[i]      <= 1'b0;
      s3_mant_q[i]      <= '0;
      s3_special_q[i]   <= '0;
      s3_e8_biased_q[i] <= '0;
    end
  end else begin
    // S1: load on input handshake, clear when consumed by S2
    if (s1_load) begin
      s1_v_q <= 1'b1;
      for (int l = 0; l < NUM_LANES; l++) s1_buf_q[l] <= fp16_lane[l];
      s1_e16_max_q <= e16_max_in;
    end else if (s2_advance) begin
      s1_v_q <= 1'b0;
    end

    // S2: load when S1 advances, clear when consumed by S3
    if (s2_advance) begin
      s2_v_q <= 1'b1;
      for (int l = 0; l < NUM_LANES; l++) s2_buf_q[l] <= s1_buf_q[l];
      s2_scale_q <= s2_scale_next;
    end else if (s3_advance) begin
      s2_v_q <= 1'b0;
    end

    // S3: load when S2 advances, clear when consumed by S4
    if (s3_advance) begin
      s3_v_q <= 1'b1;
      s3_scale_q <= s2_scale_q;
      for (int l = 0; l < NUM_LANES; l++) begin
        s3_sign_q[l]      <= s3_sign_next[l];
        s3_mant_q[l]      <= s3_mant_next[l];
        s3_special_q[l]   <= s3_special_next[l];
        s3_e8_biased_q[l] <= s3_e8_biased_next[l];
      end
    end else if (s4_advance) begin
      s3_v_q <= 1'b0;
    end

    // S4: load when S3 advances, clear when output handshake completes
    if (s4_advance) begin
      s4_v_q <= 1'b1;
      s4_val_q   <= s4_val_next;
      s4_scale_q <= s3_scale_q;
    end else if (out_handshake) begin
      s4_v_q <= 1'b0;
    end
  end
end

// ---------------------------------------------------------------
//  Outputs
// ---------------------------------------------------------------
assign mx_val_valid_o = s4_v_q;
assign mx_val_data_o  = s4_val_q;
assign mx_exp_valid_o = s4_v_q;
assign mx_exp_data_o  = s4_scale_q;

endmodule : redmule_mx_encoder
