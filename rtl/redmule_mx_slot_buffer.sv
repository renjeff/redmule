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

// Pending beat storage (allows double buffering one extra 512-bit beat)
logic                  x_pending_lower_valid_q, x_pending_lower_valid_d;
logic                  x_pending_upper_valid_q, x_pending_upper_valid_d;
logic [MX_DATA_W-1:0]  x_pending_lower_q, x_pending_lower_d;
logic [MX_DATA_W-1:0]  x_pending_upper_q, x_pending_upper_d;
logic                  x_pending_lower_exp_valid_q, x_pending_lower_exp_valid_d;
logic                  x_pending_upper_exp_valid_q, x_pending_upper_exp_valid_d;
logic [7:0]            x_pending_lower_exp_q, x_pending_lower_exp_d;
logic [7:0]            x_pending_upper_exp_q, x_pending_upper_exp_d;

logic                  w_pending_lower_valid_q, w_pending_lower_valid_d;
logic                  w_pending_upper_valid_q, w_pending_upper_valid_d;
logic [MX_DATA_W-1:0]  w_pending_lower_q, w_pending_lower_d;
logic [MX_DATA_W-1:0]  w_pending_upper_q, w_pending_upper_d;
logic                  w_pending_lower_exp_valid_q, w_pending_lower_exp_valid_d;
logic                  w_pending_upper_exp_valid_q, w_pending_upper_exp_valid_d;
logic [MX_EXP_VECTOR_W-1:0] w_pending_lower_exp_q, w_pending_lower_exp_d;
logic [MX_EXP_VECTOR_W-1:0] w_pending_upper_exp_q, w_pending_upper_exp_d;

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
logic x_primary_free, x_pending_free;
logic w_primary_free, w_pending_free;
assign x_primary_free = !x_slot_data_valid_q && !x_upper_valid_q;
assign x_pending_free = !x_pending_lower_valid_q && !x_pending_upper_valid_q;
assign w_primary_free = !w_slot_data_valid_q && !w_upper_valid_q;
assign w_pending_free = !w_pending_lower_valid_q && !w_pending_upper_valid_q;

assign x_data_accept = mx_enable_i && x_data_i.valid && (x_primary_free || x_pending_free);
assign w_data_accept = mx_enable_i && w_data_i.valid && (w_primary_free || w_pending_free);

logic x_slot_need_exp, x_upper_need_exp, x_pending_lower_need_exp, x_pending_upper_need_exp;
logic w_slot_need_exp, w_upper_need_exp, w_pending_lower_need_exp, w_pending_upper_need_exp;

assign x_slot_need_exp = x_slot_data_valid_q && !x_slot_exp_valid_q;
assign x_upper_need_exp = x_upper_valid_q && !x_upper_exp_valid_q;
assign x_pending_lower_need_exp = x_pending_lower_valid_q && !x_pending_lower_exp_valid_q;
assign x_pending_upper_need_exp = x_pending_upper_valid_q && !x_pending_upper_exp_valid_q;

assign w_slot_need_exp = w_slot_data_valid_q && !w_slot_exp_valid_q;
assign w_upper_need_exp = w_upper_valid_q && !w_upper_exp_valid_q;
assign w_pending_lower_need_exp = w_pending_lower_valid_q && !w_pending_lower_exp_valid_q;
assign w_pending_upper_need_exp = w_pending_upper_valid_q && !w_pending_upper_exp_valid_q;

assign x_exp_accept = mx_enable_i && x_exp_valid_i && !consume_x_slot_i &&
                      (x_slot_need_exp || x_upper_need_exp ||
                       x_pending_lower_need_exp || x_pending_upper_need_exp);
assign w_exp_accept = mx_enable_i && w_exp_valid_i && !consume_w_slot_i &&
                      (w_slot_need_exp || w_upper_need_exp ||
                       w_pending_lower_need_exp || w_pending_upper_need_exp);

// Ready signals for data streams
assign x_data_i.ready = mx_enable_i ? (x_primary_free || x_pending_free) : 1'b1;
assign w_data_i.ready = mx_enable_i ? (w_primary_free || w_pending_free) : 1'b1;

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
    x_pending_lower_valid_q <= 1'b0;
    x_pending_upper_valid_q <= 1'b0;
    x_pending_lower_q <= '0;
    x_pending_upper_q <= '0;
    x_pending_lower_exp_valid_q <= 1'b0;
    x_pending_upper_exp_valid_q <= 1'b0;
    x_pending_lower_exp_q <= '0;
    x_pending_upper_exp_q <= '0;
    w_pending_lower_valid_q <= 1'b0;
    w_pending_upper_valid_q <= 1'b0;
    w_pending_lower_q <= '0;
    w_pending_upper_q <= '0;
    w_pending_lower_exp_valid_q <= 1'b0;
    w_pending_upper_exp_valid_q <= 1'b0;
    w_pending_lower_exp_q <= '0;
    w_pending_upper_exp_q <= '0;
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
    x_pending_lower_valid_q <= 1'b0;
    x_pending_upper_valid_q <= 1'b0;
    x_pending_lower_q <= '0;
    x_pending_upper_q <= '0;
    x_pending_lower_exp_valid_q <= 1'b0;
    x_pending_upper_exp_valid_q <= 1'b0;
    x_pending_lower_exp_q <= '0;
    x_pending_upper_exp_q <= '0;
    w_pending_lower_valid_q <= 1'b0;
    w_pending_upper_valid_q <= 1'b0;
    w_pending_lower_q <= '0;
    w_pending_upper_q <= '0;
    w_pending_lower_exp_valid_q <= 1'b0;
    w_pending_upper_exp_valid_q <= 1'b0;
    w_pending_lower_exp_q <= '0;
    w_pending_upper_exp_q <= '0;
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
    x_pending_lower_valid_q <= x_pending_lower_valid_d;
    x_pending_upper_valid_q <= x_pending_upper_valid_d;
    x_pending_lower_q <= x_pending_lower_d;
    x_pending_upper_q <= x_pending_upper_d;
    x_pending_lower_exp_valid_q <= x_pending_lower_exp_valid_d;
    x_pending_upper_exp_valid_q <= x_pending_upper_exp_valid_d;
    x_pending_lower_exp_q <= x_pending_lower_exp_d;
    x_pending_upper_exp_q <= x_pending_upper_exp_d;
    w_pending_lower_valid_q <= w_pending_lower_valid_d;
    w_pending_upper_valid_q <= w_pending_upper_valid_d;
    w_pending_lower_q <= w_pending_lower_d;
    w_pending_upper_q <= w_pending_upper_d;
    w_pending_lower_exp_valid_q <= w_pending_lower_exp_valid_d;
    w_pending_upper_exp_valid_q <= w_pending_upper_exp_valid_d;
    w_pending_lower_exp_q <= w_pending_lower_exp_d;
    w_pending_upper_exp_q <= w_pending_upper_exp_d;
  end
end

// Combinational logic
always_comb begin
  x_slot_data_valid_d = x_slot_data_valid_q;
  x_slot_exp_valid_d  = x_slot_exp_valid_q;
  x_slot_data_d  = x_slot_data_q;
  x_slot_exp_d   = x_slot_exp_q;
  x_slot_valid_d = x_slot_data_valid_q && x_slot_exp_valid_q;
  w_slot_data_valid_d = w_slot_data_valid_q;
  w_slot_exp_valid_d  = w_slot_exp_valid_q;
  w_slot_data_d  = w_slot_data_q;
  w_slot_exp_d   = w_slot_exp_q;
  w_slot_valid_d = w_slot_data_valid_q && w_slot_exp_valid_q;
  x_upper_valid_d = x_upper_valid_q;
  x_upper_buffer_d = x_upper_buffer_q;
  x_upper_exp_valid_d = x_upper_exp_valid_q;
  x_upper_exp_d = x_upper_exp_q;
  w_upper_valid_d = w_upper_valid_q;
  w_upper_buffer_d = w_upper_buffer_q;
  w_upper_exp_valid_d = w_upper_exp_valid_q;
  w_upper_exp_d = w_upper_exp_q;
  x_pending_lower_valid_d = x_pending_lower_valid_q;
  x_pending_upper_valid_d = x_pending_upper_valid_q;
  x_pending_lower_d = x_pending_lower_q;
  x_pending_upper_d = x_pending_upper_q;
  x_pending_lower_exp_valid_d = x_pending_lower_exp_valid_q;
  x_pending_upper_exp_valid_d = x_pending_upper_exp_valid_q;
  x_pending_lower_exp_d = x_pending_lower_exp_q;
  x_pending_upper_exp_d = x_pending_upper_exp_q;
  w_pending_lower_valid_d = w_pending_lower_valid_q;
  w_pending_upper_valid_d = w_pending_upper_valid_q;
  w_pending_lower_d = w_pending_lower_q;
  w_pending_upper_d = w_pending_upper_q;
  w_pending_lower_exp_valid_d = w_pending_lower_exp_valid_q;
  w_pending_upper_exp_valid_d = w_pending_upper_exp_valid_q;
  w_pending_lower_exp_d = w_pending_lower_exp_q;
  w_pending_upper_exp_d = w_pending_upper_exp_q;

  // X data acceptance
  if (x_data_accept) begin
    if (x_primary_free) begin
      x_slot_data_valid_d = 1'b1;
      x_slot_data_d = x_unpacked_lower;
      x_slot_exp_valid_d = 1'b0;
      x_upper_valid_d = 1'b1;
      x_upper_buffer_d = x_unpacked_upper;
      x_upper_exp_valid_d = 1'b0;
    end else begin
      x_pending_lower_valid_d = 1'b1;
      x_pending_lower_d = x_unpacked_lower;
      x_pending_lower_exp_valid_d = 1'b0;
      x_pending_upper_valid_d = 1'b1;
      x_pending_upper_d = x_unpacked_upper;
      x_pending_upper_exp_valid_d = 1'b0;
    end
  end

  // X exponent acceptance: route to slot or upper based on which needs it
  // Each 256-bit block (slot and upper) needs its own exponent
  if (x_exp_accept) begin
    if (x_slot_need_exp) begin
      x_slot_exp_valid_d = 1'b1;
      x_slot_exp_d = x_exp_data_i;
    end else if (x_upper_need_exp) begin
      x_upper_exp_valid_d = 1'b1;
      x_upper_exp_d = x_exp_data_i;
    end else if (x_pending_lower_need_exp) begin
      x_pending_lower_exp_valid_d = 1'b1;
      x_pending_lower_exp_d = x_exp_data_i;
    end else if (x_pending_upper_need_exp) begin
      x_pending_upper_exp_valid_d = 1'b1;
      x_pending_upper_exp_d = x_exp_data_i;
    end
  end

  x_slot_valid_d = x_slot_data_valid_d && x_slot_exp_valid_d;

  // W data acceptance
  if (w_data_accept) begin
    if (w_primary_free) begin
      w_slot_data_valid_d = 1'b1;
      w_slot_data_d = w_unpacked_lower;
      w_slot_exp_valid_d = 1'b0;
      w_upper_valid_d = 1'b1;
      w_upper_buffer_d = w_unpacked_upper;
      w_upper_exp_valid_d = 1'b0;
    end else begin
      w_pending_lower_valid_d = 1'b1;
      w_pending_lower_d = w_unpacked_lower;
      w_pending_lower_exp_valid_d = 1'b0;
      w_pending_upper_valid_d = 1'b1;
      w_pending_upper_d = w_unpacked_upper;
      w_pending_upper_exp_valid_d = 1'b0;
    end
  end

  // W exponent acceptance: route to slot or upper based on which needs it
  // Each 256-bit block (slot and upper) needs its own exponent
  if (w_exp_accept) begin
    if (w_slot_need_exp) begin
      w_slot_exp_valid_d = 1'b1;
      w_slot_exp_d = w_exp_data_i;
    end else if (w_upper_need_exp) begin
      w_upper_exp_valid_d = 1'b1;
      w_upper_exp_d = w_exp_data_i;
    end else if (w_pending_lower_need_exp) begin
      w_pending_lower_exp_valid_d = 1'b1;
      w_pending_lower_exp_d = w_exp_data_i;
    end else if (w_pending_upper_need_exp) begin
      w_pending_upper_exp_valid_d = 1'b1;
      w_pending_upper_exp_d = w_exp_data_i;
    end
  end

  w_slot_valid_d = w_slot_data_valid_d && w_slot_exp_valid_d;

  // Slot consumption from arbiter
  // When slot consumed, move upper to slot if available (including its exponent)
  if (consume_x_slot_i) begin
    if (x_upper_valid_q) begin
      x_slot_data_valid_d = 1'b1;
      x_slot_data_d = x_upper_buffer_q;
      x_slot_exp_valid_d = x_upper_exp_valid_q;
      x_slot_exp_d = x_upper_exp_q;
      x_upper_valid_d = 1'b0;
      x_upper_exp_valid_d = 1'b0;
    end else if (x_pending_lower_valid_q) begin
      x_slot_data_valid_d = 1'b1;
      x_slot_data_d = x_pending_lower_q;
      x_slot_exp_valid_d = x_pending_lower_exp_valid_q;
      x_slot_exp_d = x_pending_lower_exp_q;
      x_pending_lower_valid_d = 1'b0;
      x_pending_lower_exp_valid_d = 1'b0;
      x_upper_valid_d = x_pending_upper_valid_q;
      x_upper_buffer_d = x_pending_upper_q;
      x_upper_exp_valid_d = x_pending_upper_exp_valid_q;
      x_upper_exp_d = x_pending_upper_exp_q;
      x_pending_upper_valid_d = 1'b0;
      x_pending_upper_exp_valid_d = 1'b0;
    end else begin
      x_slot_data_valid_d = 1'b0;
      x_slot_exp_valid_d  = 1'b0;
    end
  end

  x_slot_valid_d = x_slot_data_valid_d && x_slot_exp_valid_d;

  if (consume_w_slot_i) begin
    if (w_upper_valid_q) begin
      w_slot_data_valid_d = 1'b1;
      w_slot_data_d = w_upper_buffer_q;
      w_slot_exp_valid_d = w_upper_exp_valid_q;
      w_slot_exp_d = w_upper_exp_q;
      w_upper_valid_d = 1'b0;
      w_upper_exp_valid_d = 1'b0;
    end else if (w_pending_lower_valid_q) begin
      w_slot_data_valid_d = 1'b1;
      w_slot_data_d = w_pending_lower_q;
      w_slot_exp_valid_d = w_pending_lower_exp_valid_q;
      w_slot_exp_d = w_pending_lower_exp_q;
      w_pending_lower_valid_d = 1'b0;
      w_pending_lower_exp_valid_d = 1'b0;
      w_upper_valid_d = w_pending_upper_valid_q;
      w_upper_buffer_d = w_pending_upper_q;
      w_upper_exp_valid_d = w_pending_upper_exp_valid_q;
      w_upper_exp_d = w_pending_upper_exp_q;
      w_pending_upper_valid_d = 1'b0;
      w_pending_upper_exp_valid_d = 1'b0;
    end else begin
      w_slot_data_valid_d = 1'b0;
      w_slot_exp_valid_d  = 1'b0;
    end
  end

  w_slot_valid_d = w_slot_data_valid_d && w_slot_exp_valid_d;
end

endmodule : redmule_mx_slot_buffer
