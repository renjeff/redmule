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

// block parameters
localparam int unsigned ELEM_WIDTH = 8;
localparam int unsigned NUM_ELEMS = DATA_W / ELEM_WIDTH;
localparam int unsigned NUM_GROUPS = NUM_ELEMS / NUM_LANES;

localparam int BIAS_FP8_E4M3 = 7;
localparam int BIAS_FP8_E5M2 = 15;
localparam int BIAS_FP16 = 15;


// // State machine

typedef enum logic [1:0] {
    IDLE,
    SCAN,
    ENCODE,
    OUTPUT    // Registered output: val_reg_q has encoded data, present to consumer
} redmule_mx_encode_state_e;

redmule_mx_encode_state_e current_state, next_state;

// index of current group
logic [$clog2(NUM_GROUPS)-1:0] group_idx_q, group_idx_d;

// // exponent tracking and shared exponent
// running max exp over a block
logic [4:0]  e16_max_q, e16_max_d;

// shared exponent for this block
logic [7:0] scale_reg_q, scale_reg_d;

// // FOR NOW: FP16 buffer
logic [BITW-1:0]        fp16_buf_q [NUM_ELEMS];
logic [BITW-1:0]        fp16_buf_d [NUM_ELEMS];

logic [DATA_W-1:0]      val_reg_q, val_reg_d;

// per lane FP16 views

logic[ BITW-1:0]      fp16_lane [NUM_LANES];
logic [4:0]           e16_lane [NUM_LANES]; //per lane exponent

genvar lane;
generate
  for (lane = 0; lane < NUM_LANES; lane++) begin : gen_lanes
      //slice input for this lane
      assign fp16_lane[lane] = fp16_data_i[BITW*lane +: BITW];
      assign e16_lane[lane] = fp16_lane[lane][14:10]; //exponent bits
  end
endgenerate


// // helper functions

// Compute shared exp (E_shared) from max FP16 exponent
// function automatic logic [7:0] compute_shared_exp(input logic [4:0] max_e16);
//   logic signed [8:0] delta;
//   logic signed [8:0] shared;
//   begin
//     delta = max_e16 - BIAS_FP16 + BIAS_FP8_E4M3;
//     shared = delta + 127; // bias for shared exponent
//     compute_shared_exp = shared[7:0];
//   end
// endfunction
function automatic logic [7:0] compute_shared_exp(input logic [4:0] max_e16, input mx_format_e fmt);
  int signed eM_unbiased;
  int signed scale_needed;
  int signed e8m0;
  int signed max_unbiased_e8;
  begin
    if (max_e16 == 5'd0) begin
      compute_shared_exp = 8'd127;
    end else begin
      // Max unbiased exponent per format:
      // With Inf/NaN: max_finite_biased = 2^e - 2.  Without: 2^e - 1.
      // E4M3: (16-2)-7 = 7.  E5M2: (32-2)-15 = 15.
      // E3M2: (8-2)-3 = 3.   E2M3: (4-1)-1 = 2 (no Inf).  E2M1: (4-1)-1 = 2 (no Inf).
      case (fmt)
        MX_FMT_E5M2:  max_unbiased_e8 = 15;
        MX_FMT_E3M2:  max_unbiased_e8 = 3;
        MX_FMT_E2M3:  max_unbiased_e8 = 2;   // no Inf: max biased=3, unbiased=2
        MX_FMT_E2M1:  max_unbiased_e8 = 2;   // no Inf: max biased=3, unbiased=2
        default:       max_unbiased_e8 = 7;
      endcase

      eM_unbiased  = int'(max_e16) - BIAS_FP16;
      scale_needed = eM_unbiased - max_unbiased_e8;
      e8m0 = scale_needed + 127;

      if (e8m0 < 0)
        compute_shared_exp = 8'd0;
      else if (e8m0 > 255)
        compute_shared_exp = 8'd255;
      else
        compute_shared_exp = e8m0[7:0];
    end
  end
endfunction

function automatic logic rne_round_up(
    input logic lsb,
    input logic round_bit,
    input logic sticky_bit
);
    logic [1:0] rs;
    begin
        rs = {round_bit, sticky_bit};
        unique case (rs)
            2'b00,
            2'b01: rne_round_up = 1'b0; // < ulp/2 away, round down
            2'b10: rne_round_up = lsb; // = ulp/2 away, round towards even result
            2'b11: rne_round_up = 1'b1; // > ulp/2 away, round up
            default: rne_round_up = 1'b0;
        endcase
    end
endfunction


function automatic logic [ELEM_WIDTH-1:0] fp16_to_fp8_e4m3_unscaled(
  input logic [BITW-1:0] val_fp16
);
    logic s;
    logic [4:0] e16;
    logic [9:0] m16;

    logic [3:0] e8;
    logic [2:0] m8_trunc, m8_round;

    logic rbit, sbit;
    logic round_up;
    logic carry;

    int e_unbias;

    begin
        s = val_fp16[15];
        e16 = val_fp16[14:10];
        m16 = val_fp16[9:0];

        //zero
        if (e16 == 5'b0)
            return {s,7'b0};

        //inf/NaN
        if (e16 == 5'b11111) begin
            if(m16 == 0)
                return {s,4'hF,3'b000}; //inf
            else 
                return {s,4'hF,3'b001}; //NaN
        end
        
        //normal: rebias exponent
        e_unbias = e16 - BIAS_FP16 + BIAS_FP8_E4M3;

        if (e_unbias <= 0)
            return {s,4'b0000, 3'b000}; //underflow to zero
        if (e_unbias >= 15)
            return {s,4'hE,3'b111}; // saturate
        
        e8 = e_unbias[3:0];
        m8_trunc = m16[9:7]; // only truncate

        // RNE rounding bits
        rbit = m16[6];
        sbit = | m16[5:0];
        round_up = rne_round_up(m8_trunc[0], rbit, sbit);

        // apply rounding
        {carry, m8_round} = {1'b0, m8_trunc} + round_up;

        if (carry) begin
            // mantissa overflow, increment exp
            if (e8 == 4'hE) begin
                e8 = 4'hE; //saturate
                m8_round = 3'b111;
            end else begin
                e8 = e8 + 4'd1;
                // if it reaches 0xF, clamp back to finite
                if (e8 == 4'hF) begin
                    e8 = 4'hE;
                    m8_round = 3'b111;
                end
            end
        end

        return{s,e8,m8_round};
    end
endfunction
   
// FP16 -> MXFP8 (format-aware, with shared exponent scaling)
function automatic logic [ELEM_WIDTH-1:0] fp16_to_mxfp8(
    input logic [BITW-1:0] val_fp16,
    input logic [7:0] shared_exp,
    input mx_format_e fmt
);
    logic s;
    logic [4:0] e16;
    logic [9:0] m16;

    int signed delta;
    int signed e8_unbiased;
    int signed e8_biased_tmp;
    int signed fp8_bias;
    int signed max_unbiased;
    int        exp_bits;
    int        mant_bits;

    logic rbit, sbit, round_up, carry;

    begin
        s = val_fp16[15];
        e16 = val_fp16[14:10];
        m16 = val_fp16[9:0];

        // Format parameters
        case (fmt)
          MX_FMT_E5M2: begin
            fp8_bias     = BIAS_FP8_E5M2;  // 15
            max_unbiased = 15;              // biased 30 - 15
            exp_bits     = 5;
            mant_bits    = 2;
          end
          MX_FMT_E3M2: begin
            fp8_bias     = 3;
            max_unbiased = 3;               // biased 6 - 3
            exp_bits     = 3;
            mant_bits    = 2;
          end
          MX_FMT_E2M3: begin
            fp8_bias     = 1;
            max_unbiased = 2;               // no Inf: biased 3, unbiased 2
            exp_bits     = 2;
            mant_bits    = 3;
          end
          MX_FMT_E2M1: begin
            fp8_bias     = 1;
            max_unbiased = 2;               // no Inf: biased 3, unbiased 2
            exp_bits     = 2;
            mant_bits    = 1;
          end
          default: begin  // E4M3
            fp8_bias     = BIAS_FP8_E4M3;  // 7
            max_unbiased = 7;               // biased 14 - 7
            exp_bits     = 4;
            mant_bits    = 3;
          end
        endcase

        // Zero
        if (e16 == 5'b0)
            return {s, 7'b0};

        // Inf/NaN
        if (e16 == 5'b11111) begin
            case (fmt)
              MX_FMT_E5M2: begin
                if (m16 == 0)
                  return {s, 5'b11111, 2'b00}; // inf
                else
                  return {s, 5'b11111, 2'b01}; // NaN
              end
              MX_FMT_E3M2: begin
                if (m16 == 0)
                  return {2'b0, s, 3'b111, 2'b00}; // inf
                else
                  return {2'b0, s, 3'b111, 2'b01}; // NaN
              end
              MX_FMT_E2M3: begin
                // E2M3 has no inf/NaN — saturate to max finite
                return {2'b0, s, 2'b11, 3'b111};
              end
              MX_FMT_E2M1: begin
                // E2M1 has no inf/NaN — saturate to max finite
                return {4'b0, s, 2'b11, 1'b1};
              end
              default: begin  // E4M3
                if (m16 == 0)
                  return {s, 4'hF, 3'b000}; // inf
                else
                  return {s, 4'hF, 3'b001}; // NaN
              end
            endcase
        end

        // Normal: compute FP8 exponent
        delta = int'(shared_exp) - 127;
        e8_unbiased = int'(e16) - BIAS_FP16 - delta;

        // Underflow
        if (e8_unbiased < -fp8_bias)
            return {s, 7'b0};

        // Overflow: saturate to max finite
        if (e8_unbiased > max_unbiased) begin
          case (fmt)
            MX_FMT_E5M2: return {s, 5'b11110, 2'b11};       // max finite E5M2
            MX_FMT_E3M2: return {2'b0, s, 3'b110, 2'b11};   // max finite E3M2
            MX_FMT_E2M3: return {2'b0, s, 2'b11, 3'b111};   // max finite E2M3 (no inf, all-ones is normal)
            MX_FMT_E2M1: return {4'b0, s, 2'b11, 1'b1};     // max finite E2M1
            default:      return {s, 4'hE, 3'b111};           // max finite E4M3
          endcase
        end

        e8_biased_tmp = e8_unbiased + fp8_bias;

        // Subnormal flush
        if (e8_biased_tmp <= 0)
            return {s, 7'b0};

        // Format-dependent mantissa truncation and rounding
        if (fmt == MX_FMT_E3M2) begin
          // E3M2: 3-bit exponent, 2-bit mantissa, stored in low 6 bits
          logic [2:0] e6_3;
          logic [1:0] m6_2_trunc, m6_2_round;
          logic carry_e3m2;

          e6_3 = e8_biased_tmp[2:0];
          m6_2_trunc = m16[9:8];
          rbit = m16[7];
          sbit = |m16[6:0];
          round_up = rne_round_up(m6_2_trunc[0], rbit, sbit);
          {carry_e3m2, m6_2_round} = {1'b0, m6_2_trunc} + round_up;

          if (carry_e3m2) begin
            if (e6_3 >= 3'b110) begin  // max normal exp for E3M2
              e6_3 = 3'b110;
              m6_2_round = 2'b11;
            end else begin
              e6_3 = e6_3 + 3'd1;
            end
          end

          return {2'b0, s, e6_3, m6_2_round};
        end else if (fmt == MX_FMT_E2M3) begin
          // E2M3: 2-bit exponent, 3-bit mantissa, stored in low 6 bits
          logic [1:0] e6_2;
          logic [2:0] m6_3_trunc, m6_3_round;
          logic carry_e2m3;

          e6_2 = e8_biased_tmp[1:0];
          m6_3_trunc = m16[9:7];
          rbit = m16[6];
          sbit = |m16[5:0];
          round_up = rne_round_up(m6_3_trunc[0], rbit, sbit);
          {carry_e2m3, m6_3_round} = {1'b0, m6_3_trunc} + round_up;

          if (carry_e2m3) begin
            if (e6_2 >= 2'b11) begin  // E2M3 has no inf, all-ones is max normal
              e6_2 = 2'b11;
              m6_3_round = 3'b111;
            end else begin
              e6_2 = e6_2 + 2'd1;
            end
          end

          return {2'b0, s, e6_2, m6_3_round};
        end else if (fmt == MX_FMT_E2M1) begin
          // E2M1: 2-bit exponent, 1-bit mantissa, stored in low nibble
          logic [1:0] e4_2;
          logic       m4_1_trunc, m4_1_round;
          logic       carry_1;

          e4_2 = e8_biased_tmp[1:0];
          m4_1_trunc = m16[9];  // top 1 mantissa bit
          rbit = m16[8];
          sbit = |m16[7:0];
          round_up = rne_round_up(m4_1_trunc, rbit, sbit);
          {carry_1, m4_1_round} = {1'b0, m4_1_trunc} + round_up;

          if (carry_1) begin
            if (e4_2 >= 2'b11) begin  // no Inf: max normal exp for E2M1 = 3 (biased)
              e4_2 = 2'b11;
              m4_1_round = 1'b1;
            end else begin
              e4_2 = e4_2 + 2'd1;
            end
          end

          // Pack into 8-bit container: {4'b0, S, EE, M}
          return {4'b0, s, e4_2, m4_1_round};
        end else if (fmt == MX_FMT_E5M2) begin
          logic [4:0] e8_5;
          logic [1:0] m8_2_trunc, m8_2_round;
          logic carry_2;

          e8_5 = e8_biased_tmp[4:0];
          m8_2_trunc = m16[9:8];  // top 2 mantissa bits
          rbit = m16[7];
          sbit = |m16[6:0];
          round_up = rne_round_up(m8_2_trunc[0], rbit, sbit);
          {carry_2, m8_2_round} = {1'b0, m8_2_trunc} + round_up;

          if (carry_2) begin
            if (e8_5 >= 5'b11110) begin
              e8_5 = 5'b11110;
              m8_2_round = 2'b11;
            end else begin
              e8_5 = e8_5 + 5'd1;
            end
          end

          return {s, e8_5, m8_2_round};
        end else begin
          logic [3:0] e8_4;
          logic [2:0] m8_3_trunc, m8_3_round;
          logic carry_3;

          e8_4 = e8_biased_tmp[3:0];
          m8_3_trunc = m16[9:7];  // top 3 mantissa bits
          rbit = m16[6];
          sbit = |m16[5:0];
          round_up = rne_round_up(m8_3_trunc[0], rbit, sbit);
          {carry_3, m8_3_round} = {1'b0, m8_3_trunc} + round_up;

          if (carry_3) begin
            if (e8_4 >= 4'hE) begin
              e8_4 = 4'hE;
              m8_3_round = 3'b111;
            end else begin
              e8_4 = e8_4 + 4'd1;
            end
          end

          return {s, e8_4, m8_3_round};
        end
    end
endfunction

// // sequential part

always_ff @(posedge clk_i or negedge rst_ni) begin : state_register
  if (!rst_ni) begin
        current_state <= IDLE;
        group_idx_q <= '0;
        e16_max_q <= 5'd0;
        scale_reg_q <= 8'd0;
        val_reg_q <= '0;

        for ( int i= 0; i < NUM_ELEMS; i++) begin
            fp16_buf_q[i] <= '0;
        end
    end else begin
        current_state <= next_state;
        group_idx_q <= group_idx_d;
        e16_max_q <= e16_max_d;
        scale_reg_q <= scale_reg_d;
        val_reg_q <= val_reg_d;

        for ( int i= 0; i < NUM_ELEMS; i++) begin
            fp16_buf_q[i] <= fp16_buf_d[i];
        end
    end
end

// // combinational FSM
    always_comb begin : fsm
        next_state = current_state;
        group_idx_d = group_idx_q;
        e16_max_d = e16_max_q;
        scale_reg_d = scale_reg_q;
        val_reg_d = val_reg_q;

        for (int i = 0; i < NUM_ELEMS; i++) begin
            fp16_buf_d[i] = fp16_buf_q[i];
        end

        fp16_ready_o   = 1'b0;
        mx_val_valid_o = 1'b0;
        mx_val_data_o  = val_reg_q;
        mx_exp_valid_o = 1'b0;
        mx_exp_data_o  = scale_reg_q;

        unique case (current_state)
            IDLE: begin
                fp16_ready_o = 1'b1;

                // start new block when first FP16 group arrives
                if (fp16_valid_i) begin
                    // next_state = SCAN;
                    e16_max_d = 5'd0;
                    val_reg_d = '0;
                    group_idx_d = '0;

                // SCAN first group immediatly (otherwise we loose it)
                    for (int l = 0; l < NUM_LANES; l++) begin
                        int unsigned elem_idx;
                        elem_idx = l;
                        fp16_buf_d[elem_idx] = fp16_lane[l];

                        // update running max exp
                        if (e16_lane[l] != 5'b0 && e16_lane[l] != 5'b11111) begin
                            if (e16_lane[l] > e16_max_d) begin
                                e16_max_d = e16_lane[l];
                            end
                        end
                    end

                    if (NUM_GROUPS == 1) begin
                        // block fits in the single group
                        scale_reg_d = compute_shared_exp(e16_max_d, mx_format_i);
                        group_idx_d = '0;
                        next_state = ENCODE;
                    end else begin
                        // more groups incoming
                        group_idx_d = 1;
                        next_state = SCAN;
                    end
                end else begin
                    next_state  = IDLE;
                    group_idx_d = '0;
                end
            end

 
            SCAN: begin
                fp16_ready_o = 1'b1;

                if (fp16_valid_i) begin
                    for (int l = 0; l < NUM_LANES; l++ ) begin
                        int unsigned elem_idx;
                        elem_idx= group_idx_q * NUM_LANES + l;
                        fp16_buf_d[elem_idx] = fp16_lane[l];
                        // DEBUG: show what we store
                        // $display("[%0t] SCAN: group=%0d lane=%0d elem_idx=%0d fp16_in=0x%04h e16=%0d e16_max_d=%0d",
                        //         $time, group_idx_q, l, elem_idx, fp16_lane[l],
                        //         e16_lane[l], e16_max_d);

                        if (e16_lane[l] != 5'b0 && e16_lane[l] != 5'b11111) begin
                            if (e16_lane[l] > e16_max_d) begin
                                e16_max_d = e16_lane[l];
                            end
                        end
                    end

                    if (group_idx_q == NUM_GROUPS-1) begin
                        // finished with whole block
                        scale_reg_d = compute_shared_exp(e16_max_d, mx_format_i);
                        group_idx_d = '0;
                        next_state = ENCODE;
                        
                        // DEBUG: dump buffer contents
                        // $display("[%0t] BUF DUMP before ENCODE:", $time);
                        // for (int i = 0; i < NUM_ELEMS; i++) begin
                        //     $display("  buf[%0d] = 0x%04h", i, fp16_buf_d[i]);
                        // end
                    end else begin
                        group_idx_d = group_idx_q + 1;
                    end
                end else begin
                    next_state = SCAN;
                end
            end

            ENCODE: begin
                // no more inputs in this phase
                fp16_ready_o = 1'b0;

                // encode current group from fp16_buf into val_reg_d
                for ( int l = 0; l < NUM_LANES; l++) begin
                    int unsigned elem_idx;
                    logic[BITW-1:0] fp16_val;
                    logic[ELEM_WIDTH-1:0] fp8_val;

                    elem_idx = group_idx_q * NUM_LANES + l;
                    fp16_val = fp16_buf_q[elem_idx];
                    fp8_val = fp16_to_mxfp8(fp16_val, scale_reg_q, mx_format_i);

                    val_reg_d[ELEM_WIDTH*elem_idx +: ELEM_WIDTH] = fp8_val;
                    // // DEBUG: show encode step
                    // $display("[%0t] ENCODE: group=%0d lane=%0d elem_idx=%0d fp16_val=0x%04h shared=0x%02h fp8_val=0x%02h",
                    //     $time, group_idx_q, l, elem_idx, fp16_val, scale_reg_q, fp8_val);
                end
                // once at last group, transition to OUTPUT (registered output)
                if (group_idx_q == NUM_GROUPS -1) begin
                    next_state = OUTPUT;
                end else begin
                    group_idx_d = group_idx_q + 1;
                end
            end

            // Registered output state: val_reg_q now holds encoded data
            OUTPUT: begin
                fp16_ready_o   = 1'b0;
                mx_val_valid_o = 1'b1;
                mx_exp_valid_o = 1'b1;
                mx_val_data_o  = val_reg_q;  // registered, not combinational
                mx_exp_data_o  = scale_reg_q;

                if (mx_val_ready_i && mx_exp_ready_i) begin
                    next_state = IDLE;
                    group_idx_d = '0;
                end
            end

            default: begin
                next_state = IDLE;
            end

        endcase
    end


endmodule : redmule_mx_encoder
