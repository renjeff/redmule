// MX decoder shared between the X (single shared exponent) and W (per-group
// shared exponent) data paths.  Pipelined version: 2 internal stages for
// 1-block-per-cycle sustained throughput (NUM_GROUPS must be 1).
//
//   Stage 0 (S0): Latch input, combinationally convert FP8 → FP16 (unscaled).
//   Stage 1 (S1): Combinationally apply MX scale, register final FP16 output.
//
// An opaque tag is pipelined alongside the data so the arbiter target
// information arrives at the output aligned with the decoded values.

module redmule_mx_decoder
  import redmule_pkg::*;
#(
  parameter int unsigned DATA_W = 256,
  parameter int unsigned BITW = 16,
  parameter int unsigned NUM_LANES = 1,
  parameter int unsigned MX_EXP_WIDTH = ((DATA_W / 8) / NUM_LANES) * 8,
  parameter int unsigned TAG_WIDTH = 2
)(
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  mx_format_e              mx_format_i,

  input  logic                    mx_val_valid_i,
  output logic                    mx_val_ready_o,
  input  logic [DATA_W-1:0]       mx_val_data_i,

  input  logic                    mx_exp_valid_i,
  output logic                    mx_exp_ready_o,
  input  logic [MX_EXP_WIDTH-1:0] mx_exp_data_i,
  input  logic                    vector_shared_exp_i,

  // Opaque tag pipelined with data (e.g. arbiter target: X / W)
  input  logic [TAG_WIDTH-1:0]    tag_i,
  output logic [TAG_WIDTH-1:0]    tag_o,

  output logic                    fp16_valid_o,
  input  logic                    fp16_ready_i,
  output logic [NUM_LANES*BITW-1:0] fp16_data_o
);

  localparam int unsigned ELEM_WIDTH  = 8;
  localparam int unsigned NUM_ELEMS   = DATA_W / ELEM_WIDTH;
  localparam int unsigned NUM_GROUPS  = NUM_ELEMS / NUM_LANES;

  initial begin
    if (NUM_LANES == 0)
      $fatal(1, "MX decoder: NUM_LANES must be > 0");
    if (NUM_ELEMS % NUM_LANES != 0)
      $fatal(1, "MX decoder: NUM_ELEMS (%0d) must be divisible by NUM_LANES (%0d)",
             NUM_ELEMS, NUM_LANES);
    if (NUM_GROUPS != 1)
      $fatal(1, "Pipelined MX decoder requires NUM_GROUPS == 1 (got %0d)", NUM_GROUPS);
  end

  // ---------------------------------------------------------------
  //  Conversion functions
  // ---------------------------------------------------------------

  localparam int BIAS_FP16 = 15;

  // E4M3: 1 sign + 4 exp + 3 mantissa, bias = 7
  function automatic logic [15:0] fp8_e4m3_to_fp16 (input logic [7:0] in);
    logic       s;
    logic [3:0] e8;
    logic [2:0] m8;
    logic [4:0] e16;
    logic [9:0] m16;
    int         e16_int;
    begin
      s  = in[7];
      e8 = in[6:3];
      m8 = in[2:0];

      if (e8 == 4'b0000) begin
        fp8_e4m3_to_fp16 = {s,5'b0,10'b0};
      end else if (e8 == 4'b1111) begin
        if (m8 == 3'b000) begin
          fp8_e4m3_to_fp16 = {s,5'b11111,10'b0};
        end else begin
          fp8_e4m3_to_fp16 = {s,5'b11111,10'b1000000000};
        end
      end else begin
        e16_int = int'(e8) - 7 + BIAS_FP16;
        e16     = e16_int[4:0];
        m16     = {m8,7'b0};
        fp8_e4m3_to_fp16 = {s, e16, m16};
      end
    end
  endfunction

  // E5M2: 1 sign + 5 exp + 2 mantissa, bias = 15
  function automatic logic [15:0] fp8_e5m2_to_fp16 (input logic [7:0] in);
    logic       s;
    logic [4:0] e8;
    logic [1:0] m8;
    logic [4:0] e16;
    logic [9:0] m16;
    int         e16_int;
    begin
      s  = in[7];
      e8 = in[6:2];
      m8 = in[1:0];

      if (e8 == 5'b00000) begin
        fp8_e5m2_to_fp16 = {s,5'b0,10'b0};
      end else if (e8 == 5'b11111) begin
        if (m8 == 2'b00) begin
          fp8_e5m2_to_fp16 = {s,5'b11111,10'b0};
        end else begin
          fp8_e5m2_to_fp16 = {s,5'b11111,10'b1000000000};
        end
      end else begin
        // E5M2 bias = 15, same as FP16, so exponent maps directly
        e16_int = int'(e8) - 15 + BIAS_FP16;
        e16     = e16_int[4:0];
        m16     = {m8,8'b0};
        fp8_e5m2_to_fp16 = {s, e16, m16};
      end
    end
  endfunction

  // E2M1: 1 sign + 2 exp + 1 mantissa, bias = 1
  // Stored in low 4 bits of 8-bit container: {4'b0, S, EE, M}
  // OCP MX spec: E2M1 has NO Inf and NO NaN — all exponent values are normal.
  // E=00: zero/subnormal (flush to zero)
  // E=01,10,11: normal values
  function automatic logic [15:0] fp4_e2m1_to_fp16 (input logic [7:0] in);
    logic       s;
    logic [1:0] e4;
    logic       m4;
    logic [4:0] e16;
    logic [9:0] m16;
    int         e16_int;
    begin
      s  = in[3];
      e4 = in[2:1];
      m4 = in[0];

      if (e4 == 2'b00) begin
        // Zero (subnormals flush to zero for MX)
        fp4_e2m1_to_fp16 = {s, 5'b0, 10'b0};
      end else begin
        // Normal (all non-zero exponents, including 11 = max normal)
        e16_int = int'({3'b0, e4}) - 1 + BIAS_FP16;
        e16     = e16_int[4:0];
        m16     = {m4, 9'b0};
        fp4_e2m1_to_fp16 = {s, e16, m16};
      end
    end
  endfunction

  // E3M2: 1 sign + 3 exp + 2 mantissa, bias = 3
  // Stored in low 6 bits of 8-bit container: {2'b0, S, EEE, MM}
  // OCP MX spec: E3M2 has Inf (E=111,M=00) and NaN (E=111,M!=00)
  function automatic logic [15:0] fp6_e3m2_to_fp16 (input logic [7:0] in);
    logic       s;
    logic [2:0] e6;
    logic [1:0] m6;
    logic [4:0] e16;
    logic [9:0] m16;
    int         e16_int;
    begin
      s  = in[5];
      e6 = in[4:2];
      m6 = in[1:0];

      if (e6 == 3'b000) begin
        fp6_e3m2_to_fp16 = {s, 5'b0, 10'b0};
      end else if (e6 == 3'b111) begin
        if (m6 == 2'b00)
          fp6_e3m2_to_fp16 = {s, 5'b11111, 10'b0};           // Inf
        else
          fp6_e3m2_to_fp16 = {s, 5'b11111, 10'b1000000000};  // NaN
      end else begin
        e16_int = int'({2'b0, e6}) - 3 + BIAS_FP16;
        e16     = e16_int[4:0];
        m16     = {m6, 8'b0};
        fp6_e3m2_to_fp16 = {s, e16, m16};
      end
    end
  endfunction

  // E2M3: 1 sign + 2 exp + 3 mantissa, bias = 1
  // Stored in low 6 bits of 8-bit container: {2'b0, S, EE, MMM}
  // OCP MX spec: E2M3 has NO Inf/NaN (all exponent values are normal)
  function automatic logic [15:0] fp6_e2m3_to_fp16 (input logic [7:0] in);
    logic       s;
    logic [1:0] e6;
    logic [2:0] m6;
    logic [4:0] e16;
    logic [9:0] m16;
    int         e16_int;
    begin
      s  = in[5];
      e6 = in[4:3];
      m6 = in[2:0];

      if (e6 == 2'b00) begin
        fp6_e2m3_to_fp16 = {s, 5'b0, 10'b0};
      end else begin
        e16_int = int'({3'b0, e6}) - 1 + BIAS_FP16;
        e16     = e16_int[4:0];
        m16     = {m6, 7'b0};
        fp6_e2m3_to_fp16 = {s, e16, m16};
      end
    end
  endfunction

  // Format-aware MX element → FP16 conversion
  function automatic logic [15:0] fp8_to_fp16 (input logic [7:0] in, input mx_format_e fmt);
    begin
      case (fmt)
        MX_FMT_E5M2:  fp8_to_fp16 = fp8_e5m2_to_fp16(in);
        MX_FMT_E2M1:  fp8_to_fp16 = fp4_e2m1_to_fp16(in);
        MX_FMT_E3M2:  fp8_to_fp16 = fp6_e3m2_to_fp16(in);
        MX_FMT_E2M3:  fp8_to_fp16 = fp6_e2m3_to_fp16(in);
        default:       fp8_to_fp16 = fp8_e4m3_to_fp16(in);
      endcase
    end
  endfunction

  function automatic logic [15:0] mx_scale_fp16(
    input logic [15:0] val_fp16,
    input logic [7:0]  shared_exp
  );
    logic       s;
    logic [4:0] e16;
    logic [9:0] m16;
    int signed  delta;
    int signed  new_e16;
    localparam logic [15:0] FP16_MAX_POS = 16'h7bff;
    begin
      s   = val_fp16[15];
      e16 = val_fp16[14:10];
      m16 = val_fp16[9:0];

      if (e16 == 5'b0 || e16 == 5'b11111) begin
        mx_scale_fp16 = val_fp16;
      end else begin
        delta   = int'(shared_exp) - 127;
        new_e16 = int'(e16) + delta;
        if (new_e16 <= 0) begin
          mx_scale_fp16 = {s,5'b0,10'b0};
        end else if (new_e16 >= 31) begin
          mx_scale_fp16 = {s,FP16_MAX_POS[14:0]};
        end else begin
          mx_scale_fp16 = {s,new_e16[4:0],m16};
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------
  //  Pipeline registers
  // ---------------------------------------------------------------

  // --- Stage 0: input latch + FP8→FP16 conversion result ---
  logic                          s0_valid_q;
  logic [NUM_LANES-1:0][BITW-1:0] s0_unscaled_q;
  logic [7:0]                    s0_scale_q;
  logic [TAG_WIDTH-1:0]          s0_tag_q;

  // --- Stage 1: scaled output ---
  logic                          s1_valid_q;
  logic [NUM_LANES*BITW-1:0]     s1_data_q;
  logic [TAG_WIDTH-1:0]          s1_tag_q;

  // ---------------------------------------------------------------
  //  Pipeline advancement (elastic, with bubble collapsing)
  // ---------------------------------------------------------------

  logic s1_advance, s0_advance;
  assign s1_advance = !s1_valid_q || fp16_ready_i;
  assign s0_advance = !s0_valid_q || s1_advance;

  // ---------------------------------------------------------------
  //  Input handshake
  // ---------------------------------------------------------------

  logic input_fire;
  assign mx_val_ready_o = s0_advance;
  assign mx_exp_ready_o = s0_advance;
  assign input_fire     = mx_val_valid_i && mx_exp_valid_i && s0_advance;

  // ---------------------------------------------------------------
  //  Combinational: FP8 → FP16 (from input data, latched into S0)
  // ---------------------------------------------------------------

  logic [NUM_LANES-1:0][BITW-1:0] input_unscaled;

  for (genvar i = 0; i < NUM_LANES; i++) begin : gen_convert
    assign input_unscaled[i] = fp8_to_fp16(mx_val_data_i[ELEM_WIDTH*i +: ELEM_WIDTH], mx_format_i);
  end

  // ---------------------------------------------------------------
  //  Combinational: MX scale (from S0 registered data, into S1)
  // ---------------------------------------------------------------

  logic [NUM_LANES*BITW-1:0] s0_scaled;

  for (genvar i = 0; i < NUM_LANES; i++) begin : gen_scale
    assign s0_scaled[i*BITW +: BITW] = mx_scale_fp16(s0_unscaled_q[i], s0_scale_q);
  end

  // ---------------------------------------------------------------
  //  Sequential logic
  // ---------------------------------------------------------------

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s0_valid_q    <= 1'b0;
      s0_unscaled_q <= '0;
      s0_scale_q    <= '0;
      s0_tag_q      <= '0;
      s1_valid_q    <= 1'b0;
      s1_data_q     <= '0;
      s1_tag_q      <= '0;
    end else begin
      // --- Stage 1 ---
      if (s1_advance) begin
        s1_valid_q <= s0_valid_q;
        if (s0_valid_q) begin
          s1_data_q <= s0_scaled;
          s1_tag_q  <= s0_tag_q;
        end
      end

      // --- Stage 0 ---
      if (s0_advance) begin
        s0_valid_q <= input_fire;
        if (input_fire) begin
          s0_unscaled_q <= input_unscaled;
          // NUM_GROUPS==1: single scale regardless of vector mode
          s0_scale_q    <= mx_exp_data_i[7:0];
          s0_tag_q      <= tag_i;
        end
      end
    end
  end

  // ---------------------------------------------------------------
  //  Output
  // ---------------------------------------------------------------

  assign fp16_valid_o = s1_valid_q;
  assign fp16_data_o  = s1_data_q;
  assign tag_o        = s1_tag_q;

endmodule : redmule_mx_decoder
