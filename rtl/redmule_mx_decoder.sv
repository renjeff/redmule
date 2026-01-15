// MX decoder shared between the X (single shared exponent) and W (per-group
// shared exponent) data paths. A single parameter selects whether the exponent
// input carries one broadcast value or a vector with one entry per element
// group.

module redmule_mx_decoder
#(
  parameter int unsigned DATA_W = 256,
  parameter int unsigned BITW = 16,
  parameter int unsigned NUM_LANES = 1,
  parameter int unsigned MX_EXP_WIDTH = ((DATA_W / 8) / NUM_LANES) * 8
)(
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    mx_val_valid_i,
  output logic                    mx_val_ready_o,
  input  logic [DATA_W-1:0]       mx_val_data_i,

  input  logic                    mx_exp_valid_i,
  output logic                    mx_exp_ready_o,
  input  logic [MX_EXP_WIDTH-1:0] mx_exp_data_i,
  input  logic                    vector_shared_exp_i,

  output logic                    fp16_valid_o,
  input  logic                    fp16_ready_i,
  output logic [NUM_LANES*BITW-1:0] fp16_data_o
);

  localparam int unsigned ELEM_WIDTH  = 8;
  localparam int unsigned NUM_ELEMS   = DATA_W / ELEM_WIDTH;
  localparam int unsigned NUM_GROUPS  = NUM_ELEMS / NUM_LANES;
  localparam int unsigned GROUP_IDX_W = (NUM_GROUPS > 1) ? $clog2(NUM_GROUPS) : 1;

  initial begin
    if (NUM_LANES == 0) begin
      $fatal(1, "MX decoder: NUM_LANES must be > 0");
    end
    if (NUM_ELEMS % NUM_LANES != 0) begin
      $fatal(1, "MX decoder: NUM_ELEMS (%0d) must be divisible by NUM_LANES (%0d)",
             NUM_ELEMS, NUM_LANES);
    end
    if (NUM_GROUPS*8 != MX_EXP_WIDTH) begin
      $fatal(1, "MX decoder: MX_EXP_WIDTH (%0d) must be NUM_GROUPS*8 (%0d)",
             MX_EXP_WIDTH, NUM_GROUPS*8);
    end
  end

  typedef enum logic [0:0] {
    IDLE,
    DECODE
  } redmule_mx_decode_state_e;

  redmule_mx_decode_state_e current_state, next_state;

  localparam int BIAS_FP8  = 7;
  localparam int BIAS_FP16 = 15;

  logic [DATA_W-1:0]      val_reg_q, val_reg_d;
  logic [7:0]             scale_reg_q, scale_reg_d;
  logic [7:0]             scale_per_group_q [NUM_GROUPS];
  logic [7:0]             scale_per_group_d [NUM_GROUPS];
  logic [GROUP_IDX_W-1:0] group_idx_q, group_idx_d;
  logic                   vector_mode_q, vector_mode_d;

  logic [ELEM_WIDTH-1:0] elem_mx [NUM_LANES];
  logic [BITW-1:0]       elem_fp16_unscaled [NUM_LANES];
  logic [BITW-1:0]       elem_fp16_scaled [NUM_LANES];

  logic [7:0] current_scale;
  assign current_scale = vector_mode_q ? scale_per_group_q[group_idx_q] : scale_reg_q;

  genvar lane;
  generate
    for (lane = 0; lane < NUM_LANES; lane++) begin : gen_lanes
      logic [$clog2(NUM_ELEMS)-1:0] elem_idx_lane;
      assign elem_idx_lane = group_idx_q * NUM_LANES + lane;
      assign elem_mx[lane] = val_reg_q[ELEM_WIDTH*elem_idx_lane +: ELEM_WIDTH];

      always_comb begin
        logic [15:0] tmp;
        tmp = fp8_e4m3_to_fp16(elem_mx[lane]);
        elem_fp16_unscaled[lane] = tmp;
        elem_fp16_scaled[lane]   = mx_scale_fp16(tmp, current_scale);
      end
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      current_state <= IDLE;
      val_reg_q     <= '0;
      scale_reg_q   <= '0;
      group_idx_q   <= '0;
      vector_mode_q <= 1'b0;
      for (int g = 0; g < NUM_GROUPS; g++) begin
        scale_per_group_q[g] <= 8'd127;
      end
    end else begin
      current_state <= next_state;
      val_reg_q     <= val_reg_d;
      scale_reg_q   <= scale_reg_d;
      group_idx_q   <= group_idx_d;
      vector_mode_q <= vector_mode_d;
      for (int g = 0; g < NUM_GROUPS; g++) begin
        scale_per_group_q[g] <= scale_per_group_d[g];
      end
    end
  end

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
        e16_int = int'(e8) - BIAS_FP8 + BIAS_FP16;
        e16     = e16_int[4:0];
        m16     = {m8,7'b0};
        fp8_e4m3_to_fp16 = {s, e16, m16};
      end
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

  always_comb begin
    next_state  = current_state;
    val_reg_d   = val_reg_q;
    scale_reg_d = scale_reg_q;
    group_idx_d = group_idx_q;
    vector_mode_d = vector_mode_q;
    for (int g = 0; g < NUM_GROUPS; g++) begin
      scale_per_group_d[g] = scale_per_group_q[g];
    end

    mx_val_ready_o = 1'b0;
    mx_exp_ready_o = 1'b0;
    fp16_valid_o   = 1'b0;
    fp16_data_o    = '0;

    unique case (current_state)
      IDLE: begin
        mx_val_ready_o = 1'b1;
        mx_exp_ready_o = 1'b1;
        if (mx_val_valid_i && mx_exp_valid_i) begin
          val_reg_d      = mx_val_data_i;
          group_idx_d    = '0;
          vector_mode_d  = vector_shared_exp_i;
          if (vector_shared_exp_i) begin
            for (int g = 0; g < NUM_GROUPS; g++) begin
              scale_per_group_d[g] = mx_exp_data_i[8*g +: 8];
            end
          end else begin
            scale_reg_d = mx_exp_data_i[7:0];
          end
          next_state = DECODE;
        end
      end
      DECODE: begin
        fp16_valid_o = 1'b1;
        for (int i = 0; i < NUM_LANES; i++) begin
          fp16_data_o[BITW*i +: BITW] = elem_fp16_scaled[i];
        end
        if (fp16_ready_i) begin
          if (group_idx_q == NUM_GROUPS-1) begin
            group_idx_d = '0;
            next_state  = IDLE;
          end else begin
            group_idx_d = group_idx_q + 1'b1;
          end
        end
      end
      default: begin
        next_state = IDLE;
      end
    endcase
  end

endmodule : redmule_mx_decoder
