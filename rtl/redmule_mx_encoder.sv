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
  int signed scale_needed;
  int signed e8m0;
  begin
    // Special case: if no normal values found in block (max_e16 == 0),
    // return neutral scale (127 = 0x7F) to match golden model behavior.
    // This happens when all inputs are zero, subnormal, Inf, or NaN.
    if (max_e16 == 5'd0) begin
      compute_shared_exp = 8'd127;
    end else begin
      // MX scaling: adjust so max FP16 exponent maps to max usable FP8 exponent
      // For MXFP8 E4M3: max exponent is 14 (0b1110), representing unbiased 7
      // 
      // We want: max_e16 (unbiased) = e8_max (unbiased) + scale_bias
      // scale_bias = max_e16_unbiased - e8_max_unbiased
      //            = (max_e16 - 15) - (14 - 7)
      //            = max_e16 - 15 - 7
      //            = max_e16 - 22
      // 
      // E8M0 encoding: shared_exp = scale_bias + 127
      
      eM_unbiased = int'(max_e16) - BIAS_FP16;     // Unbiased FP16 max exp
      scale_needed = eM_unbiased - 7;               // 7 = max unbiased FP8 E4M3 exp (14-7)
      e8m0 = scale_needed + 127;                    // E8M0 biased format
      
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
   
// FP16 -> MXFP8 (E4M3+shared exp)
function automatic logic [ELEM_WIDTH-1:0] fp16_to_mxfp8(
    input logic [BITW-1:0] val_fp16,
    input logic [7:0] shared_exp
);
    logic s;
    logic [4:0] e16;
    logic [9:0] m16;

    logic [3:0] e8;
    logic [2:0] m8_trunc, m8_round;
    logic rbit, sbit, round_up, carry;

    int signed delta;
    int signed e8_unbiased;
    int signed e8_biased_tmp;

    begin
        s = val_fp16[15];
        e16 = val_fp16[14:10];
        m16 = val_fp16[9:0];

        // Zero
        if (e16 == 5'b0)
            return {s, 7'b0};

        // Inf/NaN
        if (e16 == 5'b11111) begin
            if (m16 == 0)
                return {s, 4'hF, 3'b000}; // inf
            else 
                return {s, 4'hF, 3'b001}; // NaN
        end

        // Normal: compute FP8 exponent directly
        // Decoder does: e16_scaled = e8 - BIAS_FP8 + BIAS_FP16 + (shared_exp - 127)
        // So encoder needs: e8 = e16 - BIAS_FP16 + BIAS_FP8 - (shared_exp - 127)
        delta = int'(shared_exp) - 127;
        e8_unbiased = int'(e16) - BIAS_FP16 - delta;
        
        // Check for underflow (maps to zero in FP8)
        if (e8_unbiased < -BIAS_FP8_E4M3)
            return {s, 4'b0000, 3'b000};
        
        // Check for overflow (saturate to max finite FP8)
        if (e8_unbiased > 7)  // max unbiased exp for E4M3 is 7 (biased 14)
            return {s, 4'hE, 3'b111};
        
        // Bias the exponent for FP8
        e8_biased_tmp = e8_unbiased + BIAS_FP8_E4M3;
        e8 = e8_biased_tmp[3:0];
        
        // Handle subnormal result (e8 would be 0)
        if (e8 == 4'b0)
            return {s, 4'b0000, 3'b000}; // flush to zero for simplicity
        
        // Truncate mantissa with RNE rounding
        m8_trunc = m16[9:7];
        rbit = m16[6];
        sbit = |m16[5:0];
        round_up = rne_round_up(m8_trunc[0], rbit, sbit);
        
        {carry, m8_round} = {1'b0, m8_trunc} + round_up;
        
        if (carry) begin
            if (e8 >= 4'hE) begin
                e8 = 4'hE;
                m8_round = 3'b111;
            end else begin
                e8 = e8 + 4'd1;
            end
        end
        
        return {s, e8, m8_round};
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

