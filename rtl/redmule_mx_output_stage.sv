// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// MX Output Stage Module
// Handles engine output buffering, MX encoding, and output muxing

`include "hci_helpers.svh"

module redmule_mx_output_stage
  import redmule_pkg::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned DATAW_ALIGN = 512,
  parameter int unsigned DATAW       = 512,
  parameter int unsigned MX_DATA_W   = 256,
  parameter int unsigned BITW        = 16,
  parameter int unsigned Width       = 32,
  parameter int unsigned Height      = 32,
  parameter int unsigned SysDataWidth = 32,
  parameter int unsigned MX_NUM_LANES = Width
)(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  input  logic mx_enable_i,
  input  logic reg_enable_i,     // Engine is actively computing with valid inputs

  // Engine output
  input  logic [Width-1:0][BITW-1:0] z_engine_data_i,
  hwpe_stream_intf_stream.sink z_engine_stream_i,

  // Engine valid flags for FIFO push
  input  flgs_engine_t flgs_engine_i,
  output logic fifo_grant_o,

  // Muxed output (to Z FIFO)
  hwpe_stream_intf_stream.source z_muxed_o,

  // Exponent stream (to top-level port)
  hwpe_stream_intf_stream.source mx_exp_stream_o,

  // Optional debug visibility signals (tapped by testbench)
  output logic                    mx_val_valid_o,
  output logic                    mx_val_ready_o,
  output logic [MX_DATA_W-1:0]    mx_val_data_o,
  output logic                    mx_exp_valid_o,
  output logic                    mx_exp_ready_o,
  output logic [7:0]              mx_exp_data_o,
  output logic                    fifo_valid_o,
  output logic                    fifo_pop_o,
  output logic [DATAW_ALIGN-1:0]  fifo_data_out_o
);

localparam int unsigned MX_FP16_PER_BEAT = DATAW_ALIGN / BITW;
localparam int unsigned MX_CHUNK_RATIO   = MX_FP16_PER_BEAT / MX_NUM_LANES;
localparam int unsigned MX_CHUNK_WIDTH   = MX_NUM_LANES * BITW;
localparam int unsigned MX_CHUNK_CNT_W   = (MX_CHUNK_RATIO > 1) ? $clog2(MX_CHUNK_RATIO) : 1;
localparam int unsigned MX_CHUNK_COUNT_W = (MX_CHUNK_RATIO > 1) ? $clog2(MX_CHUNK_RATIO + 1) : 1;
localparam int unsigned FIFO_META_W      = 16;
localparam int unsigned FIFO_DATA_W      = DATAW_ALIGN + FIFO_META_W;

initial begin
  if (DATAW_ALIGN % BITW != 0) begin
    $fatal(1, "MX output: DATAW_ALIGN (%0d) must be a multiple of BITW (%0d)", DATAW_ALIGN, BITW);
  end
  if (MX_FP16_PER_BEAT % MX_NUM_LANES != 0) begin
    $fatal(1, "MX output: beat lanes (%0d) must divide evenly by MX_NUM_LANES (%0d)",
           MX_FP16_PER_BEAT, MX_NUM_LANES);
  end
end

// Engine FIFO signals
logic [DATAW_ALIGN-1:0] fifo_data_out;
logic fifo_push, fifo_pop, fifo_valid;

// Delay reg_enable by total pipeline latency
// Includes: systolic array (Height + Width) + MX decoder path + FMA pipeline
// Empirically tuned to align with first valid engine output
localparam int unsigned ENGINE_LATENCY = Height + Width + 55;
logic [ENGINE_LATENCY-1:0] reg_enable_delay_q;
logic reg_enable_delayed;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni)
    reg_enable_delay_q <= '0;
  else if (clear_i)
    reg_enable_delay_q <= '0;
  else
    reg_enable_delay_q <= {reg_enable_delay_q[ENGINE_LATENCY-2:0], reg_enable_i};
end

assign reg_enable_delayed = reg_enable_delay_q[ENGINE_LATENCY-1];

// Push conditions - check if engine has valid output
logic any_pe_valid;
logic [Width-1:0] width_valid;
always_comb begin
  for (int w = 0; w < Width; w++) begin
    width_valid[w] = |flgs_engine_i.out_valid[w]; // OR all Height PEs
  end
  any_pe_valid = |width_valid; // OR all Width stages
end

// Engine FIFO
logic [DATAW_ALIGN-1:0] fifo_data_in_masked;
logic [MX_CHUNK_COUNT_W-1:0] fifo_chunk_count_in, fifo_chunk_count_out;
logic [FIFO_DATA_W-1:0] fifo_data_in, fifo_data_out_full;

always_comb begin
  fifo_data_in_masked = '0;
  for (int byte_idx = 0; byte_idx < DATAW_ALIGN/8; byte_idx++) begin
    fifo_data_in_masked[8*byte_idx +: 8] =
      z_engine_stream_i.strb[byte_idx] ? z_engine_stream_i.data[8*byte_idx +: 8] : 8'h00;
  end
end

always_comb begin
  fifo_chunk_count_in = '0;
  for (int chunk = 0; chunk < MX_CHUNK_RATIO; chunk++) begin
    if (|z_engine_stream_i.strb[(MX_CHUNK_WIDTH/8)*chunk +: (MX_CHUNK_WIDTH/8)]) begin
      fifo_chunk_count_in = fifo_chunk_count_in + 1'b1;
    end
  end
end

assign fifo_push = z_engine_stream_i.valid && mx_enable_i && fifo_grant_o && (fifo_chunk_count_in != '0);
assign fifo_data_in = {{(FIFO_META_W-MX_CHUNK_COUNT_W){1'b0}}, fifo_chunk_count_in, fifo_data_in_masked};

redmule_mx_fifo #(
  .DATA_WIDTH ( FIFO_DATA_W ),
  .FIFO_DEPTH ( 32          ) // =z_width  decouple Z drain from MX serialization
) i_engine_fifo (
  .clk_i      ( clk_i            ),
  .rst_ni     ( rst_ni           ),
  .clear_i    ( clear_i          ),
  .push_i     ( fifo_push        ),
  .grant_o    ( fifo_grant_o     ),
  .data_i     ( fifo_data_in     ),
  .pop_i      ( fifo_pop         ),
  .valid_o    ( fifo_valid       ),
  .data_o     ( fifo_data_out_full )
);

assign fifo_data_out      = fifo_data_out_full[DATAW_ALIGN-1:0];
assign fifo_chunk_count_out = fifo_data_out_full[DATAW_ALIGN +: MX_CHUNK_COUNT_W];

// MX Encoder signals
logic [MX_DATA_W-1:0] mx_val_data;  // 256 bits for 32 FP8 elements
logic mx_val_valid, mx_val_ready;
logic [7:0] mx_exp_data;
logic mx_exp_valid, mx_exp_ready;
logic encoder_ready;

logic [DATAW_ALIGN-1:0] block_data_q;
logic block_valid_q;
logic [MX_CHUNK_CNT_W-1:0] chunk_index_q;
logic [MX_CHUNK_COUNT_W-1:0] block_chunk_count_q;
logic load_block;

assign load_block = mx_enable_i && fifo_valid && !block_valid_q;
assign fifo_pop   = load_block;

logic [MX_CHUNK_WIDTH-1:0] encoder_chunk;
assign encoder_chunk = block_data_q[MX_CHUNK_WIDTH*chunk_index_q +: MX_CHUNK_WIDTH];

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    block_valid_q <= 1'b0;
    block_data_q  <= '0;
    chunk_index_q <= '0;
    block_chunk_count_q <= '0;
  end else if (clear_i || !mx_enable_i) begin
    block_valid_q <= 1'b0;
    block_data_q  <= '0;
    chunk_index_q <= '0;
    block_chunk_count_q <= '0;
  end else begin
    if (load_block) begin
      block_valid_q <= 1'b1;
      block_data_q  <= fifo_data_out;
      chunk_index_q <= '0;
      block_chunk_count_q <= (fifo_chunk_count_out == '0) ? {{(MX_CHUNK_COUNT_W-1){1'b0}}, 1'b1}
                                                           : fifo_chunk_count_out;
    end else if (block_valid_q && encoder_ready) begin
      if ((chunk_index_q + 1'b1) >= block_chunk_count_q) begin
        block_valid_q <= 1'b0;
        chunk_index_q <= '0;
      end else begin
        chunk_index_q <= chunk_index_q + 1'b1;
      end
    end
  end
end

// MX Encoder
redmule_mx_encoder #(
  .DATA_W    ( MX_DATA_W ),
  .BITW      ( BITW    ),
  .NUM_LANES ( MX_NUM_LANES )
) i_mx_encoder (
  .clk_i          ( clk_i          ),
  .rst_ni         ( rst_ni         ),
  .fp16_valid_i   ( block_valid_q  ),
  .fp16_ready_o   ( encoder_ready  ),
  .fp16_data_i    ( encoder_chunk  ),
  .mx_val_valid_o ( mx_val_valid   ),
  .mx_val_ready_i ( mx_val_ready   ),
  .mx_val_data_o  ( mx_val_data    ),
  .mx_exp_valid_o ( mx_exp_valid   ),
  .mx_exp_ready_i ( mx_exp_ready   ),
  .mx_exp_data_o  ( mx_exp_data    )
);

// Exponent streaming
assign mx_exp_stream_o.valid = mx_exp_valid;
assign mx_exp_stream_o.data  = {{(DATAW_ALIGN-8){1'b0}}, mx_exp_data};
assign mx_exp_stream_o.strb  = '1;
assign mx_exp_ready = mx_exp_stream_o.ready;

// Debug/export wiring for MX instrumentation
assign fifo_valid_o     = fifo_valid;
assign fifo_pop_o       = fifo_pop;
assign fifo_data_out_o  = fifo_data_out;
assign mx_val_valid_o   = mx_val_valid;
assign mx_val_ready_o   = mx_val_ready;
assign mx_val_data_o    = mx_val_data;
assign mx_exp_valid_o   = mx_exp_valid;
assign mx_exp_ready_o   = mx_exp_ready;
assign mx_exp_data_o    = mx_exp_data;

// MX encoder output packing: collect DATAW_ALIGN/MX_DATA_W blocks per beat
localparam int unsigned MX_BLOCK_WIDTH  = MX_DATA_W;
localparam int unsigned MX_BLOCK_BYTES  = MX_DATA_W/8;
localparam int unsigned BLOCKS_PER_BEAT = DATAW_ALIGN / MX_BLOCK_WIDTH;
localparam int unsigned BLOCK_CNT_W     = (BLOCKS_PER_BEAT > 1) ? $clog2(BLOCKS_PER_BEAT) : 1;
localparam int unsigned TOTAL_BYTES     = DATAW_ALIGN/8;

logic [DATAW_ALIGN-1:0] pack_data_q, pack_data_d;
logic [TOTAL_BYTES-1:0] pack_strb_q, pack_strb_d;
logic [BLOCK_CNT_W-1:0] pack_count_q, pack_count_d;
logic                   pack_valid_q, pack_valid_d;
logic                   mx_enable_q;
logic                   mx_mode_q;
logic                   mx_active;
logic                   pack_ready;

// Keep encoder backpressure local to this stage.
// Using z_muxed_o.ready here creates a combinational loop via z_buffer ready/control.
assign pack_ready  = !pack_valid_q;
assign mx_val_ready = pack_ready;

// Track MX enable to flush leftover blocks when the job ends
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    mx_enable_q <= 1'b0;
    mx_mode_q   <= 1'b0;
  end else if (clear_i) begin
    mx_enable_q <= 1'b0;
    mx_mode_q   <= 1'b0;
  end else begin
    mx_enable_q <= mx_enable_i;
    if (mx_enable_i) begin
      mx_mode_q <= 1'b1;
    end
  end
end

assign mx_active = mx_mode_q || mx_enable_i || pack_valid_q || (pack_count_q != '0) || block_valid_q;

logic flush_partial;
assign flush_partial = (pack_count_q != '0) && !pack_valid_q && !mx_enable_i && mx_enable_q;

always_comb begin
  pack_data_d  = pack_data_q;
  pack_strb_d  = pack_strb_q;
  pack_count_d = pack_count_q;
  pack_valid_d = pack_valid_q;

  if (pack_valid_q && z_muxed_o.ready && mx_active) begin
    pack_valid_d = 1'b0;
  end

  if (mx_val_valid && mx_val_ready) begin
    if (pack_count_q == '0) begin
      pack_data_d = '0;
      pack_strb_d = '0;
    end
    pack_data_d[MX_BLOCK_WIDTH*pack_count_q +: MX_BLOCK_WIDTH] = mx_val_data;
    pack_strb_d[MX_BLOCK_BYTES*pack_count_q +: MX_BLOCK_BYTES] = {MX_BLOCK_BYTES{1'b1}};
    if (pack_count_q == BLOCKS_PER_BEAT-1) begin
      pack_valid_d = 1'b1;
      pack_count_d = '0;
    end else begin
      pack_count_d = pack_count_q + 1'b1;
    end
  end

  if (flush_partial) begin
    pack_valid_d = 1'b1;
    pack_count_d = '0;
  end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    pack_data_q  <= '0;
    pack_strb_q  <= '0;
    pack_count_q <= '0;
    pack_valid_q <= 1'b0;
  end else if (clear_i) begin
    pack_data_q  <= '0;
    pack_strb_q  <= '0;
    pack_count_q <= '0;
    pack_valid_q <= 1'b0;
  end else begin
    pack_data_q  <= pack_data_d;
    pack_strb_q  <= pack_strb_d;
    pack_count_q <= pack_count_d;
    pack_valid_q <= pack_valid_d;
  end
end

// MUX: Select between latched MX output and engine bypass
assign z_muxed_o.data  = mx_active ? pack_data_q : z_engine_stream_i.data;
assign z_muxed_o.strb  = mx_active ? pack_strb_q : z_engine_stream_i.strb;
assign z_muxed_o.valid = mx_active ? pack_valid_q : z_engine_stream_i.valid;

// Consume z_buffer when MX active, otherwise use backpressure from downstream
assign z_engine_stream_i.ready = mx_active ? fifo_grant_o : z_muxed_o.ready;

endmodule : redmule_mx_output_stage
