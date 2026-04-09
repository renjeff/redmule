module redmule_mx_encoder
#(
    parameter int unsigned DATA_W = 256,
    parameter int unsigned BITW = 16,
    parameter int unsigned NUM_LANES = 8
)(
    input logic                    clk_i,
    input logic                   rst_ni,

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

// block parameters
localparam int unsigned ELEM_WIDTH = 8;
localparam int unsigned NUM_ELEMS = DATA_W / ELEM_WIDTH;
localparam int unsigned NUM_GROUPS = NUM_ELEMS / NUM_LANES;

localparam int BIAS_FP8_E4M3 = 7;
localparam int BIAS_FP16 = 15;

// State machine — ENCODE split into two pipeline stages
typedef enum logic [2:0] {
    IDLE,
    SCAN,
    ENCODE_EXP,   // Stage 1: exponent computation + special case detection
    ENCODE_MANT   // Stage 2: mantissa rounding + packing
} redmule_mx_encode_state_e;

redmule_mx_encode_state_e current_state, next_state;

logic [$clog2(NUM_GROUPS)-1:0] group_idx_q, group_idx_d;
logic [4:0]  e16_max_q, e16_max_d;
logic [7:0] scale_reg_q, scale_reg_d;
logic [BITW-1:0]        fp16_buf_q [NUM_ELEMS];
logic [BITW-1:0]        fp16_buf_d [NUM_ELEMS];
logic [DATA_W-1:0]      val_reg_q, val_reg_d;

// Pipeline stage 1 intermediates (per lane)
logic signed [8:0]      s1_e8_biased_q [NUM_LANES];
logic signed [8:0]      s1_e8_biased_d [NUM_LANES];
logic                   s1_sign_q      [NUM_LANES];
logic                   s1_sign_d      [NUM_LANES];
logic [9:0]             s1_mant_q      [NUM_LANES];
logic [9:0]             s1_mant_d      [NUM_LANES];
// 0=normal, 1=zero, 2=inf, 3=nan, 4=underflow, 5=overflow
logic [2:0]             s1_special_q   [NUM_LANES];
logic [2:0]             s1_special_d   [NUM_LANES];

// per lane FP16 views
logic [BITW-1:0]      fp16_lane [NUM_LANES];
logic [4:0]           e16_lane [NUM_LANES];

genvar lane;
generate
  for (lane = 0; lane < NUM_LANES; lane++) begin : gen_lanes
      assign fp16_lane[lane] = fp16_data_i[BITW*lane +: BITW];
      assign e16_lane[lane] = fp16_lane[lane][14:10];
  end
endgenerate

function automatic logic [7:0] compute_shared_exp(input logic [4:0] max_e16);
  int signed eM_unbiased, scale_needed, e8m0;
  begin
    if (max_e16 == 5'd0) begin
      compute_shared_exp = 8'd127;
    end else begin
      eM_unbiased  = int'(max_e16) - BIAS_FP16;
      scale_needed = eM_unbiased - 7; // 7 = max unbiased E4M3 exp
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

// Sequential registers
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    current_state <= IDLE;
    group_idx_q <= '0;
    e16_max_q <= 5'd0;
    scale_reg_q <= 8'd0;
    val_reg_q <= '0;
    for (int i = 0; i < NUM_ELEMS; i++) fp16_buf_q[i] <= '0;
    for (int i = 0; i < NUM_LANES; i++) begin
      s1_e8_biased_q[i] <= '0;
      s1_sign_q[i]      <= '0;
      s1_mant_q[i]      <= '0;
      s1_special_q[i]   <= '0;
    end
  end else begin
    current_state <= next_state;
    group_idx_q <= group_idx_d;
    e16_max_q <= e16_max_d;
    scale_reg_q <= scale_reg_d;
    val_reg_q <= val_reg_d;
    for (int i = 0; i < NUM_ELEMS; i++) fp16_buf_q[i] <= fp16_buf_d[i];
    for (int i = 0; i < NUM_LANES; i++) begin
      s1_e8_biased_q[i] <= s1_e8_biased_d[i];
      s1_sign_q[i]      <= s1_sign_d[i];
      s1_mant_q[i]      <= s1_mant_d[i];
      s1_special_q[i]   <= s1_special_d[i];
    end
  end
end

// Combinational FSM
always_comb begin : fsm
    next_state  = current_state;
    group_idx_d = group_idx_q;
    e16_max_d   = e16_max_q;
    scale_reg_d = scale_reg_q;
    val_reg_d   = val_reg_q;

    for (int i = 0; i < NUM_ELEMS; i++) fp16_buf_d[i] = fp16_buf_q[i];
    for (int i = 0; i < NUM_LANES; i++) begin
      s1_e8_biased_d[i] = s1_e8_biased_q[i];
      s1_sign_d[i]      = s1_sign_q[i];
      s1_mant_d[i]      = s1_mant_q[i];
      s1_special_d[i]   = s1_special_q[i];
    end

    fp16_ready_o   = 1'b0;
    mx_val_valid_o = 1'b0;
    mx_val_data_o  = val_reg_q;
    mx_exp_valid_o = 1'b0;
    mx_exp_data_o  = scale_reg_q;

    unique case (current_state)
      IDLE: begin
        fp16_ready_o = 1'b1;
        if (fp16_valid_i) begin
          e16_max_d = 5'd0;
          val_reg_d = '0;
          group_idx_d = '0;
          for (int l = 0; l < NUM_LANES; l++) begin
            fp16_buf_d[l] = fp16_lane[l];
            if (e16_lane[l] != 5'b0 && e16_lane[l] != 5'b11111)
              if (e16_lane[l] > e16_max_d)
                e16_max_d = e16_lane[l];
          end
          if (NUM_GROUPS == 1) begin
            scale_reg_d = compute_shared_exp(e16_max_d);
            group_idx_d = '0;
            next_state = ENCODE_EXP;
          end else begin
            group_idx_d = 1;
            next_state = SCAN;
          end
        end
      end

      SCAN: begin
        fp16_ready_o = 1'b1;
        if (fp16_valid_i) begin
          for (int l = 0; l < NUM_LANES; l++) begin
            int unsigned elem_idx;
            elem_idx = group_idx_q * NUM_LANES + l;
            fp16_buf_d[elem_idx] = fp16_lane[l];
            if (e16_lane[l] != 5'b0 && e16_lane[l] != 5'b11111)
              if (e16_lane[l] > e16_max_d)
                e16_max_d = e16_lane[l];
          end
          if (group_idx_q == NUM_GROUPS-1) begin
            scale_reg_d = compute_shared_exp(e16_max_d);
            group_idx_d = '0;
            next_state = ENCODE_EXP;
          end else begin
            group_idx_d = group_idx_q + 1;
          end
        end
      end

      // ---- Pipeline Stage 1: exponent + special case detection ----
      ENCODE_EXP: begin
        fp16_ready_o = 1'b0;
        for (int l = 0; l < NUM_LANES; l++) begin
          int unsigned elem_idx;
          logic [BITW-1:0] fp16_val;
          logic        s;
          logic [4:0]  e16;
          logic [9:0]  m16;
          int signed   delta, e8_unbiased;

          elem_idx = group_idx_q * NUM_LANES + l;
          fp16_val = fp16_buf_q[elem_idx];
          s   = fp16_val[15];
          e16 = fp16_val[14:10];
          m16 = fp16_val[9:0];

          delta = int'(scale_reg_q) - 127;
          e8_unbiased = int'(e16) - BIAS_FP16 - delta;

          s1_sign_d[l] = s;
          s1_mant_d[l] = m16;

          if (e16 == 5'b0) begin
            s1_special_d[l]   = 3'd1; // zero
            s1_e8_biased_d[l] = '0;
          end else if (e16 == 5'b11111) begin
            s1_special_d[l]   = (m16 == 0) ? 3'd2 : 3'd3; // inf or nan
            s1_e8_biased_d[l] = '0;
          end else if (e8_unbiased < -BIAS_FP8_E4M3) begin
            s1_special_d[l]   = 3'd4; // underflow
            s1_e8_biased_d[l] = '0;
          end else if (e8_unbiased > 7) begin
            s1_special_d[l]   = 3'd5; // overflow
            s1_e8_biased_d[l] = '0;
          end else if ((e8_unbiased + BIAS_FP8_E4M3) <= 0) begin
            s1_special_d[l]   = 3'd4; // subnormal flush
            s1_e8_biased_d[l] = '0;
          end else begin
            s1_special_d[l]   = 3'd0; // normal
            s1_e8_biased_d[l] = 9'(e8_unbiased + BIAS_FP8_E4M3);
          end
        end
        next_state = ENCODE_MANT;
      end

      // ---- Pipeline Stage 2: mantissa rounding + packing ----
      ENCODE_MANT: begin
        fp16_ready_o = 1'b0;
        for (int l = 0; l < NUM_LANES; l++) begin
          int unsigned elem_idx;
          logic [ELEM_WIDTH-1:0] fp8_val;
          logic        s;
          logic [9:0]  m16;
          logic [3:0]  e4;
          logic [2:0]  m3t, m3r;
          logic rbit, sbit, round_up, c3;

          elem_idx = group_idx_q * NUM_LANES + l;
          s   = s1_sign_q[l];
          m16 = s1_mant_q[l];

          case (s1_special_q[l])
            3'd1: fp8_val = {s, 7'b0};              // zero
            3'd2: fp8_val = {s, 4'hF, 3'b000};      // inf
            3'd3: fp8_val = {s, 4'hF, 3'b001};      // nan
            3'd4: fp8_val = {s, 7'b0};              // underflow
            3'd5: fp8_val = {s, 4'hE, 3'b111};      // overflow saturate
            default: begin // normal: E4M3 mantissa rounding
              e4 = s1_e8_biased_q[l][3:0];
              m3t = m16[9:7];
              rbit = m16[6];
              sbit = |m16[5:0];
              round_up = rne_round_up(m3t[0], rbit, sbit);
              {c3, m3r} = {1'b0, m3t} + round_up;
              if (c3) begin
                if (e4 >= 4'hE) begin e4 = 4'hE; m3r = 3'b111; end
                else e4 = e4 + 4'd1;
              end
              fp8_val = {s, e4, m3r};
            end
          endcase
          val_reg_d[ELEM_WIDTH*elem_idx +: ELEM_WIDTH] = fp8_val;
        end

        if (group_idx_q == NUM_GROUPS - 1) begin
          mx_val_valid_o = 1'b1;
          mx_exp_valid_o = 1'b1;
          mx_val_data_o  = val_reg_d;
          if (mx_val_ready_i && mx_exp_ready_i) begin
            next_state = IDLE;
            group_idx_d = '0;
          end
        end else begin
          group_idx_d = group_idx_q + 1;
          next_state = ENCODE_EXP;
        end
      end

      default: next_state = IDLE;
    endcase
end

endmodule : redmule_mx_encoder
