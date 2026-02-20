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
  hwpe_stream_intf_stream.source mx_exp_stream
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
flags_fifo_t   x_fifo_flgs, w_fifo_flgs, x_exp_fifo_flgs, w_exp_fifo_flgs;
cntrl_flags_t  cntrl_flags;

/*--------------------------------------------------------------*/
/* |                         Streamer                         | */
/*--------------------------------------------------------------*/

// Implementation of the incoming and outgoing streaming interfaces (one for each kind of data)

// X streaming interface + X FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_d         ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_muxed     ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_fifo      ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_raw       ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_slot      ( .clk( clk_i ) );

// W streaming interface + W FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_buffer_d         ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_buffer_muxed     ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_buffer_fifo      ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_buffer_raw       ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_buffer_slot      ( .clk( clk_i ) );

// Y streaming interface + Y FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) y_buffer_d         ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) y_buffer_fifo      ( .clk( clk_i ) );

// Z streaming interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) z_buffer_q         ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) z_buffer_muxed     ( .clk( clk_i ) );

// X,W exponent interfaces: streaming input from streamer
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_exp_from_streamer   ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_exp_from_streamer   ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_exp_stream_buffered ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) w_exp_stream_buffered ( .clk( clk_i ) );

// X,W exponent buffer outputs: direct register access (decoupled from streaming)
logic [7:0]  x_exp_buf_data;
logic        x_exp_buf_valid;
logic        x_exp_buf_consume;
logic [7:0] w_exp_buf_data;   // W exponent is 8 bits (unpacked from packed format)
logic        w_exp_buf_valid;
logic        w_exp_buf_consume;

// MX output stage signals
logic fifo_grant;  
logic fifo_valid;
logic fifo_pop;
logic [Width*BITW-1:0] fifo_data_out;
logic mx_val_valid;
logic mx_val_ready;
logic [DATAW/2-1:0] mx_val_data;
logic mx_exp_valid;
logic mx_exp_ready;
logic [7:0] mx_exp_data;

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
  .x_exp_stream_o  ( x_exp_from_streamer ), // mx output exponent stream
  .w_exp_stream_o  ( w_exp_from_streamer ),
  // Sink interface for the outgoing stream
  .z_stream_i      ( z_buffer_muxed      ),
  // Master TCDM interface ports for the memory side
  .tcdm            ( tcdm                ),
  .ecc_errors_o    ( ecc_errors_streamer ),
  .ctrl_i          ( cntrl_streamer      ),
  .flags_o         ( flgs_streamer       )
);

logic mx_mode_active;
assign mx_mode_active = cntrl_flags.mx_enable;

// Route streamer outputs either to MX slot path or raw path
assign x_buffer_slot.valid = mx_mode_active ? x_buffer_d.valid : 1'b0;
assign x_buffer_slot.data  = x_buffer_d.data;
assign x_buffer_slot.strb  = x_buffer_d.strb;
assign x_buffer_raw.valid  = mx_mode_active ? 1'b0 : x_buffer_d.valid;
assign x_buffer_raw.data   = x_buffer_d.data;
assign x_buffer_raw.strb   = x_buffer_d.strb;
assign x_buffer_d.ready    = mx_mode_active ? x_buffer_slot.ready : x_buffer_raw.ready;

assign w_buffer_slot.valid = mx_mode_active ? w_buffer_d.valid : 1'b0;
assign w_buffer_slot.data  = w_buffer_d.data;
assign w_buffer_slot.strb  = w_buffer_d.strb;
assign w_buffer_raw.valid  = mx_mode_active ? 1'b0 : w_buffer_d.valid;
assign w_buffer_raw.data   = w_buffer_d.data;
assign w_buffer_raw.strb   = w_buffer_d.strb;
assign w_buffer_d.ready    = mx_mode_active ? w_buffer_slot.ready : w_buffer_raw.ready;

// Dedicated exponent FIFOs decouple streamer backpressure from the deep buffers
hwpe_stream_fifo #(
  .DATA_WIDTH ( DATAW_ALIGN ),
  .FIFO_DEPTH ( 4           )
) i_x_exp_stream_fifo (
  .clk_i   ( clk_i                 ),
  .rst_ni  ( rst_ni                ),
  .clear_i ( clear                 ),
  .flags_o ( x_exp_fifo_flgs       ),
  .push_i  ( x_exp_from_streamer   ),
  .pop_o   ( x_exp_stream_buffered )
);

hwpe_stream_fifo #(
  .DATA_WIDTH ( DATAW_ALIGN ),
  .FIFO_DEPTH ( 4           )
) i_w_exp_stream_fifo (
  .clk_i   ( clk_i                 ),
  .rst_ni  ( rst_ni                ),
  .clear_i ( clear                 ),
  .flags_o ( w_exp_fifo_flgs       ),
  .push_i  ( w_exp_from_streamer   ),
  .pop_o   ( w_exp_stream_buffered )
);

// X exponent buffer: extracts 8-bit exponents from compact 1024-bit beats
// 1024/8 = 128 exponents per beat, buffer depth 1024 = enough for many blocks
redmule_exp_buffer #(
  .EXP_WIDTH     ( 8           ),  // 8-bit exponents for X
  .BUFFER_DEPTH  ( 1024        ),  // Large buffer to hold all exponents
  .BEAT_WIDTH    ( DATAW_ALIGN )
) i_x_exp_buffer (
  .clk_i      ( clk_i                ),
  .rst_ni     ( rst_ni               ),
  .clear_i    ( clear                ),
  .stream_i   ( x_exp_stream_buffered ),
  .data_o     ( x_exp_buf_data       ),
  .valid_o    ( x_exp_buf_valid      ),
  .consume_i  ( x_exp_buf_consume    )
);

// W exponent buffer: extracts 8-bit exponents from packed beats (same as X)
// 512/8 = 64 exponents per beat, buffer depth 1024 for up to 1024 weight blocks
redmule_exp_buffer #(
  .EXP_WIDTH     ( 8           ),  // 8-bit exponents for W (unpacked from 32-bit packed words)
  .BUFFER_DEPTH  ( 1024        ),  // Buffer for up to 1024 weight blocks
  .BEAT_WIDTH    ( DATAW_ALIGN )
) i_w_exp_buffer (
  .clk_i      ( clk_i                ),
  .rst_ni     ( rst_ni               ),
  .clear_i    ( clear                ),
  .stream_i   ( w_exp_stream_buffered ),
  .data_o     ( w_exp_buf_data       ),
  .valid_o    ( w_exp_buf_valid      ),
  .consume_i  ( w_exp_buf_consume    )
);

/*---------------------------------------------------------------*/
/* |                   MX MODULES (INPUT SIDE)                 | */
/*---------------------------------------------------------------*/

// MX decoder parameters
localparam int unsigned MX_DATA_W = 256;  // 32 FP8 elements
localparam int unsigned MX_NUM_LANES = Width;  // Process Width elements per cycle
localparam int unsigned MX_INPUT_ELEM_WIDTH  = 8;
localparam int unsigned MX_INPUT_NUM_ELEMS   = MX_DATA_W / MX_INPUT_ELEM_WIDTH;
localparam int unsigned MX_INPUT_NUM_GROUPS  = MX_INPUT_NUM_ELEMS / MX_NUM_LANES;
localparam int unsigned MX_EXP_VECTOR_W      = MX_INPUT_NUM_GROUPS * 8;
localparam int unsigned MX_SLOT_FIFO_DEPTH   = 16;  // Restore depth to avoid stressing dummy TCDM

// Slot buffer signals
logic x_slot_valid, w_slot_valid;
logic x_slot_exp_valid, w_slot_exp_valid;
logic [MX_DATA_W-1:0] x_slot_data, w_slot_data;
logic [7:0] x_slot_exp;
logic [MX_EXP_VECTOR_W-1:0] w_slot_exp;
logic consume_x_slot, consume_w_slot;

// Decoder signals
logic x_mx_fp16_valid, x_mx_fp16_ready;
logic w_mx_fp16_valid, w_mx_fp16_ready;
logic [MX_NUM_LANES*BITW-1:0] x_mx_fp16_data, w_mx_fp16_data;

// Decoder interface signals
logic mx_dec_val_valid, mx_dec_exp_valid;
logic mx_dec_val_ready, mx_dec_exp_ready;
logic [MX_DATA_W-1:0] mx_dec_val_data;
logic [MX_EXP_VECTOR_W-1:0] mx_dec_exp_data;
logic mx_dec_vector_mode;
logic mx_dec_fp16_valid, mx_dec_fp16_ready;
logic [MX_NUM_LANES*BITW-1:0] mx_dec_fp16_data;

// Arbiter target tracking
typedef enum logic [1:0] {
  MX_DEC_NONE,
  MX_DEC_X,
  MX_DEC_W
} mx_dec_target_e;
mx_dec_target_e mx_dec_target;

// Instantiate MX slot buffer
redmule_mx_slot_buffer #(
  .DATAW_ALIGN       ( DATAW_ALIGN       ),
  .MX_DATA_W         ( MX_DATA_W         ),
  .MX_EXP_VECTOR_W   ( MX_EXP_VECTOR_W   ),
  .MX_INPUT_ELEM_WIDTH ( MX_INPUT_ELEM_WIDTH ),
  .MX_INPUT_NUM_ELEMS  ( MX_INPUT_NUM_ELEMS  ),
  .SLOT_FIFO_DEPTH   ( MX_SLOT_FIFO_DEPTH )
) i_mx_slot_buffer (
  .clk_i            ( clk_i                   ),
  .rst_ni           ( rst_ni                  ),
  .clear_i          ( clear                   ),
  .mx_enable_i      ( cntrl_flags.mx_enable   ),
  .x_data_i         ( x_buffer_slot          ),
  .w_data_i         ( w_buffer_slot         ),
  .x_exp_data_i     ( x_exp_buf_data         ),
  .x_exp_valid_i    ( x_exp_buf_valid        ),
  .x_exp_consume_o  ( x_exp_buf_consume      ),
  .w_exp_data_i     ( w_exp_buf_data         ),
  .w_exp_valid_i    ( w_exp_buf_valid        ),
  .w_exp_consume_o  ( w_exp_buf_consume      ),
  .x_slot_valid_o   ( x_slot_valid       ),
  .x_slot_exp_valid_o ( x_slot_exp_valid ),
  .w_slot_valid_o   ( w_slot_valid       ),
  .w_slot_exp_valid_o ( w_slot_exp_valid ),
  .x_slot_data_o    ( x_slot_data        ),
  .w_slot_data_o    ( w_slot_data        ),
  .x_slot_exp_o     ( x_slot_exp         ),
  .w_slot_exp_o     ( w_slot_exp         ),
  .consume_x_slot_i ( consume_x_slot     ),
  .consume_w_slot_i ( consume_w_slot     )
);

// Instantiate MX arbiter
logic [1:0] mx_dec_target_raw;
logic target_is_x, target_is_w;
assign target_is_x = (mx_dec_target == MX_DEC_X);
assign target_is_w = (mx_dec_target == MX_DEC_W);

redmule_mx_arbiter #(
  .MX_DATA_W           ( MX_DATA_W           ),
  .MX_EXP_VECTOR_W     ( MX_EXP_VECTOR_W     ),
  .MX_NUM_LANES        ( MX_NUM_LANES        ),
  .MX_INPUT_NUM_GROUPS ( MX_INPUT_NUM_GROUPS ),
  .BITW                ( BITW                )
) i_mx_arbiter (
  .clk_i                ( clk_i                   ),
  .rst_ni               ( rst_ni                  ),
  .clear_i              ( clear                   ),
  .mx_enable_i          ( cntrl_flags.mx_enable   ),
  .x_slot_valid_i       ( x_slot_valid            ),
  .x_slot_exp_valid_i   ( x_slot_exp_valid        ),
  .w_slot_valid_i       ( w_slot_valid       ),
  .w_slot_exp_valid_i   ( w_slot_exp_valid   ),
  .x_slot_data_i        ( x_slot_data        ),
  .w_slot_data_i        ( w_slot_data        ),
  .x_slot_exp_i         ( x_slot_exp         ),
  .w_slot_exp_i         ( w_slot_exp         ),
  .x_fifo_flgs_i        ( x_fifo_flgs        ),
  .w_fifo_flgs_i        ( w_fifo_flgs        ),
  .mx_dec_val_valid_o   ( mx_dec_val_valid   ),
  .mx_dec_exp_valid_o   ( mx_dec_exp_valid   ),
  .mx_dec_val_ready_i   ( mx_dec_val_ready   ),
  .mx_dec_exp_ready_i   ( mx_dec_exp_ready   ),
  .mx_dec_val_data_o    ( mx_dec_val_data    ),
  .mx_dec_exp_data_o    ( mx_dec_exp_data    ),
  .mx_dec_vector_mode_o ( mx_dec_vector_mode ),
  .mx_dec_fp16_valid_i  ( mx_dec_fp16_valid  ),
  .mx_dec_fp16_ready_i  ( mx_dec_fp16_ready  ),
  .consume_x_slot_o     ( consume_x_slot     ),
  .consume_w_slot_o     ( consume_w_slot     ),
  .mx_dec_target_o      ( mx_dec_target_raw  )
);

// Cast target to enum
assign mx_dec_target = mx_dec_target_e'(mx_dec_target_raw);

redmule_mx_decoder #(
  .DATA_W    ( MX_DATA_W    ),
  .BITW      ( BITW         ),
  .NUM_LANES ( MX_NUM_LANES )
) i_mx_decoder_shared (
  .clk_i               ( clk_i             ),
  .rst_ni              ( rst_ni            ),
  .mx_val_valid_i      ( mx_dec_val_valid  ),
  .mx_val_ready_o      ( mx_dec_val_ready  ),
  .mx_val_data_i       ( mx_dec_val_data   ),
  .mx_exp_valid_i      ( mx_dec_exp_valid  ),
  .mx_exp_ready_o      ( mx_dec_exp_ready  ),
  .mx_exp_data_i       ( mx_dec_exp_data   ),
  .vector_shared_exp_i ( mx_dec_vector_mode ),
  .fp16_valid_o        ( mx_dec_fp16_valid ),
  .fp16_ready_i        ( mx_dec_fp16_ready ),
  .fp16_data_o         ( mx_dec_fp16_data  )
);

// Route decoder output to X or W based on target
assign x_mx_fp16_valid = (cntrl_flags.mx_enable && target_is_x) ? mx_dec_fp16_valid : 1'b0;
assign w_mx_fp16_valid = (cntrl_flags.mx_enable && target_is_w) ? mx_dec_fp16_valid : 1'b0;
assign x_mx_fp16_data  = mx_dec_fp16_data;
assign w_mx_fp16_data  = mx_dec_fp16_data;

// Instantiate MX input mux
redmule_mx_input_mux #(
  .DATAW_ALIGN  ( DATAW_ALIGN  ),
  .BITW         ( BITW         ),
  .MX_NUM_LANES ( MX_NUM_LANES )
) i_mx_input_mux (
  .mx_enable_i        ( cntrl_flags.mx_enable ),
  .target_is_x_i      ( target_is_x           ),
  .target_is_w_i      ( target_is_w        ),
  .x_raw_i            ( x_buffer_raw       ),
  .w_raw_i            ( w_buffer_raw      ),
  .x_decoded_valid_i  ( x_mx_fp16_valid    ),
  .w_decoded_valid_i  ( w_mx_fp16_valid    ),
  .x_decoded_ready_o  ( x_mx_fp16_ready    ),
  .w_decoded_ready_o  ( w_mx_fp16_ready    ),
  .x_decoded_data_i   ( x_mx_fp16_data     ),
  .w_decoded_data_i   ( w_mx_fp16_data     ),
  .x_muxed_o          ( x_buffer_muxed     ),
  .w_muxed_o          ( w_buffer_muxed     )
);

// Decoder ready routing
assign mx_dec_fp16_ready = target_is_x ? x_mx_fp16_ready :
                           target_is_w ? w_mx_fp16_ready : 1'b0;

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DATAW_ALIGN   ),
  .FIFO_DEPTH     ( 8             )  // Testing smaller depth
) i_x_buffer_fifo (
  .clk_i          ( clk_i           ),
  .rst_ni         ( rst_ni          ),
  .clear_i        ( clear           ),
  .flags_o        ( x_fifo_flgs     ),
  .push_i         ( x_buffer_muxed  ),
  .pop_o          ( x_buffer_fifo   )
);

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DATAW_ALIGN   ),
  .FIFO_DEPTH     ( 8             )  // Testing smaller depth
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
assign out_ready        = cntrl_flags.mx_enable ? (cntrl_engine.out_ready && fifo_grant) : cntrl_engine.out_ready;
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
/* |                   MX OUTPUT STAGE                         | */
/*---------------------------------------------------------------*/

redmule_mx_output_stage #(
  .DATAW_ALIGN   ( DATAW_ALIGN   ),
  .DATAW         ( DATAW         ),
  .BITW          ( BITW          ),
  .Width         ( Width         ),
  .Height        ( Height        ),
  .SysDataWidth  ( SysDataWidth  )
) i_mx_output_stage (
  .clk_i              ( clk_i                   ),
  .rst_ni             ( rst_ni                  ),
  .clear_i            ( clear                   ),
  .mx_enable_i        ( cntrl_flags.mx_enable   ),
  .reg_enable_i       ( reg_enable              ),  // Gate encoder on valid computation
  .z_engine_data_i    ( z_buffer_d              ),
  .z_engine_stream_i  ( z_buffer_q              ),
  .flgs_engine_i      ( flgs_engine             ),
  .fifo_grant_o       ( fifo_grant              ),
  .z_muxed_o          ( z_buffer_muxed          ),
  .mx_exp_stream_o    ( mx_exp_stream           ),
  .mx_val_valid_o     ( mx_val_valid            ),
  .mx_val_ready_o     ( mx_val_ready            ),
  .mx_val_data_o      ( mx_val_data             ),
  .mx_exp_valid_o     ( mx_exp_valid            ),
  .mx_exp_ready_o     ( mx_exp_ready            ),
  .mx_exp_data_o      ( mx_exp_data             ),
  .fifo_valid_o       ( fifo_valid              ),
  .fifo_pop_o         ( fifo_pop                ),
  .fifo_data_out_o    ( fifo_data_out           )
);

/*---------------------------------------------------------------*/
/* |                    Memory Controller                      | */
/*---------------------------------------------------------------*/

logic z_priority;
assign z_priority = z_buffer_flgs.z_priority;

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
