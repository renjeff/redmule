// Wide MX decoder: accumulates 2 narrow decoder slots and decodes them
// in parallel using 2 decoder instances. Produces 1 full beat (64 FP16)
// per 2 input cycles, halving the decode latency per beat.
//
// Interface: same as redmule_mx_decoder but with double-width output.
// The input accepts 1 slot per cycle (same as narrow decoder).
// Internally, it collects 2 slots + 2 exponents, then fires both decoders.
// Output is valid every 2 input cycles (1 full beat).

module redmule_mx_decoder_wide
#(
  parameter int unsigned DATA_W    = 256,   // Single slot width (32 FP8)
  parameter int unsigned BITW      = 16,
  parameter int unsigned NUM_LANES = 32,    // Lanes per slot
  parameter int unsigned MX_EXP_WIDTH = 8,
  parameter int unsigned TAG_WIDTH = 2
)(
  input  logic                        clk_i,
  input  logic                        rst_ni,

  // Input: 1 slot per cycle (same as narrow decoder)
  input  logic                        mx_val_valid_i,
  output logic                        mx_val_ready_o,
  input  logic [DATA_W-1:0]           mx_val_data_i,

  input  logic                        mx_exp_valid_i,
  output logic                        mx_exp_ready_o,
  input  logic [MX_EXP_WIDTH-1:0]     mx_exp_data_i,
  input  logic                        vector_shared_exp_i,

  input  logic [TAG_WIDTH-1:0]        tag_i,
  output logic [TAG_WIDTH-1:0]        tag_o,

  // Output: 2 slots packed = 1 full beat (64 FP16)
  output logic                        fp16_valid_o,
  input  logic                        fp16_ready_i,
  output logic [2*NUM_LANES*BITW-1:0] fp16_data_o,

  // Hold stream: when high, arbiter should not switch streams (accumulating slot pair)
  output logic                        hold_stream_o
);

  localparam int unsigned SLOT_W = NUM_LANES * BITW;  // 512 bits per slot output

  // Accumulator: collect slot 0, then slot 1
  logic                   acc_has_slot0_q;
  logic [DATA_W-1:0]      acc_data0_q;
  logic [MX_EXP_WIDTH-1:0] acc_exp0_q;
  logic [TAG_WIDTH-1:0]   acc_tag0_q;
  logic                   acc_vec0_q;

  // Both decoders fire simultaneously when slot 1 arrives
  logic                   both_fire;
  logic [DATA_W-1:0]      dec0_data, dec1_data;
  logic [MX_EXP_WIDTH-1:0] dec0_exp, dec1_exp;
  logic                   dec0_vec, dec1_vec;
  logic [TAG_WIDTH-1:0]   dec_tag;

  // Decoder outputs
  logic                   dec0_out_valid, dec1_out_valid;
  logic [SLOT_W-1:0]      dec0_out_data, dec1_out_data;
  logic [TAG_WIDTH-1:0]   dec0_out_tag, dec1_out_tag;
  logic                   dec0_in_ready, dec1_in_ready;

  // Both decoders share the same output ready (they produce results in lockstep)
  logic                   dec_out_ready;

  // Input handshake: accept slots one at a time
  // Slot 0: accepted when accumulator is empty
  // Slot 1: accepted when accumulator has slot 0 AND both decoders are ready
  logic accept_slot0, accept_slot1;
  assign accept_slot0 = !acc_has_slot0_q && mx_val_valid_i && mx_exp_valid_i;
  // Slot 1 must have the same tag (same stream) as slot 0
  assign accept_slot1 = acc_has_slot0_q && mx_val_valid_i && mx_exp_valid_i &&
                        dec0_in_ready && dec1_in_ready &&
                        (tag_i == acc_tag0_q);

  assign mx_val_ready_o = accept_slot0 || accept_slot1;
  assign mx_exp_ready_o = mx_val_ready_o;

  // Fire both decoders when slot 1 arrives
  assign both_fire = accept_slot1;

  // Route data to decoders
  assign dec0_data = acc_data0_q;       // Slot 0 from accumulator
  assign dec0_exp  = acc_exp0_q;
  assign dec0_vec  = acc_vec0_q;
  assign dec1_data = mx_val_data_i;     // Slot 1 from input
  assign dec1_exp  = mx_exp_data_i;
  assign dec1_vec  = vector_shared_exp_i;
  assign dec_tag   = acc_tag0_q;        // Tag from slot 0 (same stream)

  // Accumulator register
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      acc_has_slot0_q <= 1'b0;
      acc_data0_q     <= '0;
      acc_exp0_q      <= '0;
      acc_tag0_q      <= '0;
      acc_vec0_q      <= 1'b0;
    end else if (accept_slot1) begin
      // Slot 1 consumed, clear accumulator
      acc_has_slot0_q <= 1'b0;
    end else if (accept_slot0) begin
      // Latch slot 0
      acc_has_slot0_q <= 1'b1;
      acc_data0_q     <= mx_val_data_i;
      acc_exp0_q      <= mx_exp_data_i;
      acc_tag0_q      <= tag_i;
      acc_vec0_q      <= vector_shared_exp_i;
    end
  end

  // Decoder instance 0 (processes slot 0)
  redmule_mx_decoder #(
    .DATA_W    ( DATA_W    ),
    .BITW      ( BITW      ),
    .NUM_LANES ( NUM_LANES ),
    .TAG_WIDTH ( TAG_WIDTH )
  ) i_dec0 (
    .clk_i               ( clk_i          ),
    .rst_ni              ( rst_ni         ),
    .mx_val_valid_i      ( both_fire      ),
    .mx_val_ready_o      ( dec0_in_ready  ),
    .mx_val_data_i       ( dec0_data      ),
    .mx_exp_valid_i      ( both_fire      ),
    .mx_exp_ready_o      (                ),  // unused, tied via dec0_in_ready
    .mx_exp_data_i       ( dec0_exp       ),
    .vector_shared_exp_i ( dec0_vec       ),
    .tag_i               ( dec_tag        ),
    .tag_o               ( dec0_out_tag   ),
    .fp16_valid_o        ( dec0_out_valid ),
    .fp16_ready_i        ( dec_out_ready  ),
    .fp16_data_o         ( dec0_out_data  )
  );

  // Decoder instance 1 (processes slot 1)
  redmule_mx_decoder #(
    .DATA_W    ( DATA_W    ),
    .BITW      ( BITW      ),
    .NUM_LANES ( NUM_LANES ),
    .TAG_WIDTH ( TAG_WIDTH )
  ) i_dec1 (
    .clk_i               ( clk_i          ),
    .rst_ni              ( rst_ni         ),
    .mx_val_valid_i      ( both_fire      ),
    .mx_val_ready_o      ( dec1_in_ready  ),
    .mx_val_data_i       ( dec1_data      ),
    .mx_exp_valid_i      ( both_fire      ),
    .mx_exp_ready_o      (                ),
    .mx_exp_data_i       ( dec1_exp       ),
    .vector_shared_exp_i ( dec1_vec       ),
    .tag_i               ( dec_tag        ),
    .tag_o               ( dec1_out_tag   ),
    .fp16_valid_o        ( dec1_out_valid ),
    .fp16_ready_i        ( dec_out_ready  ),
    .fp16_data_o         ( dec1_out_data  )
  );

  // Both decoders produce output on the same cycle (pipelined in lockstep)
  // Combine their outputs into 1 full beat
  assign fp16_valid_o = dec0_out_valid && dec1_out_valid;
  assign fp16_data_o  = {dec1_out_data, dec0_out_data};  // Slot 1 in upper half
  assign tag_o        = dec0_out_tag;
  assign dec_out_ready = fp16_ready_i;

  // Hold stream: tell arbiter not to switch while we have slot 0 buffered
  assign hold_stream_o = acc_has_slot0_q;

endmodule : redmule_mx_decoder_wide
