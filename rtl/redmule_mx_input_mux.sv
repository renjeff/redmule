// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// MX Input Mux Module
// Muxes between MX-decoded and FP16 bypass for X/W input streams

`include "hci_helpers.svh"

module redmule_mx_input_mux
  import redmule_pkg::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned DATAW_ALIGN = 512,
  parameter int unsigned BITW        = 16,
  parameter int unsigned MX_NUM_LANES = 32
)(
  input  logic mx_enable_i,

  // Input from arbiter (which stream is being decoded)
  input  logic target_is_x_i,
  input  logic target_is_w_i,

  // Raw streams from streamer (bypass path)
  hwpe_stream_intf_stream.sink x_raw_i,
  hwpe_stream_intf_stream.sink w_raw_i,

  // Decoded streams from decoder
  input  logic x_decoded_valid_i,
  input  logic w_decoded_valid_i,
  output logic x_decoded_ready_o,
  output logic w_decoded_ready_o,
  input  logic [MX_NUM_LANES*BITW-1:0] x_decoded_data_i,
  input  logic [MX_NUM_LANES*BITW-1:0] w_decoded_data_i,

  // Muxed outputs (to data FIFOs)
  hwpe_stream_intf_stream.source x_muxed_o,
  hwpe_stream_intf_stream.source w_muxed_o
);

// X mux logic
// When MX disabled: pass through x_raw directly
// When MX enabled and decoder is outputting X: use decoded output
// When MX enabled but not outputting X: invalid (block)
assign x_muxed_o.valid = mx_enable_i ? (target_is_x_i ? x_decoded_valid_i : 1'b0) : x_raw_i.valid;
assign x_muxed_o.data  = mx_enable_i ? x_decoded_data_i : x_raw_i.data;
assign x_muxed_o.strb  = mx_enable_i ? {(DATAW_ALIGN/8){1'b1}} : x_raw_i.strb;

// W mux logic
// When MX disabled: pass through w_raw directly
// When MX enabled and decoder is outputting W: use decoded output
// When MX enabled but not outputting W: invalid (block)
assign w_muxed_o.valid = mx_enable_i ? (target_is_w_i ? w_decoded_valid_i : 1'b0) : w_raw_i.valid;
assign w_muxed_o.data  = mx_enable_i ? w_decoded_data_i : w_raw_i.data;
assign w_muxed_o.strb  = mx_enable_i ? {(DATAW_ALIGN/8){1'b1}} : w_raw_i.strb;

// Ready signals
// When MX enabled: ready comes from decoder path
// When MX disabled: ready comes from downstream FIFO
assign x_decoded_ready_o = target_is_x_i ? x_muxed_o.ready : 1'b0;
assign w_decoded_ready_o = target_is_w_i ? w_muxed_o.ready : 1'b0;

// Raw stream ready handled by slot_buffer module (not here)
assign x_raw_i.ready = mx_enable_i ? 1'b0 : x_muxed_o.ready;
assign w_raw_i.ready = mx_enable_i ? 1'b0 : w_muxed_o.ready;

endmodule : redmule_mx_input_mux
