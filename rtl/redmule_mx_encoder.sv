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


// // State machine

typedef enum logic [1:0] {
    IDLE,
    SCAN,
    ENCODE
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
function automatic logic [7:0] compute_shared_exp(input logic [4:0] max_e16);
  int signed eM_unbiased;
  int signed e_scale_unbiased;
  int signed e8m0;
  begin
    eM_unbiased      = max_e16 - BIAS_FP16;
    e_scale_unbiased = eM_unbiased - 7;
    e8m0             = e_scale_unbiased + 127;

    if (e8m0 < 0)
      compute_shared_exp = 8'd0;
    else if (e8m0 > 255)
      compute_shared_exp = 8'd255;
    else
      compute_shared_exp = e8m0[7:0];
  end
endfunction


function automatic logic [ELEM_WIDTH-1:0] fp16_to_fp8_e4m3_unscaled(
  input logic [BITW-1:0] val_fp16
);
    // place holder: just drop low bits and keeo sign + 4b exp + 3b mant
    logic s;
    logic [4:0] e16;
    logic [9:0] m16;

    logic [3:0] e8;
    logic [2:0] m8;

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
        
        //normal

      
        e_unbias = e16 - BIAS_FP16 + BIAS_FP8_E4M3;

        if (e_unbias <= 0)
            return {s,7'b0}; //underflow to zero
        if (e_unbias >= 15)
            return {s,4'hE,3'b111}; // saturate
        
        e8 = e_unbias[3:0];
        m8 = m16[9:7]; // only truncate

        return{s,e8,m8};
    end
endfunction
   

// FP16 -> MXFP8 (E4M3+shared exp)
function automatic logic [ELEM_WIDTH-1:0] fp16_to_mxfp8(
    input logic [BITW-1:0] val_fp16,
    input logic [7:0] shared_exp
);
    logic s;
    logic [4:0] e16;
    logic [9:0] m16;

    logic [BITW-1:0] tmp;
    int signed delta;
    int signed e16_unscaled;

    begin
        s = val_fp16[15];
        e16 = val_fp16[14:10];
        m16 = val_fp16[9:0];

        // Zero/Inf/NaN: don't touch exponent, just quantise

        if (e16 == 5'b0 || e16 == 5'b11111) begin
            fp16_to_mxfp8 = fp16_to_fp8_e4m3_unscaled(val_fp16);
            return fp16_to_mxfp8;
        end
        
        // undo MX scaling:d ecode does e16_scaled = e16_unscaled + (shared_exp -127)
        delta = int'(shared_exp) - 127;
        e16_unscaled = e16 - delta;

        // clamp to FP8 range
        if (e16_unscaled <= 0)
            tmp = {s, 5'b0, 10'b0}; // underflow
        else if (e16_unscaled >= 31)
            tmp = {s, 5'b11110, 10'b1111111111}; // overflow to max finite
        else
            tmp = {s, e16_unscaled[4:0], m16}; // normal value

        fp16_to_mxfp8 = fp16_to_fp8_e4m3_unscaled(tmp);
        return fp16_to_mxfp8;
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
                        scale_reg_d = compute_shared_exp(e16_max_d);
                        group_idx_d = '0;
                        next_state = ENCODE;
                    end else begin
                        // more groups incoming
                        group_idx_d = 1;
                        next_state = SCAN;
                    end
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
                        scale_reg_d = compute_shared_exp(e16_max_d);
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
                    fp8_val = fp16_to_mxfp8(fp16_val, scale_reg_q);

                    val_reg_d[ELEM_WIDTH*elem_idx +: ELEM_WIDTH] = fp8_val;
                    // // DEBUG: show encode step
                    // $display("[%0t] ENCODE: group=%0d lane=%0d elem_idx=%0d fp16_val=0x%04h shared=0x%02h fp8_val=0x%02h",
                    //     $time, group_idx_q, l, elem_idx, fp16_val, scale_reg_q, fp8_val);
                end
                // once at last group, block is ready
                if (group_idx_q == NUM_GROUPS -1) begin
                    mx_val_valid_o = 1'b1;
                    mx_exp_valid_o = 1'b1;
                    mx_val_data_o  = val_reg_d;
                    // DEBUG: dump final packed MX block
                    // $display("[%0t] ENCODE DONE: shared_exp=0x%02h", $time, scale_reg_q);

                    // wait for both outputs to be accepted
                    if (mx_val_ready_i && mx_exp_ready_i) begin
                        next_state = IDLE;
                        group_idx_d = '0;
                    end
                // ellse: stay in ENCODE, keep val_reg_q stable and re-assert valid in next cycle
                end else begin
                    // still filling block, move to nect group
                    group_idx_d = group_idx_q + 1;
                    
                end
            end
            
            default: begin
                next_state = IDLE;
            end

        endcase 
    end


endmodule : redmule_mx_encoder

