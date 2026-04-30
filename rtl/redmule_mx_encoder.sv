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

// State machine — SCAN pipelined (tree_max registered) + ENCODE split into two
// pipeline stages + registered OUTPUT. The SCAN_DRAIN state absorbs the
// last tree_max_q comparison after the final SCAN input cycle, breaking
// the deep combinational path from block_data_q → tree_max → e16_max_q
// (post-route ~95 levels of logic, −1.0 ns WNS without this register).
typedef enum logic [2:0] {
    IDLE,
    SCAN,
    SCAN_DRAIN,   // Absorb last registered tree_max_q into e16_max_q
    ENCODE_EXP,   // Stage 1: exponent computation + special case detection
    ENCODE_MANT,  // Stage 2: mantissa rounding + packing (format-aware)
    OUTPUT        // Registered handoff to consumer
} redmule_mx_encode_state_e;

redmule_mx_encode_state_e current_state, next_state;

logic [$clog2(NUM_GROUPS)-1:0] group_idx_q, group_idx_d;
logic [4:0]  e16_max_q, e16_max_d;
logic [7:0]  scale_reg_q, scale_reg_d;
logic [BITW-1:0]        fp16_buf_q [NUM_ELEMS];
logic [BITW-1:0]        fp16_buf_d [NUM_ELEMS];
logic [DATA_W-1:0]      val_reg_q, val_reg_d;

// Pipeline stage 1 intermediates (per lane)
// s1_e8_biased is wide enough to hold E5M2's 5-bit exp with room for carry
logic signed [5:0]      s1_e8_biased_q [NUM_LANES];
logic signed [5:0]      s1_e8_biased_d [NUM_LANES];
logic                   s1_sign_q      [NUM_LANES];
logic                   s1_sign_d      [NUM_LANES];
logic [9:0]             s1_mant_q      [NUM_LANES];
logic [9:0]             s1_mant_d      [NUM_LANES];
// Special case: 0=normal, 1=zero, 2=inf, 3=nan, 4=underflow, 5=overflow
logic [2:0]             s1_special_q   [NUM_LANES];
logic [2:0]             s1_special_d   [NUM_LANES];

// per lane FP16 views
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
//  Helper functions
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
            2'b00, 2'b01: rne_round_up = 1'b0;
            2'b10:        rne_round_up = lsb;
            2'b11:        rne_round_up = 1'b1;
            default:      rne_round_up = 1'b0;
        endcase
    end
endfunction

// Format-specific max-finite encoding (used for overflow saturation + Inf/NaN on no-Inf formats)
function automatic logic [ELEM_WIDTH-1:0] mx_max_finite(input logic s, input mx_format_e fmt);
  case (fmt)
    MX_FMT_E5M2: return {s, 5'b11110, 2'b11};       // max finite E5M2
    MX_FMT_E3M2: return {2'b0, s, 3'b110, 2'b11};   // max finite E3M2
    MX_FMT_E2M3: return {2'b0, s, 2'b11, 3'b111};   // max finite E2M3
    MX_FMT_E2M1: return {4'b0, s, 2'b11, 1'b1};     // max finite E2M1
    default:      return {s, 4'hE, 3'b111};           // max finite E4M3
  endcase
endfunction

// Format-specific Inf encoding. For no-Inf formats (E2M3, E2M1) we saturate to max finite.
function automatic logic [ELEM_WIDTH-1:0] mx_inf(input logic s, input mx_format_e fmt);
  case (fmt)
    MX_FMT_E5M2: return {s, 5'b11111, 2'b00};       // Inf E5M2
    MX_FMT_E3M2: return {2'b0, s, 3'b111, 2'b00};   // Inf E3M2
    MX_FMT_E2M3: return {2'b0, s, 2'b11, 3'b111};   // no Inf → max finite
    MX_FMT_E2M1: return {4'b0, s, 2'b11, 1'b1};     // no Inf → max finite
    default:      return {s, 4'hF, 3'b000};           // Inf E4M3
  endcase
endfunction

// Format-specific NaN encoding. For no-Inf formats we saturate to max finite.
function automatic logic [ELEM_WIDTH-1:0] mx_nan(input logic s, input mx_format_e fmt);
  case (fmt)
    MX_FMT_E5M2: return {s, 5'b11111, 2'b01};
    MX_FMT_E3M2: return {2'b0, s, 3'b111, 2'b01};
    MX_FMT_E2M3: return {2'b0, s, 2'b11, 3'b111};
    MX_FMT_E2M1: return {4'b0, s, 2'b11, 1'b1};
    default:      return {s, 4'hF, 3'b001};
  endcase
endfunction

// Format-specific normal-case mantissa round + pack.
// e8_biased is the pre-round biased exponent (sufficient bits for all formats).
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
          logic [4:0] e_out;
          logic [1:0] m_trunc, m_round;
          logic carry;
          e_out = e8_biased[4:0];
          m_trunc = m16[9:8];
          rbit = m16[7];
          sbit = |m16[6:0];
          round_up = rne_round_up(m_trunc[0], rbit, sbit);
          {carry, m_round} = {1'b0, m_trunc} + round_up;
          if (carry) begin
            if (e_out >= 5'b11110) begin
              e_out = 5'b11110;
              m_round = 2'b11;
            end else begin
              e_out = e_out + 5'd1;
            end
          end
          return {s, e_out, m_round};
        end
        MX_FMT_E3M2: begin
          logic [2:0] e_out;
          logic [1:0] m_trunc, m_round;
          logic carry;
          e_out = e8_biased[2:0];
          m_trunc = m16[9:8];
          rbit = m16[7];
          sbit = |m16[6:0];
          round_up = rne_round_up(m_trunc[0], rbit, sbit);
          {carry, m_round} = {1'b0, m_trunc} + round_up;
          if (carry) begin
            if (e_out >= 3'b110) begin
              e_out = 3'b110;
              m_round = 2'b11;
            end else begin
              e_out = e_out + 3'd1;
            end
          end
          return {2'b0, s, e_out, m_round};
        end
        MX_FMT_E2M3: begin
          logic [1:0] e_out;
          logic [2:0] m_trunc, m_round;
          logic carry;
          e_out = e8_biased[1:0];
          m_trunc = m16[9:7];
          rbit = m16[6];
          sbit = |m16[5:0];
          round_up = rne_round_up(m_trunc[0], rbit, sbit);
          {carry, m_round} = {1'b0, m_trunc} + round_up;
          if (carry) begin
            if (e_out >= 2'b11) begin
              e_out = 2'b11;
              m_round = 3'b111;
            end else begin
              e_out = e_out + 2'd1;
            end
          end
          return {2'b0, s, e_out, m_round};
        end
        MX_FMT_E2M1: begin
          logic [1:0] e_out;
          logic       m_trunc, m_round;
          logic carry;
          e_out = e8_biased[1:0];
          m_trunc = m16[9];
          rbit = m16[8];
          sbit = |m16[7:0];
          round_up = rne_round_up(m_trunc, rbit, sbit);
          {carry, m_round} = {1'b0, m_trunc} + round_up;
          if (carry) begin
            if (e_out >= 2'b11) begin
              e_out = 2'b11;
              m_round = 1'b1;
            end else begin
              e_out = e_out + 2'd1;
            end
          end
          return {4'b0, s, e_out, m_round};
        end
        default: begin  // E4M3
          logic [3:0] e_out;
          logic [2:0] m_trunc, m_round;
          logic carry;
          e_out = e8_biased[3:0];
          m_trunc = m16[9:7];
          rbit = m16[6];
          sbit = |m16[5:0];
          round_up = rne_round_up(m_trunc[0], rbit, sbit);
          {carry, m_round} = {1'b0, m_trunc} + round_up;
          if (carry) begin
            if (e_out >= 4'hE) begin
              e_out = 4'hE;
              m_round = 3'b111;
            end else begin
              e_out = e_out + 4'd1;
            end
          end
          return {s, e_out, m_round};
        end
      endcase
    end
endfunction

// ---------------------------------------------------------------
//  Tree-based max exponent across input lanes (log2 depth)
// ---------------------------------------------------------------

logic [4:0] e16_masked [NUM_LANES];
generate
  for (lane = 0; lane < NUM_LANES; lane++) begin : gen_mask
    assign e16_masked[lane] = (e16_lane[lane] != 5'b0 && e16_lane[lane] != 5'b11111)
                              ? e16_lane[lane] : 5'd0;
  end
endgenerate

logic [4:0] tree_max;
logic [4:0] tree_max_q;  // Registered tree_max output — breaks the
                         // combinational path from block_data_q through
                         // the tree into the running-max compare/register.

redmule_tree_max #(
  .WIDTH (5),
  .N     (NUM_LANES)
) i_tree_max (
  .in  (e16_masked),
  .out (tree_max)
);

// ---------------------------------------------------------------
//  Sequential registers
// ---------------------------------------------------------------

always_ff @(posedge clk_i or negedge rst_ni) begin : state_register
  if (!rst_ni) begin
    current_state <= IDLE;
    group_idx_q <= '0;
    e16_max_q <= 5'd0;
    scale_reg_q <= 8'd0;
    val_reg_q <= '0;
    tree_max_q <= 5'd0;
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
    tree_max_q <= tree_max;  // sample tree_max every cycle
    for (int i = 0; i < NUM_ELEMS; i++) fp16_buf_q[i] <= fp16_buf_d[i];
    for (int i = 0; i < NUM_LANES; i++) begin
      s1_e8_biased_q[i] <= s1_e8_biased_d[i];
      s1_sign_q[i]      <= s1_sign_d[i];
      s1_mant_q[i]      <= s1_mant_d[i];
      s1_special_q[i]   <= s1_special_d[i];
    end
  end
end

// ---------------------------------------------------------------
//  Combinational FSM
// ---------------------------------------------------------------

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
        val_reg_d = '0;
        group_idx_d = '0;
        // Reset running max for new block. tree_max for group 0 is sampled
        // into tree_max_q at the end of this cycle and absorbed in SCAN
        // (or SCAN_DRAIN if NUM_GROUPS == 1).
        e16_max_d = 5'd0;
        for (int l = 0; l < NUM_LANES; l++) begin
          fp16_buf_d[l] = fp16_lane[l];
        end
        if (NUM_GROUPS == 1) begin
          // Single group: route via SCAN_DRAIN to absorb the registered
          // tree_max_q (1-cycle latency added vs old direct ENCODE_EXP path).
          group_idx_d = '0;
          next_state = SCAN_DRAIN;
        end else begin
          group_idx_d = 1;
          next_state = SCAN;
        end
      end else begin
        next_state = IDLE;
        group_idx_d = '0;
      end
    end

    SCAN: begin
      fp16_ready_o = 1'b1;
      if (fp16_valid_i) begin
        for (int l = 0; l < NUM_LANES; l++) begin
          int unsigned elem_idx;
          elem_idx = group_idx_q * NUM_LANES + l;
          fp16_buf_d[elem_idx] = fp16_lane[l];
        end
        // tree_max_q holds the previous group's tree_max (registered).
        // The current group's tree_max is sampled at the end of this cycle
        // and absorbed in the next SCAN cycle (or SCAN_DRAIN for the last group).
        e16_max_d = (tree_max_q > e16_max_q) ? tree_max_q : e16_max_q;
        if (group_idx_q == NUM_GROUPS-1) begin
          group_idx_d = '0;
          next_state = SCAN_DRAIN;
        end else begin
          group_idx_d = group_idx_q + 1;
        end
      end
    end

    SCAN_DRAIN: begin
      // Final absorb: combine the last registered tree_max_q with the running
      // max, then compute the shared exponent. No new input consumed.
      fp16_ready_o = 1'b0;
      e16_max_d = (tree_max_q > e16_max_q) ? tree_max_q : e16_max_q;
      scale_reg_d = compute_shared_exp(e16_max_d, mx_format_i);
      next_state = ENCODE_EXP;
    end

    // ---- Stage 1: exponent compute + special case detection ----
    ENCODE_EXP: begin
      fp16_ready_o = 1'b0;
      for (int l = 0; l < NUM_LANES; l++) begin
        int unsigned elem_idx;
        logic [BITW-1:0] fp16_val;
        logic        s;
        logic [4:0]  e16;
        logic [9:0]  m16;
        int signed   delta, e8_unbiased, e8_biased_tmp;
        int signed   fp8_bias, max_unbiased;

        elem_idx = group_idx_q * NUM_LANES + l;
        fp16_val = fp16_buf_q[elem_idx];
        s   = fp16_val[15];
        e16 = fp16_val[14:10];
        m16 = fp16_val[9:0];

        // Format parameters
        case (mx_format_i)
          MX_FMT_E5M2: begin fp8_bias = BIAS_FP8_E5M2; max_unbiased = 15; end
          MX_FMT_E3M2: begin fp8_bias = 3;             max_unbiased = 3;  end
          MX_FMT_E2M3: begin fp8_bias = 1;             max_unbiased = 2;  end
          MX_FMT_E2M1: begin fp8_bias = 1;             max_unbiased = 2;  end
          default:      begin fp8_bias = BIAS_FP8_E4M3; max_unbiased = 7;  end
        endcase

        delta         = int'(scale_reg_q) - 127;
        e8_unbiased   = int'(e16) - BIAS_FP16 - delta;
        e8_biased_tmp = e8_unbiased + fp8_bias;

        s1_sign_d[l] = s;
        s1_mant_d[l] = m16;

        if (e16 == 5'b0) begin
          s1_special_d[l]   = 3'd1; // zero
          s1_e8_biased_d[l] = '0;
        end else if (e16 == 5'b11111) begin
          s1_special_d[l]   = (m16 == 0) ? 3'd2 : 3'd3; // inf or nan
          s1_e8_biased_d[l] = '0;
        end else if (e8_unbiased < -fp8_bias) begin
          s1_special_d[l]   = 3'd4; // underflow
          s1_e8_biased_d[l] = '0;
        end else if (e8_unbiased > max_unbiased) begin
          s1_special_d[l]   = 3'd5; // overflow
          s1_e8_biased_d[l] = '0;
        end else if (e8_biased_tmp <= 0) begin
          s1_special_d[l]   = 3'd4; // subnormal flush → zero
          s1_e8_biased_d[l] = '0;
        end else begin
          s1_special_d[l]   = 3'd0; // normal
          s1_e8_biased_d[l] = 6'(e8_biased_tmp);
        end
      end
      next_state = ENCODE_MANT;
    end

    // ---- Stage 2: format-specific mantissa round + pack ----
    ENCODE_MANT: begin
      fp16_ready_o = 1'b0;
      for (int l = 0; l < NUM_LANES; l++) begin
        int unsigned elem_idx;
        logic [ELEM_WIDTH-1:0] fp8_val;
        logic        s;
        logic [9:0]  m16;
        logic signed [5:0] e8_biased;

        elem_idx  = group_idx_q * NUM_LANES + l;
        s         = s1_sign_q[l];
        m16       = s1_mant_q[l];
        e8_biased = s1_e8_biased_q[l];

        case (s1_special_q[l])
          3'd1:    fp8_val = {s, 7'b0};                        // zero
          3'd2:    fp8_val = mx_inf(s, mx_format_i);           // inf (or max finite on no-Inf formats)
          3'd3:    fp8_val = mx_nan(s, mx_format_i);           // nan (or max finite on no-Inf formats)
          3'd4:    fp8_val = {s, 7'b0};                        // underflow / subnormal → zero
          3'd5:    fp8_val = mx_max_finite(s, mx_format_i);    // overflow saturate
          default: fp8_val = mx_normal_pack(s, e8_biased, m16, mx_format_i); // normal
        endcase
        val_reg_d[ELEM_WIDTH*elem_idx +: ELEM_WIDTH] = fp8_val;
      end

      if (group_idx_q == NUM_GROUPS - 1) begin
        next_state = OUTPUT;
      end else begin
        group_idx_d = group_idx_q + 1;
        next_state  = ENCODE_EXP;
      end
    end

    // ---- Registered output: val_reg_q + scale_reg_q drive the consumer ----
    OUTPUT: begin
      fp16_ready_o   = 1'b0;
      mx_val_valid_o = 1'b1;
      mx_exp_valid_o = 1'b1;
      mx_val_data_o  = val_reg_q;
      mx_exp_data_o  = scale_reg_q;

      if (mx_val_ready_i && mx_exp_ready_i) begin
        next_state  = IDLE;
        group_idx_d = '0;
      end
    end

    default: next_state = IDLE;
  endcase
end

endmodule : redmule_mx_encoder
