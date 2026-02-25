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
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  input  logic mx_enable_i,

  // Input from arbiter (which stream is being decoded)
  input  logic target_is_x_i,
  input  logic target_is_w_i,
  input  logic [7:0] x_row_chunks_i,
  input  logic [7:0] w_row_chunks_i,

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

localparam int unsigned OUTPUT_NUM_LANES = DATAW_ALIGN / BITW;
localparam int unsigned CHUNK_WIDTH      = MX_NUM_LANES * BITW;
localparam int unsigned PACK_RATIO       = OUTPUT_NUM_LANES / MX_NUM_LANES;
localparam int unsigned PACK_CNT_W       = (PACK_RATIO > 1) ? $clog2(PACK_RATIO) : 1;
localparam int unsigned ROW_CNT_W        = (PACK_RATIO > 1) ? $clog2(PACK_RATIO + 1) : 1;
localparam int unsigned STRB_WIDTH       = DATAW_ALIGN / 8;

initial begin
  if (DATAW_ALIGN % BITW != 0) begin
    $fatal(1, "MX input mux: DATAW_ALIGN (%0d) must be multiple of BITW (%0d)", DATAW_ALIGN, BITW);
  end
  if (OUTPUT_NUM_LANES % MX_NUM_LANES != 0) begin
    $fatal(1, "MX input mux: beat lanes (%0d) must be divisible by MX_NUM_LANES (%0d)",
           OUTPUT_NUM_LANES, MX_NUM_LANES);
  end
end

logic [DATAW_ALIGN-1:0]      x_pack_data_q, x_pack_data_d;
logic [DATAW_ALIGN-1:0]      w_pack_data_q, w_pack_data_d;
logic [PACK_CNT_W-1:0]       x_pack_count_q, w_pack_count_q;
logic [PACK_CNT_W-1:0]       x_pack_count_d, w_pack_count_d;
logic [ROW_CNT_W-1:0]        x_row_chunks_eff, w_row_chunks_eff;
logic                        x_pack_valid_q, w_pack_valid_q;
logic                        x_pack_valid_d, w_pack_valid_d;

logic                        x_accept_chunk, w_accept_chunk;
logic                        x_ready_for_chunk, w_ready_for_chunk;

assign x_row_chunks_eff = (x_row_chunks_i == '0) ? ROW_CNT_W'(1) :
                          (x_row_chunks_i > PACK_RATIO) ? ROW_CNT_W'(PACK_RATIO) :
                          ROW_CNT_W'(x_row_chunks_i);
assign w_row_chunks_eff = (w_row_chunks_i == '0) ? ROW_CNT_W'(1) :
                          (w_row_chunks_i > PACK_RATIO) ? ROW_CNT_W'(PACK_RATIO) :
                          ROW_CNT_W'(w_row_chunks_i);

assign x_ready_for_chunk = !x_pack_valid_q || x_muxed_o.ready;
assign w_ready_for_chunk = !w_pack_valid_q || w_muxed_o.ready;

assign x_decoded_ready_o = (mx_enable_i && target_is_x_i) ? x_ready_for_chunk : 1'b0;
assign w_decoded_ready_o = (mx_enable_i && target_is_w_i) ? w_ready_for_chunk : 1'b0;

assign x_accept_chunk = mx_enable_i && target_is_x_i && x_decoded_valid_i && x_decoded_ready_o;
assign w_accept_chunk = mx_enable_i && target_is_w_i && w_decoded_valid_i && w_decoded_ready_o;

always_comb begin
  x_pack_data_d  = x_pack_data_q;
  x_pack_count_d = x_pack_count_q;
  x_pack_valid_d = x_pack_valid_q;

  if (x_pack_valid_q && x_muxed_o.ready) begin
    x_pack_valid_d = 1'b0;
  end

  if (x_accept_chunk) begin
    if (x_pack_count_q == '0) begin
      x_pack_data_d = '0;
    end
    x_pack_data_d[CHUNK_WIDTH*x_pack_count_q +: CHUNK_WIDTH] = x_decoded_data_i;
    if ((x_pack_count_q + 1'b1) == x_row_chunks_eff) begin
      x_pack_valid_d = 1'b1;
      x_pack_count_d = '0;
    end else begin
      x_pack_count_d = x_pack_count_q + 1'b1;
    end
  end
end

always_comb begin
  w_pack_data_d  = w_pack_data_q;
  w_pack_count_d = w_pack_count_q;
  w_pack_valid_d = w_pack_valid_q;

  if (w_pack_valid_q && w_muxed_o.ready) begin
    w_pack_valid_d = 1'b0;
  end

  if (w_accept_chunk) begin
    if (w_pack_count_q == '0) begin
      w_pack_data_d = '0;
    end
    w_pack_data_d[CHUNK_WIDTH*w_pack_count_q +: CHUNK_WIDTH] = w_decoded_data_i;
    if ((w_pack_count_q + 1'b1) == w_row_chunks_eff) begin
      w_pack_valid_d = 1'b1;
      w_pack_count_d = '0;
    end else begin
      w_pack_count_d = w_pack_count_q + 1'b1;
    end
  end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    x_pack_data_q  <= '0;
    x_pack_count_q <= '0;
    x_pack_valid_q <= 1'b0;
    w_pack_data_q  <= '0;
    w_pack_count_q <= '0;
    w_pack_valid_q <= 1'b0;
  end else if (clear_i || !mx_enable_i) begin
    x_pack_data_q  <= '0;
    x_pack_count_q <= '0;
    x_pack_valid_q <= 1'b0;
    w_pack_data_q  <= '0;
    w_pack_count_q <= '0;
    w_pack_valid_q <= 1'b0;
  end else begin
    x_pack_data_q  <= x_pack_data_d;
    x_pack_count_q <= x_pack_count_d;
    x_pack_valid_q <= x_pack_valid_d;
    w_pack_data_q  <= w_pack_data_d;
    w_pack_count_q <= w_pack_count_d;
    w_pack_valid_q <= w_pack_valid_d;
  end
end

// Output muxing
assign x_muxed_o.valid = mx_enable_i ? x_pack_valid_q : x_raw_i.valid;
assign x_muxed_o.data  = mx_enable_i ? x_pack_data_q  : x_raw_i.data;
assign x_muxed_o.strb  = mx_enable_i ? {STRB_WIDTH{1'b1}} : x_raw_i.strb;
assign x_raw_i.ready   = mx_enable_i ? 1'b0 : x_muxed_o.ready;

assign w_muxed_o.valid = mx_enable_i ? w_pack_valid_q : w_raw_i.valid;
assign w_muxed_o.data  = mx_enable_i ? w_pack_data_q  : w_raw_i.data;
assign w_muxed_o.strb  = mx_enable_i ? {STRB_WIDTH{1'b1}} : w_raw_i.strb;
assign w_raw_i.ready   = mx_enable_i ? 1'b0 : w_muxed_o.ready;

endmodule : redmule_mx_input_mux
