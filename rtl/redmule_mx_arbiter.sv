// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// MX Arbiter Module
// Round-robin arbiter for shared MX decoder access

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

  // Decoder outputs (for tracking completion)
  input  logic mx_dec_fp16_valid_i,
  input  logic mx_dec_fp16_ready_i,

  // Slot control
  output logic consume_x_slot_o,
  output logic consume_w_slot_o,

  // FSM state output (for input mux)
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

// Group counter to track decoder progress
localparam int unsigned MX_GROUP_CNT_W = (MX_INPUT_NUM_GROUPS > 1) ? $clog2(MX_INPUT_NUM_GROUPS) : 1;
logic [MX_GROUP_CNT_W-1:0] mx_dec_group_cnt_q, mx_dec_group_cnt_d;

// Latched input data for decoder
logic [MX_DATA_W-1:0]       mx_dec_val_data_q, mx_dec_val_data_d;
logic [MX_EXP_VECTOR_W-1:0] mx_dec_exp_data_q, mx_dec_exp_data_d;
logic                       mx_dec_vector_mode_q, mx_dec_vector_mode_d;

// Round-robin preference bit
logic mx_dec_turn_q, mx_dec_turn_d;

// Internal signals
logic x_req, w_req;
logic x_slot_ready, w_slot_ready;
mx_dec_target_e mx_dec_owner;
logic x_fifo_has_space, w_fifo_has_space;
logic x_req_with_space, w_req_with_space;
logic mx_dec_start_new;
logic mx_arb_force_rr;
logic mx_arb_strict_alt;
logic mx_dec_owner_can_start;

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

// Start new decode condition
assign mx_dec_owner_can_start = ((mx_dec_owner == MX_DEC_X) && x_req_with_space) ||
                                ((mx_dec_owner == MX_DEC_W) && w_req_with_space);
assign mx_dec_start_new = (mx_dec_target_q == MX_DEC_NONE) &&
                          (mx_dec_owner != MX_DEC_NONE) &&
                          mx_dec_owner_can_start;

// Consume signals
assign consume_x_slot_o = mx_dec_start_new && (mx_dec_owner == MX_DEC_X);
assign consume_w_slot_o = mx_dec_start_new && (mx_dec_owner == MX_DEC_W);

// Arbitration logic
always_comb begin
  if (mx_dec_target_q == MX_DEC_NONE) begin
    // Check which streams have space in their FIFOs
    logic x_can_decode, w_can_decode;
    logic w_needs_priority;
    x_can_decode = x_req && x_fifo_has_space;
    w_can_decode = w_req && w_fifo_has_space;

    // Priority logic: W gets priority if its FIFO is empty
    // This prevents scheduler stalls waiting for W data
    w_needs_priority = w_fifo_flgs_i.empty;

    // Strict alternation experiment: when both streams request, force turn ownership
    // and do not fallback to the other stream on lack of FIFO space.
    // This can intentionally stall decode start to preserve ordering.
    if (mx_arb_strict_alt && x_req && w_req) begin
      mx_dec_owner = mx_dec_turn_q ? MX_DEC_W : MX_DEC_X;
    end else unique case ({x_can_decode, w_can_decode})
      2'b10: mx_dec_owner = MX_DEC_X;
      2'b01: mx_dec_owner = MX_DEC_W;
      2'b11: begin
        // If W FIFO is empty, prioritize W to prevent scheduler stalls
        // Otherwise use round-robin
        if (w_needs_priority && !mx_arb_force_rr)
          mx_dec_owner = MX_DEC_W;
        else
          mx_dec_owner = mx_dec_turn_q ? MX_DEC_W : MX_DEC_X;
      end
      default: mx_dec_owner = MX_DEC_NONE;
    endcase
  end else begin
    mx_dec_owner = mx_dec_target_q;
  end
end

// Valid signals: ONLY asserted when we have latched data (target_q != NONE)
// Do NOT assert valid during the transition cycle (when owner assigned but data not yet latched)
// This prevents decoder from seeing valid=1 with stale data
assign mx_dec_val_valid_o = (mx_dec_target_q != MX_DEC_NONE);
assign mx_dec_exp_valid_o = (mx_dec_target_q != MX_DEC_NONE);

// Output latched data
assign mx_dec_val_data_o    = mx_dec_val_data_q;
assign mx_dec_exp_data_o    = mx_dec_exp_data_q;
assign mx_dec_vector_mode_o = mx_dec_vector_mode_q;
assign mx_dec_target_o      = mx_dec_target_q;

`ifndef SYNTHESIS
bit dbg_mxarb;
initial dbg_mxarb = $test$plusargs("MX_ARB_DBG") || $test$plusargs("MX_DEBUG_DUMP");
assign mx_arb_force_rr = 1'b0;
initial mx_arb_strict_alt = $test$plusargs("MX_ARB_STRICT_ALT");
`else
assign mx_arb_force_rr = 1'b0;
assign mx_arb_strict_alt = 1'b0;
`endif

// Sequential logic
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    mx_dec_target_q <= MX_DEC_NONE;
    mx_dec_group_cnt_q <= '0;
    mx_dec_val_data_q <= '0;
    mx_dec_exp_data_q <= '0;
    mx_dec_vector_mode_q <= 1'b0;
    mx_dec_turn_q <= 1'b1;  // Start with W preference
  end else if (clear_i) begin
    mx_dec_target_q <= MX_DEC_NONE;
    mx_dec_group_cnt_q <= '0;
    mx_dec_val_data_q <= '0;
    mx_dec_exp_data_q <= '0;
    mx_dec_vector_mode_q <= 1'b0;
    mx_dec_turn_q <= 1'b1;  // Maintain W preference after clear
  end else begin
    mx_dec_target_q <= mx_dec_target_d;
    mx_dec_group_cnt_q <= mx_dec_group_cnt_d;
    mx_dec_val_data_q <= mx_dec_val_data_d;
    mx_dec_exp_data_q <= mx_dec_exp_data_d;
    mx_dec_vector_mode_q <= mx_dec_vector_mode_d;
    mx_dec_turn_q <= mx_dec_turn_d;

`ifndef SYNTHESIS
    if (dbg_mxarb && mx_enable_i) begin
      if (mx_dec_start_new) begin
        $display("[DBG][MX_ARB][%0t] start owner=%s x_req=%0b w_req=%0b x_space=%0b w_space=%0b x_full=%0b w_full=%0b x_empty=%0b w_empty=%0b turn=%0b",
                 $time,
                 (mx_dec_owner == MX_DEC_X) ? "X" : ((mx_dec_owner == MX_DEC_W) ? "W" : "NONE"),
                 x_req, w_req,
                 x_fifo_has_space, w_fifo_has_space,
                 x_fifo_flgs_i.full, w_fifo_flgs_i.full,
                 x_fifo_flgs_i.empty, w_fifo_flgs_i.empty,
                 mx_dec_turn_q);
      end

      if (mx_dec_fp16_valid_i && mx_dec_fp16_ready_i) begin
        $display("[DBG][MX_ARB][%0t] dec_hs tgt=%s grp=%0d/%0d",
                 $time,
                 (mx_dec_target_q == MX_DEC_X) ? "X" : ((mx_dec_target_q == MX_DEC_W) ? "W" : "NONE"),
                 mx_dec_group_cnt_q,
                 MX_INPUT_NUM_GROUPS-1);
      end
    end
`endif
  end
end

// Combinational FSM logic
always_comb begin
  mx_dec_target_d = mx_dec_target_q;
  mx_dec_group_cnt_d = mx_dec_group_cnt_q;
  mx_dec_val_data_d = mx_dec_val_data_q;
  mx_dec_exp_data_d = mx_dec_exp_data_q;
  mx_dec_vector_mode_d = mx_dec_vector_mode_q;
  mx_dec_turn_d = mx_dec_turn_q;

  unique case (mx_dec_target_q)
    MX_DEC_NONE: begin
      // Transition when we have a valid owner with valid inputs
      if (mx_dec_start_new) begin
        mx_dec_target_d = mx_dec_owner;
        mx_dec_group_cnt_d = '0;  // Reset counter when starting new decode
        // Latch input data on transition
        mx_dec_val_data_d = (mx_dec_owner == MX_DEC_X) ? x_slot_data_i : w_slot_data_i;
        mx_dec_exp_data_d = (mx_dec_owner == MX_DEC_X) ?
                            {{(MX_EXP_VECTOR_W-8){1'b0}}, x_slot_exp_i} :
                            w_slot_exp_i;
        mx_dec_vector_mode_d = (mx_dec_owner == MX_DEC_W);
        // Only flip turn when both streams COULD have been served
        if (x_req_with_space && w_req_with_space) begin
          mx_dec_turn_d = ~mx_dec_turn_q;
        end
      end
    end
    default: begin
      // Track decoder progress by counting output handshakes
      if (mx_dec_fp16_valid_i && mx_dec_fp16_ready_i) begin
        if (mx_dec_group_cnt_q == MX_INPUT_NUM_GROUPS - 1) begin
          // Last group completed, release ownership
          mx_dec_target_d = MX_DEC_NONE;
          mx_dec_group_cnt_d = '0;
        end else begin
          // More groups to process
          mx_dec_group_cnt_d = mx_dec_group_cnt_q + 1'b1;
        end
      end
    end
  endcase
end

`ifndef SYNTHESIS
  longint unsigned x_req_cycles_q, w_req_cycles_q, both_req_cycles_q;
  longint unsigned x_blocked_fifo_q, w_blocked_fifo_q;
  longint unsigned x_grant_q, w_grant_q;
  longint unsigned rr_flip_q, w_priority_grant_q;
  logic [1:0]      dbg_prev_target_q;
  int unsigned     dbg_run_len_q;

  logic dbg_decode_fire;
  assign dbg_decode_fire = mx_dec_fp16_valid_i && mx_dec_fp16_ready_i;

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
      dbg_prev_target_q   <= MX_DEC_NONE;
      dbg_run_len_q       <= '0;
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
      dbg_prev_target_q   <= MX_DEC_NONE;
      dbg_run_len_q       <= '0;
    end else begin
      if (x_req) x_req_cycles_q <= x_req_cycles_q + 1;
      if (w_req) w_req_cycles_q <= w_req_cycles_q + 1;
      if (x_req && w_req) both_req_cycles_q <= both_req_cycles_q + 1;
      if (x_req && !x_fifo_has_space) x_blocked_fifo_q <= x_blocked_fifo_q + 1;
      if (w_req && !w_fifo_has_space) w_blocked_fifo_q <= w_blocked_fifo_q + 1;

      if (mx_dec_start_new && mx_dec_owner == MX_DEC_X) x_grant_q <= x_grant_q + 1;
      if (mx_dec_start_new && mx_dec_owner == MX_DEC_W) w_grant_q <= w_grant_q + 1;
      if (mx_dec_start_new && x_req_with_space && w_req_with_space) rr_flip_q <= rr_flip_q + 1;
      if (mx_dec_start_new && x_req_with_space && w_req_with_space && w_fifo_flgs_i.empty && mx_dec_owner == MX_DEC_W)
        w_priority_grant_q <= w_priority_grant_q + 1;

      // Track long contiguous decode runs for each target
      if (dbg_decode_fire) begin
        if (mx_dec_target_q == dbg_prev_target_q) begin
          dbg_run_len_q <= dbg_run_len_q + 1;
        end else begin
          dbg_prev_target_q <= mx_dec_target_q;
          dbg_run_len_q <= 1;
        end

        if (dbg_mxarb && dbg_run_len_q == 8 && (mx_dec_target_q == MX_DEC_X || mx_dec_target_q == MX_DEC_W)) begin
          $display("[DBG][MXARB][%0t] long_run target=%s len>=%0d x_req=%0b w_req=%0b x_space=%0b w_space=%0b w_empty=%0b turn=%0b",
                   $time,
                   (mx_dec_target_q == MX_DEC_X) ? "X" : "W",
                   dbg_run_len_q,
                   x_req,
                   w_req,
                   x_fifo_has_space,
                   w_fifo_has_space,
                   w_fifo_flgs_i.empty,
                   mx_dec_turn_q);
        end
      end
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
