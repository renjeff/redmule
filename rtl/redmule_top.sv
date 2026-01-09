// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
//

`include "hci_helpers.svh"

module redmule_top
  import cv32e40x_pkg::*;
  import fpnew_pkg::*;
  import redmule_pkg::*;
  import hci_package::*;
  import hwpe_ctrl_package::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned  ID_WIDTH           = 8                 ,
  parameter int unsigned  N_CORES            = 8                 ,
  parameter int unsigned  DW                 = DATA_W            , // TCDM port dimension (in bits)
  parameter int unsigned  UW                 = 1                 ,
  parameter int unsigned  X_EXT              = 0                 ,
  parameter int unsigned  SysInstWidth       = 32                ,
  parameter int unsigned  SysDataWidth       = 32                ,
  parameter int unsigned  NumContext         = N_CONTEXT         , // Number of sequential jobs for the slave device
  parameter fp_format_e   FpFormat           = FPFORMAT          , // Data format (default is FP16)
  parameter int unsigned  Height             = ARRAY_HEIGHT      , // Number of PEs within a row
  parameter int unsigned  Width              = ARRAY_WIDTH       , // Number of parallel rows
  parameter int unsigned  NumPipeRegs        = PIPE_REGS         , // Number of pipeline registers within each PE
  parameter pipe_config_t PipeConfig         = DISTRIBUTED       ,
  parameter int unsigned  BITW               = fp_width(FpFormat),  // Number of bits for the given format
  parameter hci_size_parameter_t `HCI_SIZE_PARAM(tcdm) = '0
)(
  input  logic                    clk_i      ,
  input  logic                    rst_ni     ,
  input  logic                    test_mode_i,
  output logic                    busy_o     ,
  output logic [N_CORES-1:0][1:0] evt_o      ,
  cv32e40x_if_xif.coproc_issue    xif_issue_if_i,
  cv32e40x_if_xif.coproc_result   xif_result_if_o,
  cv32e40x_if_xif.coproc_compressed xif_compressed_if_i,
  cv32e40x_if_xif.coproc_mem        xif_mem_if_o,
  // Periph slave port for the controller side
  hwpe_ctrl_intf_periph.slave periph,
  // TCDM master ports for the memory side
  hci_core_intf.initiator tcdm,
  // MX shared exponent output stream (separate from data)
  hwpe_stream_intf_stream.source mx_exp_stream,
  // MX shared exponent input streams for X and W decoders
  hwpe_stream_intf_stream.sink x_mx_exp_stream,
  hwpe_stream_intf_stream.sink w_mx_exp_stream
);

localparam int unsigned DATAW_ALIGN = `HCI_SIZE_GET_DW(tcdm) - SysDataWidth;
localparam int unsigned HCI_ECC = (`HCI_SIZE_GET_EW(tcdm)>1);

logic                       enable, clear;
logic                       reg_enable;
logic                       start_cfg, cfg_complete;

hwpe_ctrl_intf_periph #( .ID_WIDTH  (ID_WIDTH) ) local_periph ( .clk(clk_i) );

if (!X_EXT) begin: gen_periph_connection
  /* If there is no Xif we directly plug the
     control port into the hwpe-slave device */
  assign start_cfg = ((periph.req) &&
                      (periph.add[7:0] == 'h54) &&
                      (!periph.wen) && (periph.gnt)) ? 1'b1 : 1'b0;

  // Bind periph port to local one
  assign local_periph.req  = periph.req;
  assign local_periph.add  = periph.add;
  assign local_periph.wen  = periph.wen;
  assign local_periph.be   = periph.be;
  assign local_periph.data = periph.data;
  assign local_periph.id   = periph.id;
  assign periph.gnt     = local_periph.gnt;
  assign periph.r_data  = local_periph.r_data;
  assign periph.r_valid = local_periph.r_valid;
  assign periph.r_id    = local_periph.r_id;
  // Kill Xif
  assign xif_issue_if_i.issue_ready = '0;
  assign xif_issue_if_i.issue_resp  = '0;
  assign xif_result_if_o.result_valid = '0;
  assign xif_result_if_o.result       = '0;
  assign xif_compressed_if_i.compressed_ready = '0;
  assign xif_compressed_if_i.compressed_resp  = '0;
  assign xif_mem_if_o.mem_valid = '0;
  assign xif_mem_if_o.mem_req   = '0;

end else begin: gen_xif_decoder
  /* If there is the Xif, we pass through the
     instruction decoder and then enter into
     the hwpe slave device */
  logic [SysDataWidth-1:0] cfg_reg;
  logic [SysDataWidth-1:0] sizem, sizen, sizek;
  logic [SysDataWidth-1:0] x_addr, w_addr, y_addr, z_addr;

  redmule_inst_decoder #(
    .SysInstWidth       ( SysInstWidth       ),
    .SysDataWidth       ( SysDataWidth       ),
    .NumRfReadPrts      ( 3                  ) // FIXME: parametric
  ) i_inst_decoder      (
    .clk_i               ( clk_i               ),
    .rst_ni              ( rst_ni              ),
    .clear_i             ( clear               ),
    .xif_issue_if_i      ( xif_issue_if_i      ),
    .xif_result_if_o     ( xif_result_if_o     ),
    .xif_compressed_if_i ( xif_compressed_if_i ),
    .xif_mem_if_o        ( xif_mem_if_o        ),
    .periph              ( local_periph        ),
    .cfg_complete_i      ( cfg_complete        ),
    .start_cfg_o         ( start_cfg           )
  );
  // Kill periph bus
  assign periph.gnt     = '0;
  assign periph.r_data  = '0;
  assign periph.r_valid = '0;
  assign periph.r_id    = '0;
end

// Streamer control signals, flags and ecc info
cntrl_streamer_t cntrl_streamer;
flgs_streamer_t  flgs_streamer;
errs_streamer_t  ecc_errors_streamer;

cntrl_engine_t   cntrl_engine;

// Wrapper control signals and flags
// Input feature map
x_buffer_ctrl_t x_buffer_ctrl;
x_buffer_flgs_t x_buffer_flgs;

// Weights
w_buffer_ctrl_t w_buffer_ctrl;
w_buffer_flgs_t w_buffer_flgs;

// Output feature map
z_buffer_ctrl_t z_buffer_ctrl;
z_buffer_flgs_t z_buffer_flgs;

// FSM control signals and flags
cntrl_scheduler_t cntrl_scheduler;
flgs_scheduler_t  flgs_scheduler;

// Register file binded from controller to FSM
ctrl_regfile_t reg_file;
flags_fifo_t   w_fifo_flgs, z_fifo_flgs;
cntrl_flags_t  cntrl_flags;

/*--------------------------------------------------------------*/
/* |                         Streamer                         | */
/*--------------------------------------------------------------*/

// Implementation of the incoming and outgoing streaming interfaces (one for each kind of data)

// X streaming interface + X FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_d         ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_muxed     ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_fifo      ( .clk( clk_i ) );

// W streaming interface + W FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_buffer_d         ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_buffer_muxed     ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_buffer_fifo      ( .clk( clk_i ) );

// Y streaming interface + Y FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) y_buffer_d         ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) y_buffer_fifo      ( .clk( clk_i ) );

// Z streaming interface + Z FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) z_buffer_q         ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) z_buffer_fifo      ( .clk( clk_i ) );

// MX encoder output signals (forward declaration for mux)
logic [DATAW_ALIGN-1:0] mx_z_buffer_data;
logic mx_val_valid;
logic mx_enable;
logic fifo_grant;  // Forward declaration for encoder FIFO backpressure

// The streamer will present a single master TCDM port used to stream data to and from the memeory.
redmule_streamer #(
  .`HCI_SIZE_PARAM(tcdm) ( `HCI_SIZE_PARAM(tcdm) )
) i_streamer      (
  .clk_i           ( clk_i               ),
  .rst_ni          ( rst_ni              ),
  .test_mode_i     ( test_mode_i         ),
  // Controller generated signals
  .enable_i        ( 1'b1                ),
  .clear_i         ( clear               ),
  // Source interfaces for the incoming streams
  .x_stream_o      ( x_buffer_d          ),
  .w_stream_o      ( w_buffer_d          ),
  .y_stream_o      ( y_buffer_d          ),
  // Sink interface for the outgoing stream
  .z_stream_i      ( z_buffer_fifo       ),
  // Master TCDM interface ports for the memory side
  .tcdm            ( tcdm                ),
  .ecc_errors_o    ( ecc_errors_streamer ),
  .ctrl_i          ( cntrl_streamer      ),
  .flags_o         ( flgs_streamer       )
);

/*---------------------------------------------------------------*/
/* |                   MX DECODERS (INPUT SIDE)                | */
/*---------------------------------------------------------------*/

// MX decoder parameters
localparam int unsigned MX_DATA_W = 256;  // 32 FP8 elements
localparam int unsigned MX_NUM_LANES = Width;  // Process Width elements per cycle

// X decoder signals
logic x_mx_fp16_valid, x_mx_fp16_ready;
logic [MX_NUM_LANES*BITW-1:0] x_mx_fp16_data;
logic x_mx_val_ready;  // Backpressure from X decoder

// W decoder signals  
logic w_mx_fp16_valid, w_mx_fp16_ready;
logic [MX_NUM_LANES*BITW-1:0] w_mx_fp16_data;
logic w_mx_val_ready;  // Backpressure from W decoder

// MX Decoder for X data (single broadcast shared exponent)
redmule_mx_decoder_x #(
  .DATA_W    ( MX_DATA_W    ),
  .BITW      ( BITW         ),
  .NUM_LANES ( MX_NUM_LANES )
) i_mx_decoder_x (
  .clk_i          ( clk_i                        ),
  .rst_ni         ( rst_ni                       ),
  .mx_val_valid_i ( x_buffer_d.valid && mx_enable ),
  .mx_val_ready_o ( x_mx_val_ready               ),
  .mx_val_data_i  ( x_buffer_d.data[MX_DATA_W-1:0] ),
  .mx_exp_valid_i ( x_mx_exp_stream.valid        ),
  .mx_exp_ready_o ( x_mx_exp_stream.ready        ),
  .mx_exp_data_i  ( x_mx_exp_stream.data[7:0]    ),
  .fp16_valid_o   ( x_mx_fp16_valid              ),
  .fp16_ready_i   ( x_mx_fp16_ready              ),
  .fp16_data_o    ( x_mx_fp16_data               )
);

// MX Decoder for W data (vector of per-group shared exponents)
redmule_mx_decoder_w #(
  .DATA_W    ( MX_DATA_W    ),
  .BITW      ( BITW         ),
  .NUM_LANES ( MX_NUM_LANES )
) i_mx_decoder_w (
  .clk_i          ( clk_i                              ),
  .rst_ni         ( rst_ni                             ),
  .mx_val_valid_i ( w_buffer_d.valid && mx_enable      ),
  .mx_val_ready_o ( w_mx_val_ready                     ),
  .mx_val_data_i  ( w_buffer_d.data[MX_DATA_W-1:0]     ),
  .mx_exp_valid_i ( w_mx_exp_stream.valid              ),
  .mx_exp_ready_o ( w_mx_exp_stream.ready              ),
  .mx_exp_data_i  ( w_mx_exp_stream.data[MX_NUM_LANES*8-1:0] ),
  .fp16_valid_o   ( w_mx_fp16_valid                    ),
  .fp16_ready_i   ( w_mx_fp16_ready                    ),
  .fp16_data_o    ( w_mx_fp16_data                     )
);

// MX input mux for X data: Select between MX decoded and direct bypass
// When MX disabled: pass through x_buffer_d directly
// When MX enabled: use decoded FP16 output, pack into DATAW_ALIGN width
assign x_buffer_muxed.valid = mx_enable ? x_mx_fp16_valid : x_buffer_d.valid;
assign x_buffer_muxed.data  = mx_enable ? {{(DATAW_ALIGN-MX_NUM_LANES*BITW){1'b0}}, x_mx_fp16_data} : x_buffer_d.data;
assign x_buffer_muxed.strb  = mx_enable ? {(DATAW_ALIGN/8){1'b1}} : x_buffer_d.strb;
assign x_buffer_d.ready     = mx_enable ? x_mx_val_ready : x_buffer_muxed.ready;  // Use decoder backpressure
assign x_mx_fp16_ready      = x_buffer_muxed.ready;

// MX input mux for W data: Select between MX decoded and direct bypass
assign w_buffer_muxed.valid = mx_enable ? w_mx_fp16_valid : w_buffer_d.valid;
assign w_buffer_muxed.data  = mx_enable ? {{(DATAW_ALIGN-MX_NUM_LANES*BITW){1'b0}}, w_mx_fp16_data} : w_buffer_d.data;
assign w_buffer_muxed.strb  = mx_enable ? {(DATAW_ALIGN/8){1'b1}} : w_buffer_d.strb;
assign w_buffer_d.ready     = mx_enable ? w_mx_val_ready : w_buffer_muxed.ready;  // Use decoder backpressure
assign w_mx_fp16_ready      = w_buffer_muxed.ready;

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DATAW_ALIGN   ),
  .FIFO_DEPTH     ( 4             )
) i_x_buffer_fifo (
  .clk_i          ( clk_i           ),
  .rst_ni         ( rst_ni          ),
  .clear_i        ( clear           ),
  .flags_o        (                 ),
  .push_i         ( x_buffer_muxed  ),
  .pop_o          ( x_buffer_fifo   )
);

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DATAW_ALIGN   ),
  .FIFO_DEPTH     ( 4             )
) i_w_buffer_fifo (
  .clk_i          ( clk_i           ),
  .rst_ni         ( rst_ni          ),
  .clear_i        ( clear           ),
  .flags_o        ( w_fifo_flgs     ),
  .push_i         ( w_buffer_muxed  ),
  .pop_o          ( w_buffer_fifo   )
);

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DATAW_ALIGN   ),
  .FIFO_DEPTH     ( 4             )
) i_y_buffer_fifo (
  .clk_i          ( clk_i         ),
  .rst_ni         ( rst_ni        ),
  .clear_i        ( clear         ),
  .flags_o        (               ),
  .push_i         ( y_buffer_d    ),
  .pop_o          ( y_buffer_fifo )
);

// MX bypass: Mux between z_buffer output and MX encoder output at 512-bit bus level
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) z_buffer_muxed ( .clk( clk_i ) );

// Handshake-safe MX mux logic
// Hold valid AND data stable until ready is received (HWPE stream protocol)
logic mx_mux_valid_q;
logic [DATAW_ALIGN-1:0] mx_mux_data_q;
logic mx_mux_handshake_done;

assign mx_mux_handshake_done = z_buffer_muxed.valid && z_buffer_muxed.ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    mx_mux_valid_q <= 1'b0;
    mx_mux_data_q  <= '0;
  end else if (clear) begin
    mx_mux_valid_q <= 1'b0;
    mx_mux_data_q  <= '0;
  end else if (mx_mux_handshake_done) begin
    mx_mux_valid_q <= 1'b0;  // Clear after successful handshake
  end else if (mx_enable && mx_val_valid && !mx_mux_valid_q) begin
    mx_mux_valid_q <= 1'b1;  // Latch valid when MX encoder outputs
    mx_mux_data_q  <= mx_z_buffer_data;  // Latch data too
  end
end

// MUX: Select between engine output (bypass) and MX encoder output
// When MX enabled and holding: use latched data to prevent protocol violations
assign z_buffer_muxed.data  = mx_enable ? (mx_mux_valid_q ? mx_mux_data_q : mx_z_buffer_data) : z_buffer_q.data;
assign z_buffer_muxed.strb  = mx_enable ? {(DATAW_ALIGN/8){1'b1}} : z_buffer_q.strb;
assign z_buffer_muxed.valid = mx_enable ? (mx_val_valid || mx_mux_valid_q) : z_buffer_q.valid;
assign z_buffer_q.ready     = mx_enable ? 1'b1 : z_buffer_muxed.ready; // Consume z_buffer when MX active

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DATAW_ALIGN   ),
  .FIFO_DEPTH     ( 2             )
) i_z_buffer_fifo (
  .clk_i          ( clk_i         ),
  .rst_ni         ( rst_ni        ),
  .clear_i        ( clear         ),
  .flags_o        ( z_fifo_flgs   ),
  .push_i         ( z_buffer_muxed ),
  .pop_o          ( z_buffer_fifo )
);

// Valid/Ready assignment
assign x_buffer_fifo.ready = x_buffer_ctrl.load;
assign w_buffer_fifo.ready = w_buffer_flgs.w_ready;

assign y_buffer_fifo.ready = z_buffer_flgs.y_ready;

assign z_buffer_q.valid    = z_buffer_flgs.z_valid;

/*----------------------------------------------------------------*/
/* |                          Buffers                           | */
/*----------------------------------------------------------------*/

logic [Width-1:0][Height-1:0][BITW-1:0] x_buffer_q;
redmule_x_buffer #(
  .DW         ( DATAW_ALIGN         ),
  .FpFormat   ( FpFormat            ),
  .Height     ( Height              ),
  .Width      ( Width               )
) i_x_buffer  (
  .clk_i       ( clk_i              ),
  .rst_ni      ( rst_ni             ),
  .clear_i     ( clear              ),
  .ctrl_i      ( x_buffer_ctrl      ),
  .flags_o     ( x_buffer_flgs      ),
  .x_buffer_o  ( x_buffer_q         ),
  .x_buffer_i  ( x_buffer_fifo.data )
);

logic [Height-1:0][BITW-1:0] w_buffer_q;
redmule_w_buffer #(
  .DW         ( DATAW_ALIGN         ),
  .FpFormat   ( FpFormat            ),
  .Height     ( Height              )
) i_w_buffer  (
  .clk_i       ( clk_i              ),
  .rst_ni      ( rst_ni             ),
  .clear_i     ( clear              ),
  .ctrl_i      ( w_buffer_ctrl      ),
  .flags_o     ( w_buffer_flgs      ),
  .w_buffer_o  ( w_buffer_q         ),
  .w_buffer_i  ( w_buffer_fifo.data )
);

logic [Width-1:0][BITW-1:0] z_buffer_d, y_bias_q, z_buffer_d_muxed;

// z_buffer_d_muxed: Always use z_buffer_d (MX bypass happens at FIFO input, not here)
assign z_buffer_d_muxed = z_buffer_d;

redmule_z_buffer #(
  .DW            ( DATAW_ALIGN        ),
  .FpFormat      ( FpFormat           ),
  .Width         ( Width              )
) i_z_buffer     (
  .clk_i         ( clk_i              ),
  .rst_ni        ( rst_ni             ),
  .clear_i       ( clear              ),
  .reg_enable_i  ( reg_enable         ),
  .ctrl_i        ( z_buffer_ctrl      ),
  .flags_o       ( z_buffer_flgs      ),
  .y_buffer_i    ( y_buffer_fifo.data ),
  .z_buffer_i    ( z_buffer_d_muxed   ),
  .y_buffer_o    ( y_bias_q           ),
  .z_buffer_o    ( z_buffer_q.data    ),
  .z_strb_o      ( z_buffer_q.strb    )
);

/*---------------------------------------------------------------*/
/* |                          Engine                           | */
/*---------------------------------------------------------------*/
cntrl_engine_t ctrl_engine;
flgs_engine_t  flgs_engine;

// Engine signals
// Control signal for successive accumulations
logic                               accumulate, engine_flush;
// fpnew_fma Input Signals
logic                         [2:0] fma_is_boxed;
logic                         [1:0] noncomp_is_boxed;
roundmode_e                         stage1_rnd,
                                    stage2_rnd;
operation_e                         op1, op2;
logic                               op_mod;
logic                               in_tag;
logic                               in_aux;
// fpnew_fma Input Handshake
logic                               in_valid;
logic       [Width-1:0][Height-1:0] in_ready;

logic                               flush;
// fpnew_fma Output signals
status_t    [Width-1:0][Height-1:0] status;
logic       [Width-1:0][Height-1:0] extension_bit;
classmask_e [Width-1:0][Height-1:0] class_mask;
logic       [Width-1:0][Height-1:0] is_class;
logic       [Width-1:0][Height-1:0] out_tag;
logic       [Width-1:0][Height-1:0] out_aux;
// fpnew_fma Output handshake
logic       [Width-1:0][Height-1:0] out_valid;
logic                               out_ready;
// fpnew_fma Indication of valid data in flight
logic       [Width-1:0][Height-1:0] busy;

// Binding from engine interface types to cntrl_engine_t and
assign fma_is_boxed     = cntrl_engine.fma_is_boxed;
assign noncomp_is_boxed = cntrl_engine.noncomp_is_boxed;
assign stage1_rnd       = cntrl_engine.stage1_rnd;
assign stage2_rnd       = cntrl_engine.stage2_rnd;
assign op1              = cntrl_engine.op1;
assign op2              = cntrl_engine.op2;
assign op_mod           = cntrl_engine.op_mod;
assign in_tag           = 1'b0;
assign in_aux           = 1'b0;
assign in_valid         = cntrl_engine.in_valid;
assign flush            = cntrl_engine.flush | clear;
// Backpressure: when MX mode enabled, also check FIFO has space
assign out_ready        = mx_enable ? (cntrl_engine.out_ready && fifo_grant) : cntrl_engine.out_ready;
always_comb begin
  for (int w = 0; w < Width; w++) begin
    for (int h = 0; h < Height; h++) begin
      flgs_engine.in_ready      [w][h] = in_ready      [w][h];
      flgs_engine.status        [w][h] = status        [w][h];
      flgs_engine.extension_bit [w][h] = extension_bit [w][h];
      flgs_engine.out_valid     [w][h] = out_valid     [w][h];
      flgs_engine.busy          [w][h] = busy          [w][h];
    end
  end
end

// Engine instance
redmule_engine     #(
  .FpFormat        ( FpFormat      ),
  .Height          ( Height        ),
  .Width           ( Width         ),
  .NumPipeRegs     ( NumPipeRegs   ),
  .PipeConfig      ( PipeConfig    )
) i_redmule_engine (
  .clk_i              ( clk_i            ),
  .rst_ni             ( rst_ni           ),
  .x_input_i          ( x_buffer_q       ),
  .w_input_i          ( w_buffer_q       ),
  .y_bias_i           ( y_bias_q         ),
  .z_output_o         ( z_buffer_d       ),
  .fma_is_boxed_i     ( fma_is_boxed     ),
  .noncomp_is_boxed_i ( noncomp_is_boxed ),
  .stage1_rnd_i       ( stage1_rnd       ),
  .stage2_rnd_i       ( stage2_rnd       ),
  .op1_i              ( op1              ),
  .op2_i              ( op2              ),
  .op_mod_i           ( op_mod           ),
  .tag_i              ( in_tag           ),
  .aux_i              ( in_aux           ),
  .in_valid_i         ( in_valid         ),
  .in_ready_o         ( in_ready         ),
  .reg_enable_i       ( reg_enable       ),
  .flush_i            ( flush            ),
  .status_o           ( status           ),
  .extension_bit_o    ( extension_bit    ),
  .class_mask_o       ( class_mask       ),
  .is_class_o         ( is_class         ),
  .tag_o              ( out_tag          ),
  .aux_o              ( out_aux          ),
  .out_valid_o        ( out_valid        ),
  .out_ready_i        ( out_ready        ),
  .busy_o             ( busy             ),
  .ctrl_engine_i      ( cntrl_engine     )
);

/*---------------------------------------------------------------*/
/* |                   MX ENCODER & FIFO                       | */
/*---------------------------------------------------------------*/

// Extract MX enable from flags (mx_enable declared at top for forward reference)
assign mx_enable = cntrl_flags.mx_enable;

// FIFO signals - using Width (not Height) since z_buffer_d is [Width-1:0] 
// Note: fifo_grant is forward-declared at top for backpressure
logic [Width-1:0][BITW-1:0] fifo_data_out;
logic fifo_push, fifo_pop, fifo_valid;

// Push conditions - check if engine has valid output
// out_valid is [Width-1:0][Height-1:0], need to OR across all dimensions
logic any_pe_valid;
logic [Width-1:0] width_valid;
always_comb begin
  for (int w = 0; w < Width; w++) begin
    width_valid[w] = |flgs_engine.out_valid[w]; // OR all Height PEs in this Width stage
  end
  any_pe_valid = |width_valid; // OR all Width stages
end
assign fifo_push = any_pe_valid && mx_enable && fifo_grant;  // Only push when FIFO has space


redmule_mx_fifo #(
  .DATA_WIDTH ( Width*BITW ),  // Width lanes * 16 bits
  .FIFO_DEPTH ( 4          )
) i_engine_fifo (
  .clk_i      ( clk_i         ),
  .rst_ni     ( rst_ni        ),
  .clear_i    ( clear         ),
  .push_i     ( fifo_push     ),
  .grant_o    ( fifo_grant    ),
  .data_i     ( z_buffer_d    ),
  .pop_i      ( fifo_pop      ),
  .valid_o    ( fifo_valid    ),
  .data_o     ( fifo_data_out )
);

// MX Encoder (mx_val_valid declared at top for forward reference)
logic [DATAW/2-1:0] mx_val_data;  // 256 bits for 32 FP8 elements
logic mx_val_ready;
logic [7:0] mx_exp_data;
logic mx_exp_valid, mx_exp_ready;
logic encoder_ready;  // Raw ready from encoder

// Gate pop with mx_enable AND fifo_valid - only pop when FIFO has data
assign fifo_pop = encoder_ready && mx_enable && fifo_valid;

redmule_mx_encoder #(
  .DATA_W    ( DATAW/2 ),  // 256 bits output
  .BITW      ( BITW  ),
  .NUM_LANES ( Width )  // Process Width lanes per cycle
) i_mx_encoder (
  .clk_i          ( clk_i          ),
  .rst_ni         ( rst_ni         ),
  .fp16_valid_i   ( fifo_valid && mx_enable ),  // Only valid when MX mode active
  .fp16_ready_o   ( encoder_ready  ),
  .fp16_data_i    ( fifo_data_out  ),
  .mx_val_valid_o ( mx_val_valid   ),
  .mx_val_ready_i ( mx_val_ready   ),
  .mx_val_data_o  ( mx_val_data    ),
  .mx_exp_valid_o ( mx_exp_valid   ),
  .mx_exp_ready_i ( mx_exp_ready   ),
  .mx_exp_data_o  ( mx_exp_data    )
);

// ============================================================================
// LEGACY: Exponent storage and serialization logic (for smaller array configs)
// ============================================================================
// // Exponent storage (temporary solution)
// localparam int MAX_MX_BLOCKS = 256;
// // TODO: expose via sepereate TCDM port
// logic [7:0] mx_exp_storage [MAX_MX_BLOCKS];
// logic [$clog2(MAX_MX_BLOCKS)-1:0] exp_wr_ptr;
// 
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin
//     exp_wr_ptr <= '0;
//   end else if (clear) begin
//     exp_wr_ptr <= '0;
//   end else if (mx_exp_valid && mx_exp_ready) begin
//     mx_exp_storage[exp_wr_ptr] <= mx_exp_data;
//     exp_wr_ptr <= exp_wr_ptr + 1;
//   end
// end
// 
// assign mx_exp_ready = 1'b1;
// 
// // Serialization: 256-bit -> Width*BITW chunks
// localparam int MX_CHUNKS_PER_BLOCK = (256 + Width*BITW - 1) / (Width*BITW); // Ceiling division incase of non-even divisibility
// logic [$clog2(MX_CHUNKS_PER_BLOCK):0] mx_word_cnt;
// logic [Width*BITW-1:0] mx_chunk;
// 
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin
//     mx_word_cnt <= '0;
//   end else if (clear) begin
//     mx_word_cnt <= '0;
//   end else if (mx_val_valid && mx_val_ready) begin
//     if (mx_word_cnt == (256/(Width*BITW) - 1)) begin
//       mx_word_cnt <= '0;
//     end else begin
//       mx_word_cnt <= mx_word_cnt + 1;
//     end
//   end
// end
// 
// assign mx_chunk = mx_val_data[mx_word_cnt*(Width*BITW) +: Width*BITW];
// assign mx_val_ready = (mx_word_cnt == (256/(Width*BITW) - 1));
// ============================================================================

// Exponent streaming: Expose shared exponent as separate output stream
assign mx_exp_stream.valid = mx_exp_valid;
assign mx_exp_stream.data  = {{(SysDataWidth-8){1'b0}}, mx_exp_data};
assign mx_exp_stream.strb  = '1;
assign mx_exp_ready = mx_exp_stream.ready;

// Data stream handshake
assign mx_val_ready = 1'b1;

// MX format constants
localparam int MX_ELEM_WIDTH = 8;   // FP8 element width  
localparam int MX_BLOCK_ELEMS = 32; // 32 elements per MX block

// MX encoder output packing: 32 FP8 elements (256 bits) into DATAW_ALIGN (512 bits)
// No serialization needed - memory bus is 512 bits, MX output is 256 bits
// Pack FP8 mantissas in lower 256 bits, upper 256 bits zero (or could hold metadata)
// (mx_z_buffer_data declared at top for forward reference)
assign mx_z_buffer_data = {{(DATAW_ALIGN-256){1'b0}}, mx_val_data};

// z_buffer_d is not used for MX - we intercept at z_buffer_q level
// The muxed signal connects to z_buffer, but MX bypass happens at FIFO input

/*---------------------------------------------------------------*/
/* |                    Memory Controller                      | */
/*---------------------------------------------------------------*/

logic z_priority;
assign z_priority = z_buffer_flgs.z_priority | !z_fifo_flgs.empty;
redmule_memory_scheduler #(
  .DW (DATAW_ALIGN),
  .W  (Width),
  .H  (Height)
) i_memory_scheduler (
  .clk_i             ( clk_i           ),
  .rst_ni            ( rst_ni          ),
  .clear_i           ( clear           ),
  .z_priority_i      ( z_priority      ),
  .reg_file_i        ( reg_file        ),
  .flgs_streamer_i   ( flgs_streamer   ),
  .cntrl_scheduler_i ( cntrl_scheduler ),
  .cntrl_flags_i     ( cntrl_flags     ),
  .cntrl_streamer_o  ( cntrl_streamer  )
);



/*---------------------------------------------------------------*/
/* |                        Controller                         | */
/*---------------------------------------------------------------*/

redmule_ctrl        #(
  .N_CORES           ( N_CORES                 ),
  .IO_REGS           ( REDMULE_REGS            ),
  .ID_WIDTH          ( ID_WIDTH                ),
  .N_CONTEXT         ( NumContext              ),
  .HCI_ECC           ( HCI_ECC                 ),
  .SysDataWidth      ( SysDataWidth            ),
  .Height            ( Height                  ),
  .Width             ( Width                   ),
  .NumPipeRegs       ( NumPipeRegs             )
) i_control          (
  .clk_i             ( clk_i                   ),
  .rst_ni            ( rst_ni                  ),
  .test_mode_i       ( test_mode_i             ),
  .flgs_streamer_i   ( flgs_streamer           ),
  .busy_o            ( busy_o                  ),
  .clear_o           ( clear                   ),
  .evt_o             ( evt_o                   ),
  .reg_file_o        ( reg_file                ),
  .reg_enable_i      ( reg_enable              ),
  .start_cfg_i       ( start_cfg               ),
  .cfg_complete_o    ( cfg_complete            ),
  .w_loaded_i        ( flgs_scheduler.w_loaded ),
  .flush_o           ( engine_flush            ),
  .cntrl_scheduler_o ( cntrl_scheduler         ),
  .cntrl_flags_o     ( cntrl_flags             ),
  .errs_streamer_i   ( ecc_errors_streamer     ),
  .periph            ( local_periph            )
);


/*---------------------------------------------------------------*/
/* |                        Local FSM                          | */
/*---------------------------------------------------------------*/
redmule_scheduler #(
  .Height      ( Height         ),
  .Width       ( Width          ),
  .NumPipeRegs ( NumPipeRegs    )
) i_scheduler (
  .clk_i             ( clk_i               ),
  .rst_ni            ( rst_ni              ),
  .test_mode_i       ( test_mode_i         ),
  .clear_i           ( clear               ),
  .x_valid_i         ( x_buffer_fifo.valid ),
  .w_valid_i         ( w_buffer_fifo.valid ),
  .y_valid_i         ( y_buffer_fifo.valid ),
  .z_ready_i         ( z_buffer_q.ready    ),
  .engine_flush_i    ( engine_flush        ),
  .reg_file_i        ( reg_file            ),
  .flgs_streamer_i   ( flgs_streamer       ),
  .flgs_x_buffer_i   ( x_buffer_flgs       ),
  .flgs_w_buffer_i   ( w_buffer_flgs       ),
  .flgs_z_buffer_i   ( z_buffer_flgs       ),
  .flgs_engine_i     ( flgs_engine         ),
  .cntrl_scheduler_i ( cntrl_scheduler     ),
  .reg_enable_o      ( reg_enable          ),
  .cntrl_engine_o    ( cntrl_engine        ),
  .cntrl_x_buffer_o  ( x_buffer_ctrl       ),
  .cntrl_w_buffer_o  ( w_buffer_ctrl       ),
  .cntrl_z_buffer_o  ( z_buffer_ctrl       ),
  .flgs_scheduler_o  ( flgs_scheduler      )
);

endmodule : redmule_top
