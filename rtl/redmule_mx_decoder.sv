module redmule_mx_decoder
//import fpnew_pkg::*;
//import redmule_pkg::*;
  //import hci_package::*;
#(
  parameter int unsigned DATA_W = 256,//redmule_pkg::DATA_W,
  parameter int unsigned BITW = 16
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
  output logic [BITW-1:0]        fp16_data_o
);

// State machine
typedef enum logic [0:0] {
  IDLE,
  DECODE
} redmule_mx_decode_state_e;

redmule_mx_decode_state_e current_state, next_state;

// Internal registers
localparam int unsigned ELEM_WIDTH = 8;
localparam int unsigned NUM_ELEMS = DATA_W / ELEM_WIDTH;

logic [DATA_W-1:0] val_reg_q, val_reg_d; // buffered block of MX values 
logic [7:0] scale_reg_q, scale_reg_d; // buffered shared exp (E8M0)

logic [$clog2(NUM_ELEMS)-1:0] elem_idx_q, elem_idx_d; // index in block

// sequential part
always_ff @(posedge clk_i or negedge rst_ni ) begin : state_register
  if(!rst_ni) begin
    current_state <= IDLE;
    val_reg_q <= '0;
    scale_reg_q <= '0;
    elem_idx_q <= '0;
  end else begin
    current_state <= next_state;
    val_reg_q <= val_reg_d;
    scale_reg_q <= scale_reg_d;
    elem_idx_q <= elem_idx_d;
  end
end


always_comb begin : fsm
  // default
  next_state = current_state;
  val_reg_d = val_reg_q;
  scale_reg_d = scale_reg_q;
  elem_idx_d = elem_idx_q;

  mx_val_ready_o = 1'b0;
  mx_exp_ready_o = 1'b0;
  fp16_valid_o = 1'b0;
  fp16_data_o = '0;
  
  unique case (current_state)
    IDLE: begin
      mx_val_ready_o = 1'b1;
      mx_exp_ready_o = 1'b1;

      if (mx_val_valid_i && mx_exp_valid_i) begin
        // latch inputs
        val_reg_d = mx_val_data_i;
        scale_reg_d = mx_exp_data_i;
        elem_idx_d = '0;

        next_state = DECODE;
      end
    end

    DECODE: begin
      mx_val_ready_o = 1'b0;
      mx_exp_ready_o = 1'b0;

      // For now: print elem index, replace with FP8-> FP16 later
      fp16_valid_o = 1'b1;
      fp16_data_o =  elem_idx_q; // temp

      if (fp16_ready_i) begin
        if (elem_idx_q == NUM_ELEMS-1) begin
          // last element
          elem_idx_d = '0;
          next_state = IDLE;
        end else begin
          elem_idx_d = elem_idx_q + 1;
        end
      end
    end

    default: begin
      next_state = IDLE;
    end
  
  endcase
end

endmodule : redmule_mx_decoder