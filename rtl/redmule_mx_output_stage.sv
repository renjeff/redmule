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
  parameter int unsigned BITW        = 16,
  parameter int unsigned Width       = 32,
  parameter int unsigned Height      = 32,
  parameter int unsigned SysDataWidth = 32
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
  output logic [DATAW/2-1:0]      mx_val_data_o,
  output logic                    mx_exp_valid_o,
  output logic                    mx_exp_ready_o,
  output logic [7:0]              mx_exp_data_o,
  output logic                    fifo_valid_o,
  output logic                    fifo_pop_o,
  output logic [Width*BITW-1:0]   fifo_data_out_o
);

// Engine FIFO signals
logic [Width-1:0][BITW-1:0] fifo_data_out;
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
assign fifo_push = z_engine_stream_i.valid && mx_enable_i && fifo_grant_o;

// Engine FIFO
logic [Width-1:0][BITW-1:0] fifo_data_in;
assign fifo_data_in = z_engine_stream_i.data[Width*BITW-1:0];

redmule_mx_fifo #(
  .DATA_WIDTH ( Width*BITW ),
  .FIFO_DEPTH ( 4          )
) i_engine_fifo (
  .clk_i      ( clk_i            ),
  .rst_ni     ( rst_ni           ),
  .clear_i    ( clear_i          ),
  .push_i     ( fifo_push        ),
  .grant_o    ( fifo_grant_o     ),
  .data_i     ( fifo_data_in     ),
  .pop_i      ( fifo_pop         ),
  .valid_o    ( fifo_valid       ),
  .data_o     ( fifo_data_out    )
);

// MX Encoder signals
logic [DATAW/2-1:0] mx_val_data;  // 256 bits for 32 FP8 elements
logic mx_val_valid, mx_val_ready;
logic [7:0] mx_exp_data;
logic mx_exp_valid, mx_exp_ready;
logic encoder_ready;

// Gate pop with mx_enable AND fifo_valid AND decoder started
assign fifo_pop = encoder_ready && mx_enable_i && fifo_valid;

// MX Encoder
redmule_mx_encoder #(
  .DATA_W    ( DATAW/2 ),  // 256 bits output
  .BITW      ( BITW    ),
  .NUM_LANES ( Width   )
) i_mx_encoder (
  .clk_i          ( clk_i          ),
  .rst_ni         ( rst_ni         ),
  .fp16_valid_i   ( fifo_valid && mx_enable_i ),
  .fp16_ready_o   ( encoder_ready  ),
  .fp16_data_i    ( fifo_data_out  ),
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

// Data stream handshake - provide backpressure when output register full
logic mx_mux_valid_q;
logic [DATAW_ALIGN-1:0] mx_mux_data_q;
logic mx_mux_handshake_done;

assign mx_val_ready = !mx_mux_valid_q || mx_mux_handshake_done;

// MX encoder output packing
logic [DATAW_ALIGN-1:0] mx_z_buffer_data;
assign mx_z_buffer_data = {{(DATAW_ALIGN-256){1'b0}}, mx_val_data};

// Simple valid/data register - latch when encoder produces and we're ready
assign mx_mux_handshake_done = z_muxed_o.valid && z_muxed_o.ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    mx_mux_valid_q <= 1'b0;
    mx_mux_data_q  <= '0;
  end else if (clear_i) begin
    mx_mux_valid_q <= 1'b0;
    mx_mux_data_q  <= '0;
  end else if (mx_val_valid && mx_val_ready) begin
    // Latch when encoder produces and we can accept
    mx_mux_valid_q <= 1'b1;
    mx_mux_data_q  <= mx_z_buffer_data;
  end else if (mx_mux_handshake_done) begin
    mx_mux_valid_q <= 1'b0;  // Clear after successful handshake
  end
end

// MUX: Select between latched MX output and engine bypass
assign z_muxed_o.data  = mx_enable_i ? mx_mux_data_q : z_engine_stream_i.data;
assign z_muxed_o.strb  = mx_enable_i ? {(DATAW_ALIGN/8){1'b1}} : z_engine_stream_i.strb;
assign z_muxed_o.valid = mx_enable_i ? mx_mux_valid_q : z_engine_stream_i.valid;

// Consume z_buffer when MX active, otherwise use backpressure from downstream
assign z_engine_stream_i.ready = mx_enable_i ? fifo_grant_o : z_muxed_o.ready;

endmodule : redmule_mx_output_stage
