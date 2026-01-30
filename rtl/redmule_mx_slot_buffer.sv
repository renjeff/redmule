// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// MX Slot Buffer Module
// Handles FP8 unpacking and slot buffering for X/W streams

`include "hci_helpers.svh"

module redmule_mx_slot_buffer
  import redmule_pkg::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned DATAW_ALIGN     = 512,
  parameter int unsigned MX_DATA_W       = 256,
  parameter int unsigned MX_EXP_VECTOR_W = 32,
  parameter int unsigned MX_INPUT_ELEM_WIDTH  = 8,
  parameter int unsigned MX_INPUT_NUM_ELEMS   = MX_DATA_W / MX_INPUT_ELEM_WIDTH
)(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  input  logic mx_enable_i,

  // Data streams from streamer (streaming interfaces)
  hwpe_stream_intf_stream.sink x_data_i,
  hwpe_stream_intf_stream.sink w_data_i,

  // Exponent inputs: direct register access from prefetch buffers (NO streaming protocol)
  input  logic [7:0]                x_exp_data_i,
  input  logic                      x_exp_valid_i,
  output logic                      x_exp_consume_o,
  input  logic [MX_EXP_VECTOR_W-1:0] w_exp_data_i,
  input  logic                      w_exp_valid_i,
  output logic                      w_exp_consume_o,

  // Slot outputs
  output logic x_slot_valid_o,
  output logic w_slot_valid_o,
  output logic [MX_DATA_W-1:0] x_slot_data_o,
  output logic [MX_DATA_W-1:0] w_slot_data_o,
  output logic [7:0] x_slot_exp_o,
  output logic [MX_EXP_VECTOR_W-1:0] w_slot_exp_o,

  // Control from arbiter
  input  logic consume_x_slot_i,
  input  logic consume_w_slot_i
);

// FP8 unpacking function
function automatic logic [MX_DATA_W-1:0] mx_unpack_half(input logic [MX_DATA_W-1:0] half_data);
  logic [MX_DATA_W-1:0] unpacked;
  for (int i = 0; i < MX_INPUT_NUM_ELEMS; i++) begin
    automatic int word_idx = i / 2;
    automatic int is_upper = i % 2;
    unpacked[i*8 +: 8] = is_upper ?
      half_data[word_idx*16 + 8 +: 8] :
      half_data[word_idx*16 +: 8];
  end
  return unpacked;
endfunction

// Local slot registers
logic                     x_slot_valid_q, x_slot_valid_d;
logic                     x_slot_data_valid_q, x_slot_data_valid_d;
logic                     x_slot_exp_valid_q,  x_slot_exp_valid_d;
logic [MX_DATA_W-1:0]     x_slot_data_q,  x_slot_data_d;
logic [7:0]               x_slot_exp_q,   x_slot_exp_d;

logic                     w_slot_valid_q, w_slot_valid_d;
logic                     w_slot_data_valid_q, w_slot_data_valid_d;
logic                     w_slot_exp_valid_q,  w_slot_exp_valid_d;
logic [MX_DATA_W-1:0]     w_slot_data_q,  w_slot_data_d;
logic [MX_EXP_VECTOR_W-1:0] w_slot_exp_q, w_slot_exp_d;

// Upper buffer registers (for second half of 512-bit beat)
logic                  x_upper_valid_q, x_upper_valid_d;
logic                  w_upper_valid_q, w_upper_valid_d;
logic [MX_DATA_W-1:0]  x_upper_buffer_q, x_upper_buffer_d;
logic [MX_DATA_W-1:0]  w_upper_buffer_q, w_upper_buffer_d;
logic                  x_upper_exp_valid_q, x_upper_exp_valid_d;
logic                  w_upper_exp_valid_q, w_upper_exp_valid_d;
logic [7:0]            x_upper_exp_q, x_upper_exp_d;
logic [MX_EXP_VECTOR_W-1:0] w_upper_exp_q, w_upper_exp_d;

// Unpacked data
logic [MX_DATA_W-1:0] x_unpacked_lower, x_unpacked_upper;
logic [MX_DATA_W-1:0] w_unpacked_lower, w_unpacked_upper;

// Accept signals
logic x_data_accept, x_exp_accept;
logic w_data_accept, w_exp_accept;

// Unpacking combinational logic
always_comb begin
  if (mx_enable_i) begin
    x_unpacked_lower = mx_unpack_half(x_data_i.data[MX_DATA_W-1:0]);
    x_unpacked_upper = mx_unpack_half(x_data_i.data[2*MX_DATA_W-1:MX_DATA_W]);
    w_unpacked_lower = mx_unpack_half(w_data_i.data[MX_DATA_W-1:0]);
    w_unpacked_upper = mx_unpack_half(w_data_i.data[2*MX_DATA_W-1:MX_DATA_W]);
  end else begin
    // FP16 mode: pass through (no unpacking needed)
    x_unpacked_lower = x_data_i.data[MX_DATA_W-1:0];
    x_unpacked_upper = '0;
    w_unpacked_lower = w_data_i.data[MX_DATA_W-1:0];
    w_unpacked_upper = '0;
  end
end

// Accept logic
assign x_data_accept = mx_enable_i && x_data_i.valid &&
                       !x_slot_data_valid_q && !x_upper_valid_q;
// Accept exponent when slot OR upper exp register needs one (prefetch allowed)
assign x_exp_accept  = mx_enable_i && x_exp_valid_i &&
                       (!x_slot_exp_valid_q || !x_upper_exp_valid_q);

assign w_data_accept = mx_enable_i && w_data_i.valid &&
                       !w_slot_data_valid_q && !w_upper_valid_q;
// Accept exponent when slot OR upper exp register needs one (prefetch allowed)
assign w_exp_accept  = mx_enable_i && w_exp_valid_i &&
                       (!w_slot_exp_valid_q || !w_upper_exp_valid_q);

// Ready signals for data streams
assign x_data_i.ready = mx_enable_i ? (!x_slot_data_valid_q && !x_upper_valid_q) : 1'b1;
assign w_data_i.ready = mx_enable_i ? (!w_slot_data_valid_q && !w_upper_valid_q) : 1'b1;

// Consume signals for exponent buffers (pulse when accepting)
assign x_exp_consume_o = x_exp_accept;
assign w_exp_consume_o = w_exp_accept;

// Output assignments
assign x_slot_valid_o = x_slot_valid_q;
assign w_slot_valid_o = w_slot_valid_q;
assign x_slot_data_o  = x_slot_data_q;
assign w_slot_data_o  = w_slot_data_q;
assign x_slot_exp_o   = x_slot_exp_q;
assign w_slot_exp_o   = w_slot_exp_q;

// Sequential logic
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    x_slot_valid_q <= 1'b0;
    x_slot_data_valid_q <= 1'b0;
    x_slot_exp_valid_q  <= 1'b0;
    x_slot_data_q  <= '0;
    x_slot_exp_q   <= '0;
    w_slot_valid_q <= 1'b0;
    w_slot_data_valid_q <= 1'b0;
    w_slot_exp_valid_q  <= 1'b0;
    w_slot_data_q  <= '0;
    w_slot_exp_q   <= '0;
    x_upper_valid_q <= 1'b0;
    x_upper_buffer_q <= '0;
    x_upper_exp_valid_q <= 1'b0;
    x_upper_exp_q <= '0;
    w_upper_valid_q <= 1'b0;
    w_upper_buffer_q <= '0;
    w_upper_exp_valid_q <= 1'b0;
    w_upper_exp_q <= '0;
  end else if (clear_i) begin
    x_slot_valid_q <= 1'b0;
    x_slot_data_valid_q <= 1'b0;
    x_slot_exp_valid_q  <= 1'b0;
    x_slot_data_q  <= '0;
    x_slot_exp_q   <= '0;
    w_slot_valid_q <= 1'b0;
    w_slot_data_valid_q <= 1'b0;
    w_slot_exp_valid_q  <= 1'b0;
    w_slot_data_q  <= '0;
    w_slot_exp_q   <= '0;
    x_upper_valid_q <= 1'b0;
    x_upper_buffer_q <= '0;
    x_upper_exp_valid_q <= 1'b0;
    x_upper_exp_q <= '0;
    w_upper_valid_q <= 1'b0;
    w_upper_buffer_q <= '0;
    w_upper_exp_valid_q <= 1'b0;
    w_upper_exp_q <= '0;
  end else begin
    x_slot_valid_q <= x_slot_valid_d;
    x_slot_data_valid_q <= x_slot_data_valid_d;
    x_slot_exp_valid_q  <= x_slot_exp_valid_d;
    x_slot_data_q  <= x_slot_data_d;
    x_slot_exp_q   <= x_slot_exp_d;
    w_slot_valid_q <= w_slot_valid_d;
    w_slot_data_valid_q <= w_slot_data_valid_d;
    w_slot_exp_valid_q  <= w_slot_exp_valid_d;
    w_slot_data_q  <= w_slot_data_d;
    w_slot_exp_q   <= w_slot_exp_d;
    x_upper_valid_q <= x_upper_valid_d;
    x_upper_buffer_q <= x_upper_buffer_d;
    x_upper_exp_valid_q <= x_upper_exp_valid_d;
    x_upper_exp_q <= x_upper_exp_d;
    w_upper_valid_q <= w_upper_valid_d;
    w_upper_buffer_q <= w_upper_buffer_d;
    w_upper_exp_valid_q <= w_upper_exp_valid_d;
    w_upper_exp_q <= w_upper_exp_d;
  end
end

// Combinational logic
always_comb begin
  x_slot_valid_d = x_slot_valid_q;
  x_slot_data_valid_d = x_slot_data_valid_q;
  x_slot_exp_valid_d  = x_slot_exp_valid_q;
  x_slot_data_d  = x_slot_data_q;
  x_slot_exp_d   = x_slot_exp_q;
  w_slot_valid_d = w_slot_valid_q;
  w_slot_data_valid_d = w_slot_data_valid_q;
  w_slot_exp_valid_d  = w_slot_exp_valid_q;
  w_slot_data_d  = w_slot_data_q;
  w_slot_exp_d   = w_slot_exp_q;
  x_upper_valid_d = x_upper_valid_q;
  x_upper_buffer_d = x_upper_buffer_q;
  x_upper_exp_valid_d = x_upper_exp_valid_q;
  x_upper_exp_d = x_upper_exp_q;
  w_upper_valid_d = w_upper_valid_q;
  w_upper_buffer_d = w_upper_buffer_q;
  w_upper_exp_valid_d = w_upper_exp_valid_q;
  w_upper_exp_d = w_upper_exp_q;

  // X data acceptance
  if (x_data_accept) begin
    x_slot_data_valid_d = 1'b1;
    x_slot_data_d = x_unpacked_lower;
    x_upper_valid_d = 1'b1;
    x_upper_buffer_d = x_unpacked_upper;
  end

  // X exponent acceptance: route to slot or upper based on which needs it
  // Each 256-bit block (slot and upper) needs its own exponent
  if (x_exp_accept) begin
    if (!x_slot_exp_valid_q) begin
      // Slot needs exponent - fill it first
      x_slot_exp_valid_d = 1'b1;
      x_slot_exp_d = x_exp_data_i;
    end else if (!x_upper_exp_valid_q) begin
      // Slot already has exp, upper needs one
      x_upper_exp_valid_d = 1'b1;
      x_upper_exp_d = x_exp_data_i;
    end
  end

  // Check if we have BOTH data and exp to form complete slot
  if (!x_slot_valid_q && (x_slot_data_valid_d || x_slot_data_valid_q) &&
      (x_slot_exp_valid_d || x_slot_exp_valid_q)) begin
    x_slot_valid_d = 1'b1;
  end

  // W data acceptance
  if (w_data_accept) begin
    w_slot_data_valid_d = 1'b1;
    w_slot_data_d = w_unpacked_lower;
    w_upper_valid_d = 1'b1;
    w_upper_buffer_d = w_unpacked_upper;
  end

  // W exponent acceptance: route to slot or upper based on which needs it
  // Each 256-bit block (slot and upper) needs its own exponent
  if (w_exp_accept) begin
    if (!w_slot_exp_valid_q) begin
      // Slot needs exponent - fill it first
      w_slot_exp_valid_d = 1'b1;
      w_slot_exp_d = w_exp_data_i;
    end else if (!w_upper_exp_valid_q) begin
      // Slot already has exp, upper needs one
      w_upper_exp_valid_d = 1'b1;
      w_upper_exp_d = w_exp_data_i;
    end
  end

  // Check if we have BOTH data and exp to form complete slot
  if (!w_slot_valid_q && (w_slot_data_valid_d || w_slot_data_valid_q) &&
      (w_slot_exp_valid_d || w_slot_exp_valid_q)) begin
    w_slot_valid_d = 1'b1;
  end

  // Slot consumption from arbiter
  // When slot consumed, move upper to slot if available (including its exponent)
  if (consume_x_slot_i) begin
    if (x_upper_valid_q) begin
      // Move upper data AND exponent to slot
      x_slot_data_valid_d = 1'b1;
      x_slot_data_d = x_upper_buffer_q;
      x_upper_valid_d = 1'b0;
      // Move upper exponent to slot
      if (x_upper_exp_valid_q) begin
        x_slot_exp_valid_d = 1'b1;
        x_slot_exp_d = x_upper_exp_q;
        x_upper_exp_valid_d = 1'b0;
        // Slot becomes valid immediately since it has both data and exp
        x_slot_valid_d = 1'b1;
      end else begin
        // Upper has no exponent yet - wait for it
        x_slot_valid_d = 1'b0;
        x_slot_exp_valid_d = 1'b0;
      end
    end else begin
      x_slot_valid_d = 1'b0;
      x_slot_data_valid_d = 1'b0;
      x_slot_exp_valid_d  = 1'b0;
    end
  end

  if (consume_w_slot_i) begin
    if (w_upper_valid_q) begin
      // Move upper data AND exponent to slot
      w_slot_data_valid_d = 1'b1;
      w_slot_data_d = w_upper_buffer_q;
      w_upper_valid_d = 1'b0;
      // Move upper exponent to slot
      if (w_upper_exp_valid_q) begin
        w_slot_exp_valid_d = 1'b1;
        w_slot_exp_d = w_upper_exp_q;
        w_upper_exp_valid_d = 1'b0;
        // Slot becomes valid immediately since it has both data and exp
        w_slot_valid_d = 1'b1;
      end else begin
        // Upper has no exponent yet - wait for it
        w_slot_valid_d = 1'b0;
        w_slot_exp_valid_d = 1'b0;
      end
    end else begin
      w_slot_valid_d = 1'b0;
      w_slot_data_valid_d = 1'b0;
      w_slot_exp_valid_d  = 1'b0;
    end
  end
end

endmodule : redmule_mx_slot_buffer
