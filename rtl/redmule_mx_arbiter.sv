// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// MX Arbiter Module
// Round-robin arbiter for shared MX decoder access.
//
// Pipelined version: releases ownership on decoder INPUT acceptance
// (not output completion).  Supports immediate re-grant so the arbiter
// can feed a new slot to the decoder every cycle without a NONE gap.

`include "hci_helpers.svh"

module redmule_mx_arbiter
  import redmule_pkg::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned MX_DATA_W           = 256,
  parameter int unsigned MX_EXP_VECTOR_W     = 32,
  parameter int unsigned MX_NUM_LANES        = 32,
  parameter int unsigned MX_INPUT_NUM_GROUPS = 1,
  parameter int unsigned BITW                = 16
)(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  input  logic mx_enable_i,

  // Slot inputs from slot buffer (mantissa valid + exponent valid per stream)
  input  logic x_slot_valid_i,
  input  logic x_slot_exp_valid_i,
  input  logic w_slot_valid_i,
  input  logic w_slot_exp_valid_i,
  input  logic [MX_DATA_W-1:0] x_slot_data_i,
  input  logic [MX_DATA_W-1:0] w_slot_data_i,
  input  logic [7:0] x_slot_exp_i,
  input  logic [MX_EXP_VECTOR_W-1:0] w_slot_exp_i,

  // FIFO space checking
  input  flags_fifo_t x_fifo_flgs_i,
  input  flags_fifo_t w_fifo_flgs_i,

  // Decoder interface
  output logic mx_dec_val_valid_o,
  output logic mx_dec_exp_valid_o,
  input  logic mx_dec_val_ready_i,
  input  logic mx_dec_exp_ready_i,
  output logic [MX_DATA_W-1:0] mx_dec_val_data_o,
  output logic [MX_EXP_VECTOR_W-1:0] mx_dec_exp_data_o,
  output logic mx_dec_vector_mode_o,

  // Decoder outputs (kept for debug visibility)
  input  logic mx_dec_fp16_valid_i,
  input  logic mx_dec_fp16_ready_i,

  // Slot control
  output logic consume_x_slot_o,
  output logic consume_w_slot_o,

  // FSM state output (current latch target, used as decoder tag_i)
  output logic [1:0] mx_dec_target_o
);

// FSM state type
typedef enum logic [1:0] {
  MX_DEC_NONE,
  MX_DEC_X,
  MX_DEC_W
} mx_dec_target_e;

// FSM state registers
mx_dec_target_e mx_dec_target_q, mx_dec_target_d;

// Latched input data for decoder
logic [MX_DATA_W-1:0]       mx_dec_val_data_q, mx_dec_val_data_d;
logic [MX_EXP_VECTOR_W-1:0] mx_dec_exp_data_q, mx_dec_exp_data_d;
logic                       mx_dec_vector_mode_q, mx_dec_vector_mode_d;

// Round-robin preference bit
logic mx_dec_turn_q, mx_dec_turn_d;

// Internal signals
logic x_req, w_req;
logic x_slot_ready, w_slot_ready;
logic x_fifo_has_space, w_fifo_has_space;
logic x_req_with_space, w_req_with_space;
logic mx_arb_force_rr;
logic mx_arb_strict_alt;

// FIFO space checking
assign x_fifo_has_space = !x_fifo_flgs_i.full;
assign w_fifo_has_space = !w_fifo_flgs_i.full;

// Request signals (only assert once mantissa and exponent are both present)
assign x_slot_ready = x_slot_valid_i && x_slot_exp_valid_i;
assign w_slot_ready = w_slot_valid_i && w_slot_exp_valid_i;
assign x_req = mx_enable_i && x_slot_ready;
assign w_req = mx_enable_i && w_slot_ready;

// Request signals with FIFO space
assign x_req_with_space = x_req && x_fifo_has_space;
assign w_req_with_space = w_req && w_fifo_has_space;

// ---------------------------------------------------------------
//  Next-owner arbitration (combinational, shared by both paths)
// ---------------------------------------------------------------

mx_dec_target_e next_owner;
logic           next_owner_valid;
logic           w_needs_priority;

assign w_needs_priority = w_fifo_flgs_i.empty || w_fifo_flgs_i.almost_empty;

always_comb begin
  next_owner       = MX_DEC_NONE;
  next_owner_valid = 1'b0;

  if (mx_arb_strict_alt && x_req && w_req) begin
    next_owner       = mx_dec_turn_q ? MX_DEC_W : MX_DEC_X;
    next_owner_valid = (next_owner == MX_DEC_X) ? x_fifo_has_space : w_fifo_has_space;
  end else begin
    unique case ({x_req_with_space, w_req_with_space})
      2'b10: begin next_owner = MX_DEC_X; next_owner_valid = 1'b1; end
      2'b01: begin next_owner = MX_DEC_W; next_owner_valid = 1'b1; end
      2'b11: begin
        if (w_needs_priority && !mx_arb_force_rr)
          next_owner = MX_DEC_W;
        else
          next_owner = mx_dec_turn_q ? MX_DEC_W : MX_DEC_X;
        next_owner_valid = 1'b1;
      end
      default: begin end
    endcase
  end
end

// ---------------------------------------------------------------
//  Decoder acceptance detection
// ---------------------------------------------------------------

logic decoder_accepts;
assign decoder_accepts = (mx_dec_target_q != MX_DEC_NONE) && mx_dec_val_ready_i;

// ---------------------------------------------------------------
//  Latch new slot: either from NONE or immediate re-grant
// ---------------------------------------------------------------

logic latch_new;
assign latch_new = (mx_dec_target_q == MX_DEC_NONE && next_owner_valid) ||
                   (decoder_accepts && next_owner_valid);

// Consume signals: fire when we latch new slot data
assign consume_x_slot_o = latch_new && (next_owner == MX_DEC_X);
assign consume_w_slot_o = latch_new && (next_owner == MX_DEC_W);

// Valid signals: asserted when we have latched data
assign mx_dec_val_valid_o = (mx_dec_target_q != MX_DEC_NONE);
assign mx_dec_exp_valid_o = (mx_dec_target_q != MX_DEC_NONE);

// Output latched data
assign mx_dec_val_data_o    = mx_dec_val_data_q;
assign mx_dec_exp_data_o    = mx_dec_exp_data_q;
assign mx_dec_vector_mode_o = mx_dec_vector_mode_q;
assign mx_dec_target_o      = mx_dec_target_q;

// ---------------------------------------------------------------
//  Combinational next-state
// ---------------------------------------------------------------

always_comb begin
  mx_dec_target_d      = mx_dec_target_q;
  mx_dec_val_data_d    = mx_dec_val_data_q;
  mx_dec_exp_data_d    = mx_dec_exp_data_q;
  mx_dec_vector_mode_d = mx_dec_vector_mode_q;
  mx_dec_turn_d        = mx_dec_turn_q;

  if (latch_new) begin
    // Transition to new target (from NONE or re-grant)
    mx_dec_target_d      = next_owner;
    mx_dec_val_data_d    = (next_owner == MX_DEC_X) ? x_slot_data_i : w_slot_data_i;
    mx_dec_exp_data_d    = (next_owner == MX_DEC_X) ?
                           {{(MX_EXP_VECTOR_W-8){1'b0}}, x_slot_exp_i} :
                           w_slot_exp_i;
    mx_dec_vector_mode_d = (next_owner == MX_DEC_W);
    // Flip turn when both streams could have been served
    if (x_req_with_space && w_req_with_space)
      mx_dec_turn_d = ~mx_dec_turn_q;
  end else if (decoder_accepts && !next_owner_valid) begin
    // Decoder took our data but no next slot ready → go idle
    mx_dec_target_d = MX_DEC_NONE;
  end
end

// ---------------------------------------------------------------
//  Debug / synthesis config
// ---------------------------------------------------------------

`ifndef SYNTHESIS
bit dbg_mxarb;
initial dbg_mxarb = $test$plusargs("MX_ARB_DBG") || $test$plusargs("MX_DEBUG_DUMP");
assign mx_arb_force_rr = 1'b0;
initial mx_arb_strict_alt = $test$plusargs("MX_ARB_STRICT_ALT");
`else
assign mx_arb_force_rr = 1'b0;
assign mx_arb_strict_alt = 1'b0;
`endif

// ---------------------------------------------------------------
//  Sequential logic
// ---------------------------------------------------------------

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    mx_dec_target_q      <= MX_DEC_NONE;
    mx_dec_val_data_q    <= '0;
    mx_dec_exp_data_q    <= '0;
    mx_dec_vector_mode_q <= 1'b0;
    mx_dec_turn_q        <= 1'b1;  // Start with W preference
  end else if (clear_i) begin
    mx_dec_target_q      <= MX_DEC_NONE;
    mx_dec_val_data_q    <= '0;
    mx_dec_exp_data_q    <= '0;
    mx_dec_vector_mode_q <= 1'b0;
    mx_dec_turn_q        <= 1'b1;
  end else begin
    mx_dec_target_q      <= mx_dec_target_d;
    mx_dec_val_data_q    <= mx_dec_val_data_d;
    mx_dec_exp_data_q    <= mx_dec_exp_data_d;
    mx_dec_vector_mode_q <= mx_dec_vector_mode_d;
    mx_dec_turn_q        <= mx_dec_turn_d;

`ifndef SYNTHESIS
    if (dbg_mxarb && mx_enable_i) begin
      if (latch_new) begin
        $display("[DBG][MX_ARB][%0t] latch owner=%s x_req=%0b w_req=%0b x_space=%0b w_space=%0b w_empty=%0b turn=%0b regrant=%0b",
                 $time,
                 (next_owner == MX_DEC_X) ? "X" : ((next_owner == MX_DEC_W) ? "W" : "NONE"),
                 x_req, w_req,
                 x_fifo_has_space, w_fifo_has_space,
                 w_fifo_flgs_i.empty,
                 mx_dec_turn_q,
                 (mx_dec_target_q != MX_DEC_NONE));
      end
    end
`endif
  end
end

// ---------------------------------------------------------------
//  Debug counters
// ---------------------------------------------------------------

`ifndef SYNTHESIS
  longint unsigned x_req_cycles_q, w_req_cycles_q, both_req_cycles_q;
  longint unsigned x_blocked_fifo_q, w_blocked_fifo_q;
  longint unsigned x_grant_q, w_grant_q;
  longint unsigned rr_flip_q, w_priority_grant_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : mxarb_debug_counters
    if (!rst_ni) begin
      x_req_cycles_q      <= '0;
      w_req_cycles_q      <= '0;
      both_req_cycles_q   <= '0;
      x_blocked_fifo_q    <= '0;
      w_blocked_fifo_q    <= '0;
      x_grant_q           <= '0;
      w_grant_q           <= '0;
      rr_flip_q           <= '0;
      w_priority_grant_q  <= '0;
    end else if (clear_i) begin
      x_req_cycles_q      <= '0;
      w_req_cycles_q      <= '0;
      both_req_cycles_q   <= '0;
      x_blocked_fifo_q    <= '0;
      w_blocked_fifo_q    <= '0;
      x_grant_q           <= '0;
      w_grant_q           <= '0;
      rr_flip_q           <= '0;
      w_priority_grant_q  <= '0;
    end else begin
      if (x_req) x_req_cycles_q <= x_req_cycles_q + 1;
      if (w_req) w_req_cycles_q <= w_req_cycles_q + 1;
      if (x_req && w_req) both_req_cycles_q <= both_req_cycles_q + 1;
      if (x_req && !x_fifo_has_space) x_blocked_fifo_q <= x_blocked_fifo_q + 1;
      if (w_req && !w_fifo_has_space) w_blocked_fifo_q <= w_blocked_fifo_q + 1;

      if (latch_new && next_owner == MX_DEC_X) x_grant_q <= x_grant_q + 1;
      if (latch_new && next_owner == MX_DEC_W) w_grant_q <= w_grant_q + 1;
      if (latch_new && x_req_with_space && w_req_with_space) rr_flip_q <= rr_flip_q + 1;
      if (latch_new && x_req_with_space && w_req_with_space && w_fifo_flgs_i.empty && next_owner == MX_DEC_W)
        w_priority_grant_q <= w_priority_grant_q + 1;
    end
  end

  final begin
    $display("[mx_arbiter] force_rr=%0b strict_alt=%0b x_req=%0d w_req=%0d both_req=%0d x_block_fifo=%0d w_block_fifo=%0d x_grant=%0d w_grant=%0d rr_flips=%0d w_prio_grants=%0d",
             mx_arb_force_rr,
             mx_arb_strict_alt,
             x_req_cycles_q, w_req_cycles_q, both_req_cycles_q,
             x_blocked_fifo_q, w_blocked_fifo_q,
             x_grant_q, w_grant_q, rr_flip_q, w_priority_grant_q);
  end
`endif

endmodule : redmule_mx_arbiter
