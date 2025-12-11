module redmule_mx_decoder
//import fpnew_pkg::*;
//import redmule_pkg::*;
  //import hci_package::*;
#(
  parameter int unsigned DATA_W = 256,//redmule_pkg::DATA_W,
  parameter int unsigned BITW = 16,
  parameter int unsigned NUM_LANES = 1
)(
  input  logic                   clk_i, 
  input  logic                   rst_ni,

  input  logic                   mx_val_valid_i,
  output logic                   mx_val_ready_o,
  input  logic [DATA_W-1:0]      mx_val_data_i,

  input logic                    mx_exp_valid_i,
  output logic                    mx_exp_ready_o,
  input logic [7:0]              mx_exp_data_i,

  output logic                   fp16_valid_o,
  input logic                    fp16_ready_i,
  output logic [NUM_LANES*BITW-1:0]        fp16_data_o
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

logic [DATA_W-1:0] val_reg_q, val_reg_d; // buffered block of MX values 
logic [7:0] scale_reg_q, scale_reg_d; // buffered shared exp (E8M0)

logic [$clog2(NUM_GROUPS)-1:0] group_idx_q, group_idx_d; // index in block

// MXFP8 datapath signals

logic [ELEM_WIDTH-1:0] elem_mx [NUM_LANES];
logic [BITW-1:0]      elem_fp16_unscaled [NUM_LANES];
logic [BITW-1:0]      elem_fp16_scaled [NUM_LANES];

genvar lane;
generate
  for (lane = 0; lane < NUM_LANES; lane++) begin : gen_lanes
    // lane element index inside a block
    logic [$clog2(NUM_ELEMS)-1:0] elem_idx_lane;

    assign elem_idx_lane = group_idx_q * NUM_LANES + lane;

    // slice out the FP8 element for this lane
    assign elem_mx[lane] = val_reg_q[ELEM_WIDTH*elem_idx_lane +: ELEM_WIDTH];

    // per lane decode
    always_comb begin
      logic [15:0] tmp;
      tmp = fp8_e4m3_to_fp16(elem_mx[lane]);
      elem_fp16_unscaled[lane] = tmp;
      elem_fp16_scaled[lane] = mx_scale_fp16(tmp, scale_reg_q);
    end
  end
endgenerate

// // scalar version
// logic [$clog2(NUM_ELEMS)-1:0] elem_idx;
// assign elem_idx = group_idx_q * NUM_LANES;
// assign elem_mx = val_reg_q[ELEM_WIDTH*elem_idx +: ELEM_WIDTH];

// sequential part
always_ff @(posedge clk_i or negedge rst_ni ) begin : state_register
  if(!rst_ni) begin
    current_state <= IDLE;
    val_reg_q <= '0;
    scale_reg_q <= '0;
    group_idx_q <= '0;
  end else begin
    current_state <= next_state;
    val_reg_q <= val_reg_d;
    scale_reg_q <= scale_reg_d;
    group_idx_q <= group_idx_d;
  end
end

function automatic logic [15:0] fp8_e4m3_to_fp16 (input logic [7:0] in);
  // FP8 fields
  logic       s;
  logic [3:0] e8;
  logic [2:0] m8;

  // FP16 fields
  logic [4:0]  e16;
  logic [9:0]  m16;
  int          e16_int;


  begin 
    s  = in[7];
    e8 = in[6:3];
    m8 = in[2:0];

    // // Debug print
    // $display("DEBUG fp8_to_fp16: in=0x%02h s=%0d e8=%0d m8=%0d BIAS_FP8=%0d BIAS_FP16=%0d",
    //          in, s, e8, m8, BIAS_FP8, BIAS_FP16);

    // zero and subnormals -> signed zero
    if (e8 == 4'b0000) begin
      fp8_e4m3_to_fp16 = {s,5'b0,10'b0};

    // Inf / NaN
    end else if (e8 == 4'b1111) begin
      if (m8 == 3'b000) begin
        fp8_e4m3_to_fp16 = {s,5'b11111,10'b0};
      end else begin
        fp8_e4m3_to_fp16 = {s,5'b11111,10'b1000000000};
      end

    end else begin
      e16_int = int'(e8) - BIAS_FP8 + BIAS_FP16;
      e16     = e16_int[4:0];
      m16     = {m8,7'b0}; // expand mantissa

      // // DEBUG: check the concat itself
      // tmp = {s, e16, m16};
      // $display("DEBUG CONCAT: s=%0d e16=%b (%0d) m16=%b tmp=0x%04h",
      //          s, e16, e16, m16, tmp);

      fp8_e4m3_to_fp16 = {s, e16, m16};
    end
  end
endfunction



// Apply MX shared exp (E8M0) as 2^k scale on FP16 value
// val_scaled = val * 2^(E_shared - 127)
function automatic logic [15:0] mx_scale_fp16
(
  input logic [15:0] val_fp16,
  input logic [7:0] shared_exp
);
  // FP16 fields;
  logic s;
  logic [4:0] e16;
  logic [9:0] m16;

  //signed exponent delta: k = E_shared - 127
  int signed delta;
  int signed new_e16;

  // max finite FP16 magnitude 0 11110 1111111111 = 16'h7bff
  localparam logic [15:0] FP16_MAX_POS = 16'h7bff;

  begin
    s = val_fp16[15];
    e16 = val_fp16[14:10];
    m16 = val_fp16[9:0];

    // zero, Inf, NaN: return as is
    if (e16 == 5'b0 || e16 == 5'b11111) begin
      mx_scale_fp16 = val_fp16;

    end else begin
      // Normal FP16 values
      // compute exponent with delta
      delta = int'(shared_exp) - 127;
      new_e16 = int'(e16) + delta;

      //underflow -> flush to signed 0
      if (new_e16 <= 0) begin
        mx_scale_fp16 = {s,5'b0,10'b0};
      
      //overflow -> clamp to max finite with sign
      end else if (new_e16 >= 31) begin
        mx_scale_fp16 = {s,FP16_MAX_POS[14:0]};
      
      // normal scaled case
      end else begin
        mx_scale_fp16 = {s,new_e16[4:0],m16};
      end
    end
  end
endfunction

// initial begin
//   $display(">>> DEBUG: BIAS_FP16 = %0d", BIAS_FP16);
//   $display(">>> DEBUG: fp8_e4m3_to_fp16(0x38) = 0x%h", fp8_e4m3_to_fp16(8'h38));
// end


always_comb begin : fsm
  // default
  next_state = current_state;
  val_reg_d = val_reg_q;
  scale_reg_d = scale_reg_q;
  group_idx_d = group_idx_q;

  mx_val_ready_o = 1'b0;
  mx_exp_ready_o = 1'b0;
  fp16_valid_o = 1'b0;
  fp16_data_o = '0;

  // elem_fp16_unscaled = fp8_e4m3_to_fp16(elem_mx); // scalar version
  // elem_fp16_scaled = mx_scale_fp16(elem_fp16_unscaled, scale_reg_q);
  
  unique case (current_state)
    IDLE: begin
      mx_val_ready_o = 1'b1;
      mx_exp_ready_o = 1'b1;

      if (mx_val_valid_i && mx_exp_valid_i) begin
        // latch inputs
        val_reg_d = mx_val_data_i;
        scale_reg_d = mx_exp_data_i;
        group_idx_d = '0;

        next_state = DECODE;
      end
    end

    DECODE: begin
      mx_val_ready_o = 1'b0;
      mx_exp_ready_o = 1'b0;

      fp16_valid_o = 1'b1;
      // fp16_data_o = elem_fp16_scaled[0];  // scalar version

      // pack NUM_LANES outputs
      for (int lane = 0; lane < NUM_LANES; lane++) begin
        fp16_data_o[BITW*lane +: BITW] = elem_fp16_scaled[lane];
      end

      if (fp16_ready_i) begin
        if (group_idx_q == NUM_GROUPS-1) begin
          // last element
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

endmodule : redmule_mx_decoder