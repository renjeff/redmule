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
  hci_core_intf.initiator tcdm
);

localparam int unsigned DATAW_ALIGN = `HCI_SIZE_GET_DW(tcdm) - SysDataWidth;
localparam int unsigned HCI_ECC = (`HCI_SIZE_GET_EW(tcdm)>1);
localparam int unsigned MX_DATA_W = 256;  // 32 FP8 elements per MX block

logic                       enable, clear;

// Internal MX exponent stream (packed exponents from encoder → FIFO → streamer Z exp sink)
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) mx_exp_stream     ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) mx_exp_stream_buf ( .clk( clk_i ) );

// Decouple exp output from TCDM backpressure so the encoder never stalls on exp writes.
hwpe_stream_fifo #(
  .DATA_WIDTH ( DATAW_ALIGN ),
  .FIFO_DEPTH ( 8           )
) i_mx_exp_decouple_fifo (
  .clk_i   ( clk_i              ),
  .rst_ni  ( rst_ni             ),
  .clear_i ( clear              ),
  .flags_o (                    ),
  .push_i  ( mx_exp_stream     ),
  .pop_o   ( mx_exp_stream_buf )
);
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
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_packed    ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_muxed     ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_fifo      ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_raw       ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ) ) x_buffer_slot      ( .clk( clk_i ) );

// W streaming interface + W FIFO interface
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ), .BYPASS_VCR_ASSERT ( 1'b1 ), .BYPASS_VDR_ASSERT ( 1'b1 ) ) w_buffer_d ( .clk( clk_i ) );
// Bypass HWPE stream assertions on W path: rewind FIFO replay transitions violate
// value-change and valid-deassert rules during bank switch
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ), .BYPASS_VCR_ASSERT ( 1'b1 ), .BYPASS_VDR_ASSERT ( 1'b1 ) ) w_buffer_packed ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ), .BYPASS_VCR_ASSERT ( 1'b1 ), .BYPASS_VDR_ASSERT ( 1'b1 ) ) w_buffer_muxed  ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ), .BYPASS_VCR_ASSERT ( 1'b1 ), .BYPASS_VDR_ASSERT ( 1'b1 ) ) w_buffer_fifo   ( .clk( clk_i ) );
hwpe_stream_intf_stream #( .DATA_WIDTH ( DATAW_ALIGN ), .BYPASS_VCR_ASSERT ( 1'b1 ), .BYPASS_VDR_ASSERT ( 1'b1 ) ) w_buffer_raw    ( .clk( clk_i ) );
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
logic [7:0] w_exp_buf_data;   // W exponent byte forwarded to decoder (NUM_GROUPS==1)
logic [31:0] w_exp_buf_word;  // Raw compact-32bit exponent word from W exp stream
logic        w_exp_buf_valid;
logic        w_exp_buf_consume;

// MX exponent mark/rewind signals (from scheduler FSM)
logic x_exp_mark, x_exp_rewind;
logic w_exp_mark, w_exp_rewind;

// MX exponent total valid counts (from memory scheduler)
logic [15:0] x_exp_total_count, w_exp_total_count;
logic [15:0] x_exp_segment_size;

// MX output stage signals
logic fifo_grant;
logic fifo_valid;
logic fifo_pop;
logic [DATAW_ALIGN-1:0] fifo_data_out;
logic mx_val_valid;
logic mx_val_ready;
logic [MX_DATA_W-1:0] mx_val_data;
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
  .z_exp_stream_i  ( mx_exp_stream_buf   ),
  // Master TCDM interface ports for the memory side
  .tcdm            ( tcdm                ),
  .ecc_errors_o    ( ecc_errors_streamer ),
  .ctrl_i          ( cntrl_streamer      ),
  .flags_o         ( flgs_streamer       )
);

logic mx_mode_active;
assign mx_mode_active = cntrl_flags.mx_enable;

localparam int unsigned W_SLOT_STRB_W = DATAW_ALIGN/8;
logic [W_SLOT_STRB_W-1:0] w_slot_strb_mask;
logic [$clog2(TOT_DEPTH):0] w_valid_lanes;
logic [$clog2(TOT_DEPTH):0] w_nominal_width;
localparam int unsigned X_SLOT_STRB_W = DATAW_ALIGN/8;
logic [X_SLOT_STRB_W-1:0] x_slot_strb_mask;
logic [$clog2(TOT_DEPTH):0] x_valid_lanes;
logic [7:0] x_row_chunks;
logic [7:0] w_row_chunks;

// Route streamer outputs either to MX slot path or raw path
assign x_valid_lanes = mx_mode_active ? reg_file.hwpe_params[X_SLOTS][$clog2(TOT_DEPTH):0] : x_buffer_ctrl.height;
assign x_slot_strb_mask = {X_SLOT_STRB_W{1'b1}};
assign x_buffer_slot.valid = mx_mode_active ? x_buffer_d.valid : 1'b0;
assign x_buffer_slot.data  = x_buffer_d.data;
assign x_buffer_slot.strb  = mx_mode_active ? (x_buffer_d.strb & x_slot_strb_mask) : x_buffer_d.strb;
assign x_buffer_raw.valid  = mx_mode_active ? 1'b0 : x_buffer_d.valid;
assign x_buffer_raw.data   = x_buffer_d.data;
assign x_buffer_raw.strb   = x_buffer_d.strb;
assign x_buffer_d.ready    = mx_mode_active ? x_buffer_slot.ready : x_buffer_raw.ready;

// w_nominal_width / w_valid_lanes kept for legacy (non-MX) path.
// In MX mode, w_row_chunks is driven by the decode position counter instead.
assign w_nominal_width = w_buffer_ctrl.width;
assign w_valid_lanes = w_nominal_width;
assign w_slot_strb_mask = {W_SLOT_STRB_W{1'b1}};
assign w_buffer_slot.valid = mx_mode_active ? w_buffer_d.valid : 1'b0;
assign w_buffer_slot.data  = w_buffer_d.data;
assign w_buffer_slot.strb  = mx_mode_active ? (w_buffer_d.strb & w_slot_strb_mask) : w_buffer_d.strb;
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
  .clk_i         ( clk_i                ),
  .rst_ni        ( rst_ni               ),
  .clear_i       ( clear                ),
  .stream_i      ( x_exp_stream_buffered ),
  .total_count_i ( x_exp_total_count    ),
  .segment_size_i( x_exp_segment_size   ),
  .data_o        ( x_exp_buf_data       ),
  .valid_o       ( x_exp_buf_valid      ),
  .consume_i     ( x_exp_buf_consume    ),
  .mark_i        ( x_exp_mark           ),
  .rewind_i      ( x_exp_rewind         )
);

// W exponent buffer: compact-32bit format (1 exponent word per W block).
// Consume one 32-bit word per block to avoid byte-wise over-consumption.
redmule_exp_buffer #(
  .EXP_WIDTH     ( 32          ),  // 32-bit compact W exponent word per block
  .BUFFER_DEPTH  ( 1024        ),  // Buffer for up to 1024 weight blocks
  .BEAT_WIDTH    ( DATAW_ALIGN )
) i_w_exp_buffer (
  .clk_i         ( clk_i                ),
  .rst_ni        ( rst_ni               ),
  .clear_i       ( clear                ),
  .stream_i      ( w_exp_stream_buffered ),
  .total_count_i ( w_exp_total_count    ),
  .segment_size_i( '0                   ),  // No segment gating for W
  .data_o        ( w_exp_buf_word       ),
  .valid_o       ( w_exp_buf_valid      ),
  .consume_i     ( w_exp_buf_consume    ),
  .mark_i        ( w_exp_mark           ),
  .rewind_i      ( w_exp_rewind         )
);

// In current MX config (NUM_GROUPS==1), decoder uses one shared exponent byte.
// The compact-32bit stream replicates the value across bytes, so select [7:0].
assign w_exp_buf_data = w_exp_buf_word[7:0];

/*---------------------------------------------------------------*/
/* |                   MX MODULES (INPUT SIDE)                 | */
/*---------------------------------------------------------------*/

// MX decoder parameters
localparam int unsigned MX_INPUT_ELEM_WIDTH  = 8;
localparam int unsigned MX_INPUT_NUM_ELEMS   = MX_DATA_W / MX_INPUT_ELEM_WIDTH;
localparam int unsigned MX_BEAT_NUM_LANES    = DATAW_ALIGN / BITW;
localparam int unsigned MX_NUM_LANES = (MX_BEAT_NUM_LANES < MX_INPUT_NUM_ELEMS) ?
                                       MX_BEAT_NUM_LANES : MX_INPUT_NUM_ELEMS;
localparam int unsigned MX_INPUT_NUM_GROUPS  = MX_INPUT_NUM_ELEMS / MX_NUM_LANES;
localparam int unsigned MX_EXP_VECTOR_W      = MX_INPUT_NUM_GROUPS * 8;
localparam int unsigned MX_ROW_CHUNKS        = MX_BEAT_NUM_LANES / MX_NUM_LANES;
localparam int unsigned MX_SLOT_FIFO_DEPTH   = 16;  // Restore depth to avoid stressing dummy TCDM

initial begin
  if (DATAW_ALIGN % BITW != 0) begin
    $fatal(1, "MX path: DATAW_ALIGN (%0d) must be a multiple of BITW (%0d)", DATAW_ALIGN, BITW);
  end
  if (MX_INPUT_NUM_ELEMS % MX_NUM_LANES != 0) begin
    $fatal(1, "MX path: MX_INPUT_NUM_ELEMS (%0d) must be divisible by MX_NUM_LANES (%0d)",
           MX_INPUT_NUM_ELEMS, MX_NUM_LANES);
  end
  if (MX_BEAT_NUM_LANES % MX_NUM_LANES != 0) begin
    $fatal(1, "MX path: stream lanes per beat (%0d) must be divisible by MX_NUM_LANES (%0d)",
           MX_BEAT_NUM_LANES, MX_NUM_LANES);
  end
end

// Slot buffer signals
logic x_slot_valid, w_slot_valid;
logic x_slot_exp_valid, w_slot_exp_valid;
logic [MX_DATA_W-1:0] x_slot_data, w_slot_data;
logic [7:0] x_slot_exp;
logic [MX_EXP_VECTOR_W-1:0] w_slot_exp;
logic consume_x_slot, consume_w_slot;

// Decoder signals
logic x_mx_fp16_valid, x_mx_fp16_ready;
logic [MX_NUM_LANES*BITW-1:0] x_mx_fp16_data;

// W decoded output mediated by elastic buffer (breaks W→X head-of-line blocking)
logic w_dec_to_buf_valid;                       // decoder → buffer push valid
logic w_dec_buf_ready;                          // buffer → decoder push ready
logic w_buf_to_mux_valid;                       // buffer → input_mux pop valid
logic [MX_NUM_LANES*BITW-1:0] w_buf_to_mux_data; // buffer → input_mux data
logic w_buf_to_mux_ready;                       // input_mux → buffer pop ready

// Dedicated decoder signals (X path)
logic x_dec_fp16_valid, x_dec_fp16_ready;
logic [MX_NUM_LANES*BITW-1:0] x_dec_fp16_data;
logic x_dec_val_ready;

// Dedicated decoder signals (W path)
logic w_dec_fp16_valid, w_dec_fp16_ready;
logic [MX_NUM_LANES*BITW-1:0] w_dec_fp16_data;
logic w_dec_val_ready;
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
  .mx_format_i      ( cntrl_flags.mx_format   ),
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

// ---------------------------------------------------------------
//  Slot consume: driven by dedicated decoder acceptance
// ---------------------------------------------------------------
logic x_slot_pair_valid, w_slot_pair_valid;
assign x_slot_pair_valid = cntrl_flags.mx_enable && x_slot_valid && x_slot_exp_valid;
assign w_slot_pair_valid = cntrl_flags.mx_enable && w_slot_valid && w_slot_exp_valid;

assign consume_x_slot = x_slot_pair_valid && x_dec_val_ready;
assign consume_w_slot = w_slot_pair_valid && w_dec_val_ready;

// ---------------------------------------------------------------
//  Dedicated X decoder
// ---------------------------------------------------------------
redmule_mx_decoder #(
  .DATA_W    ( MX_DATA_W    ),
  .BITW      ( BITW         ),
  .NUM_LANES ( MX_NUM_LANES ),
  .TAG_WIDTH ( 2            )
) i_mx_decoder_x (
  .clk_i               ( clk_i                                      ),
  .rst_ni              ( rst_ni                                     ),
  .mx_format_i         ( cntrl_flags.mx_format                      ),
  .mx_val_valid_i      ( x_slot_pair_valid                          ),
  .mx_val_ready_o      ( x_dec_val_ready                            ),
  .mx_val_data_i       ( x_slot_data                                ),
  .mx_exp_valid_i      ( x_slot_pair_valid                          ),
  .mx_exp_ready_o      (                                            ),
  .mx_exp_data_i       ( {{(MX_EXP_VECTOR_W-8){1'b0}}, x_slot_exp} ),
  .vector_shared_exp_i ( 1'b0                                       ),
  .tag_i               ( 2'b00                                      ),
  .tag_o               (                                            ),
  .fp16_valid_o        ( x_dec_fp16_valid                           ),
  .fp16_ready_i        ( x_dec_fp16_ready                           ),
  .fp16_data_o         ( x_dec_fp16_data                            )
);

// ---------------------------------------------------------------
//  Dedicated W decoder
// ---------------------------------------------------------------
redmule_mx_decoder #(
  .DATA_W    ( MX_DATA_W    ),
  .BITW      ( BITW         ),
  .NUM_LANES ( MX_NUM_LANES ),
  .TAG_WIDTH ( 2            )
) i_mx_decoder_w (
  .clk_i               ( clk_i              ),
  .rst_ni              ( rst_ni             ),
  .mx_format_i         ( cntrl_flags.mx_format ),
  .mx_val_valid_i      ( w_slot_pair_valid  ),
  .mx_val_ready_o      ( w_dec_val_ready    ),
  .mx_val_data_i       ( w_slot_data        ),
  .mx_exp_valid_i      ( w_slot_pair_valid  ),
  .mx_exp_ready_o      (                    ),
  .mx_exp_data_i       ( w_slot_exp         ),
  .vector_shared_exp_i ( 1'b1              ),
  .tag_i               ( 2'b00             ),
  .tag_o               (                    ),
  .fp16_valid_o        ( w_dec_fp16_valid   ),
  .fp16_ready_i        ( w_dec_fp16_ready   ),
  .fp16_data_o         ( w_dec_fp16_data    )
);

// ---------------------------------------------------------------
//  Route decoder outputs directly (no arbiter/tag routing)
// ---------------------------------------------------------------
assign x_mx_fp16_valid    = x_dec_fp16_valid;
assign x_mx_fp16_data     = x_dec_fp16_data;
assign x_dec_fp16_ready   = x_mx_fp16_ready;

assign w_dec_to_buf_valid = w_dec_fp16_valid;
assign w_dec_fp16_ready   = w_dec_buf_ready;

// ---------------------------------------------------------------
//  W decoder output elastic buffer
//  Smooths burstiness between W decoder and downstream packing.
// ---------------------------------------------------------------
localparam int unsigned W_DEC_BUF_DEPTH = 4;
localparam int unsigned W_DEC_BUF_DW    = MX_NUM_LANES * BITW;
localparam int unsigned W_DEC_BUF_PTR_W = $clog2(W_DEC_BUF_DEPTH);
localparam int unsigned W_DEC_BUF_CNT_W = $clog2(W_DEC_BUF_DEPTH + 1);

logic [W_DEC_BUF_DW-1:0]    w_dec_buf_mem [W_DEC_BUF_DEPTH];
logic [W_DEC_BUF_PTR_W-1:0] w_dec_buf_head_q, w_dec_buf_tail_q;
logic [W_DEC_BUF_CNT_W-1:0] w_dec_buf_count_q;

logic w_dec_buf_push, w_dec_buf_pop;

assign w_dec_buf_ready    = (w_dec_buf_count_q < W_DEC_BUF_CNT_W'(W_DEC_BUF_DEPTH));
assign w_dec_buf_push     = w_dec_to_buf_valid && w_dec_buf_ready;
assign w_dec_buf_pop      = w_buf_to_mux_valid && w_buf_to_mux_ready;

assign w_buf_to_mux_valid = (w_dec_buf_count_q != '0);
assign w_buf_to_mux_data  = w_dec_buf_mem[w_dec_buf_head_q];

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    w_dec_buf_head_q  <= '0;
    w_dec_buf_tail_q  <= '0;
    w_dec_buf_count_q <= '0;
  end else if (clear) begin
    w_dec_buf_head_q  <= '0;
    w_dec_buf_tail_q  <= '0;
    w_dec_buf_count_q <= '0;
  end else begin
    if (w_dec_buf_push)
      w_dec_buf_tail_q <= (w_dec_buf_tail_q == W_DEC_BUF_PTR_W'(W_DEC_BUF_DEPTH-1)) ?
                          '0 : w_dec_buf_tail_q + 1'b1;
    if (w_dec_buf_pop)
      w_dec_buf_head_q <= (w_dec_buf_head_q == W_DEC_BUF_PTR_W'(W_DEC_BUF_DEPTH-1)) ?
                          '0 : w_dec_buf_head_q + 1'b1;
    case ({w_dec_buf_push, w_dec_buf_pop})
      2'b10:   w_dec_buf_count_q <= w_dec_buf_count_q + 1'b1;
      2'b01:   w_dec_buf_count_q <= w_dec_buf_count_q - 1'b1;
      default: ;
    endcase
  end
end

always_ff @(posedge clk_i) begin
  if (w_dec_buf_push)
    w_dec_buf_mem[w_dec_buf_tail_q] <= w_dec_fp16_data;
end

// ---- W decode position tracker for K-tile-aware packing ----
// The input_mux packs decoded MX chunks into bus-width FIFO entries.
// The packing ratio depends on which K-tile the data belongs to:
//   Full K-tiles: D/MX_NUM_LANES chunks per row (=2 for 64/32)
//   Leftover K-tile: LEFTOVERS/MX_NUM_LANES chunks per row (=1 for 32/32)
// Data arrives K-tile-major (K0 rows first, then K1 rows), so a position
// counter on W decode acceptances determines the correct packing.
// Without this, the scheduler's live w_cols_iter_q drives packing, which
// can mismatch the data when the decoder runs ahead of the scheduler.
localparam int unsigned W_CHUNKS_FULL_K = (TOT_DEPTH + MX_NUM_LANES - 1) / MX_NUM_LANES;

logic [15:0] w_dec_pos_q;
logic        w_dec_accept;
logic        w_has_k_leftovers;
logic [7:0]  w_chunks_lftovr_k;
logic [15:0] w_num_full_k_tiles;
logic [15:0] w_slots_full_k;
logic [15:0] w_slots_per_pass;

assign w_has_k_leftovers  = (reg_file.hwpe_params[LEFTOVERS][7:0] != '0);
assign w_chunks_lftovr_k  = w_has_k_leftovers ?
    8'((reg_file.hwpe_params[LEFTOVERS][7:0] + MX_NUM_LANES - 1) / MX_NUM_LANES) :
    8'(W_CHUNKS_FULL_K);
assign w_num_full_k_tiles = w_has_k_leftovers ?
    (reg_file.hwpe_params[W_ITERS][15:0] - 16'd1) :
    reg_file.hwpe_params[W_ITERS][15:0];
assign w_slots_full_k     = reg_file.hwpe_params[W_ITERS][31:16]
                            * 16'(W_CHUNKS_FULL_K)
                            * w_num_full_k_tiles;
assign w_slots_per_pass   = w_slots_full_k
                            + (w_has_k_leftovers
                               ? (reg_file.hwpe_params[W_ITERS][31:16] * 16'(w_chunks_lftovr_k))
                               : 16'd0);

assign w_dec_accept = mx_mode_active && w_buf_to_mux_valid && w_buf_to_mux_ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    w_dec_pos_q <= '0;
  end else if (clear) begin
    w_dec_pos_q <= '0;
  end else if (w_dec_accept) begin
    if (w_dec_pos_q == w_slots_per_pass - 16'd1)
      w_dec_pos_q <= '0;
    else
      w_dec_pos_q <= w_dec_pos_q + 16'd1;
  end
end

// X row chunking for MX mode (analogous to W K-tile leftover handling).
// With N-tile-major memory layout, all data for one N-tile arrives before the next.
// Each full N-tile has TILE / MX_NUM_LANES chunks per M-row packed per beat.
// When N is not a multiple of TILE, the last N-tile has fewer chunks per row.
// A position counter on X decode acceptances determines the correct packing.
localparam int unsigned X_CHUNKS_FULL_N = TOT_DEPTH / MX_NUM_LANES;  // = 2

logic [15:0] x_dec_pos_q;
logic        x_dec_accept;
logic        x_has_n_leftovers;
logic [7:0]  x_chunks_lftovr_n;
logic [15:0] x_num_full_n_tiles;
logic [15:0] x_slots_full_n;
logic [15:0] x_slots_per_m_tile;

// LEFTOVERS[23:16] = x_cols_lftovr (systolic FP16 element count for leftover N-tile)
assign x_has_n_leftovers  = (reg_file.hwpe_params[LEFTOVERS][23:16] != '0);
assign x_chunks_lftovr_n  = x_has_n_leftovers ?
    8'((reg_file.hwpe_params[LEFTOVERS][23:16] + MX_NUM_LANES - 1) / MX_NUM_LANES) :
    8'(X_CHUNKS_FULL_N);
assign x_num_full_n_tiles = x_has_n_leftovers ?
    (reg_file.hwpe_params[X_ITERS][15:0] - 16'd1) :
    reg_file.hwpe_params[X_ITERS][15:0];

// Slots in full N-tiles per M-tile: num_full_n_tiles × ARRAY_WIDTH × X_CHUNKS_FULL_N
assign x_slots_full_n = x_num_full_n_tiles
                         * 16'(ARRAY_WIDTH)
                         * 16'(X_CHUNKS_FULL_N);

// Total slots per M-tile: full + leftover
assign x_slots_per_m_tile = x_slots_full_n
    + (x_has_n_leftovers
       ? (16'(ARRAY_WIDTH) * 16'(x_chunks_lftovr_n))
       : 16'd0);

// Count X decode acceptances (decoder → input_mux handshake)
assign x_dec_accept = mx_mode_active && x_mx_fp16_valid && x_mx_fp16_ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni)
    x_dec_pos_q <= '0;
  else if (clear)
    x_dec_pos_q <= '0;
  else if (x_dec_accept) begin
    if (x_dec_pos_q == x_slots_per_m_tile - 16'd1)
      x_dec_pos_q <= '0;
    else
      x_dec_pos_q <= x_dec_pos_q + 16'd1;
  end
end

// Row chunking: X uses position-aware N-tile packing (like W for K-tiles).
assign x_row_chunks = mx_mode_active ?
    ((x_dec_pos_q < x_slots_full_n) ? 8'(X_CHUNKS_FULL_N) : x_chunks_lftovr_n) :
    ((x_valid_lanes == '0) ? 8'd1 :
     ((x_valid_lanes + MX_NUM_LANES - 1) / MX_NUM_LANES));
assign w_row_chunks = mx_mode_active ?
    ((w_dec_pos_q < w_slots_full_k) ? 8'(W_CHUNKS_FULL_K) : w_chunks_lftovr_k) :
    ((w_valid_lanes == '0) ? 8'd1 :
     ((w_valid_lanes + MX_NUM_LANES - 1) / MX_NUM_LANES));

// Instantiate MX input mux
redmule_mx_input_mux #(
  .DATAW_ALIGN  ( DATAW_ALIGN  ),
  .BITW         ( BITW         ),
  .MX_NUM_LANES ( MX_NUM_LANES )
) i_mx_input_mux (
  .clk_i             ( clk_i               ),
  .rst_ni            ( rst_ni              ),
  .clear_i           ( clear               ),
  .mx_enable_i        ( cntrl_flags.mx_enable ),
  .target_is_x_i      ( 1'b1                  ),
  .target_is_w_i      ( 1'b1                  ),
  .x_row_chunks_i     ( x_row_chunks       ),
  .w_row_chunks_i     ( w_row_chunks       ),
  .x_raw_i            ( x_buffer_raw       ),
  .w_raw_i            ( w_buffer_raw      ),
  .x_decoded_valid_i  ( x_mx_fp16_valid    ),
  .w_decoded_valid_i  ( w_buf_to_mux_valid ),
  .x_decoded_ready_o  ( x_mx_fp16_ready    ),
  .w_decoded_ready_o  ( w_buf_to_mux_ready ),
  .x_decoded_data_i   ( x_mx_fp16_data     ),
  .w_decoded_data_i   ( w_buf_to_mux_data  ),
  .x_muxed_o          ( x_buffer_packed    ),
  .w_muxed_o          ( w_buffer_packed    )
);

// Legacy X/W load path consumes one logical row per beat.
// Unpack MX-packed beats (2 rows @1024b) back into row beats at this boundary.
logic x_mx_unpack_pending, w_mx_unpack_pending;

redmule_mx_beat_unpack #(
  .DATAW_ALIGN  ( DATAW_ALIGN  ),
  .BITW         ( BITW         ),
  .MX_NUM_LANES ( MX_NUM_LANES )
) i_x_mx_beat_unpack (
  .clk_i       ( clk_i            ),
  .rst_ni      ( rst_ni           ),
  .clear_i     ( clear            ),
  .mx_enable_i ( cntrl_flags.mx_enable ),
  .in_i        ( x_buffer_packed  ),
  .out_o       ( x_buffer_muxed   ),
  .pending_o   ( x_mx_unpack_pending )
);

redmule_mx_beat_unpack #(
  .DATAW_ALIGN  ( DATAW_ALIGN  ),
  .BITW         ( BITW         ),
  .MX_NUM_LANES ( MX_NUM_LANES )
) i_w_mx_beat_unpack (
  .clk_i       ( clk_i            ),
  .rst_ni      ( rst_ni           ),
  .clear_i     ( clear            ),
  .mx_enable_i ( cntrl_flags.mx_enable ),
  .in_i        ( w_buffer_packed  ),
  .out_o       ( w_buffer_muxed   ),
  .pending_o   ( w_mx_unpack_pending )
);

// Decoder ready routing
// Decoder ready routing handled directly in decoder output wiring above

hwpe_stream_fifo #(
  .DATA_WIDTH     ( DATAW_ALIGN   ),
  .FIFO_DEPTH     ( 16             )  // Testing smaller depth
) i_x_buffer_fifo (
  .clk_i          ( clk_i           ),
  .rst_ni         ( rst_ni          ),
  .clear_i        ( clear           ),
  .flags_o        ( x_fifo_flgs     ),
  .push_i         ( x_buffer_muxed  ),
  .pop_o          ( x_buffer_fifo   )
);

// W buffer FIFO with replay capability for M-tile boundary SCM priming
logic w_fifo_mark, w_fifo_rewind, w_fifo_replaying;

redmule_w_rewind_fifo #(
  .DATA_WIDTH     ( DATAW_ALIGN   ),
  .FIFO_DEPTH     ( 16            ),
  .REPLAY_DEPTH   ( 32            )
) i_w_buffer_fifo (
  .clk_i          ( clk_i              ),
  .rst_ni         ( rst_ni             ),
  .clear_i        ( clear              ),
  .mark_i         ( w_fifo_mark        ),
  .rewind_i       ( w_fifo_rewind      ),
  .flags_o        ( w_fifo_flgs        ),
  .replaying_o    ( w_fifo_replaying   ),
  .push_i         ( w_buffer_muxed     ),
  .pop_o          ( w_buffer_fifo      )
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

// Detect replay end: reset W buffer read counters to align with scheduler
logic w_replaying_prev_q, w_replay_end_pulse;
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) w_replaying_prev_q <= 1'b0;
  else         w_replaying_prev_q <= w_fifo_replaying;
end
assign w_replay_end_pulse = w_replaying_prev_q && !w_fifo_replaying;

// Shadow width mask from scheduler (LEFTOVERS[7:0], 0 = full tile)
logic [7:0] w_shadow_width_raw;
logic [$clog2(TOT_DEPTH):0] shadow_width_mask;
assign shadow_width_mask = (w_shadow_width_raw != '0)
                           ? w_shadow_width_raw
                           : TOT_DEPTH;

redmule_w_buffer #(
  .DW         ( DATAW_ALIGN         ),
  .FpFormat   ( FpFormat            ),
  .Height     ( Height              )
) i_w_buffer  (
  .clk_i            ( clk_i              ),
  .rst_ni           ( rst_ni             ),
  .clear_i          ( clear              ),
  .scm_clear_i      ( w_scm_clear        ),
  .cnt_reset_i      ( 1'b0               ),
  .shadow_capture_i ( w_shadow_capture   ),
  .shadow_bypass_i  ( w_shadow_bypass    ),
  .shadow_width_i   ( shadow_width_mask   ),
  .ctrl_i           ( w_buffer_ctrl      ),
  .flags_o          ( w_buffer_flgs      ),
  .w_buffer_o       ( w_buffer_q         ),
  .w_buffer_i       ( w_buffer_fifo.data )
);

logic [Width-1:0][BITW-1:0] z_buffer_d, y_bias_q, z_buffer_d_muxed;

// z_buffer_d_muxed: Always use z_buffer_d (MX bypass happens at FIFO input, not here)
assign z_buffer_d_muxed = z_buffer_d;

// Y bias register signals (must be declared before Z buffer instantiation)
logic [Width-1:0][BITW-1:0] y_bias_from_yreg;
logic [$clog2(Width)-1:0] z_buf_w_index;
logic [$clog2(DATAW_ALIGN/BITW)-1:0] z_buf_d_index;
logic y_reg_lock;  // From scheduler: locks Y register during y_push restart
logic sched_y_push_en_ungated;  // y_push_en && ~stall_engine (for Y register's own counter)
logic m_tile_transition;  // Active during M-tile z_avail+drain (W output gated to zero)
logic w_scm_clear;        // Pulse: clear W buffer SCM at M-tile boundary
logic w_shadow_capture;   // Shadow reg file capture during M0 K0
logic w_shadow_bypass;    // Shadow bypass during M1 first H loads

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
  .w_index_o     ( z_buf_w_index      ),
  .d_index_o     (                    ),  // Not used (Y register has own counter)
  .y_buffer_i    ( y_buffer_fifo.data ),
  .z_buffer_i    ( z_buffer_d_muxed   ),
  .y_buffer_o    ( y_bias_q           ),
  .z_buffer_o    ( z_buffer_q.data    ),
  .z_strb_o      ( z_buffer_q.strb    )
);

// Y bias register: shadow copy that survives z_avail fill overwrites.

redmule_y_bias_reg #(
  .DW       ( DATAW_ALIGN ),
  .FpFormat ( FpFormat     ),
  .Width    ( Width        )
) i_y_bias_reg (
  .clk_i        ( clk_i                       ),
  .rst_ni       ( rst_ni                      ),
  .clear_i      ( clear                       ),
  .write_en_i   ( z_buffer_flgs.y_ready && !y_reg_lock ),  // Locked during y_push restart
  .write_addr_i ( z_buf_w_index               ),
  .write_data_i ( y_buffer_fifo.data          ),
  // Own read counter: driven by y_push_en && ~stall_engine (ungated by y_reg_lock)
  .read_en_i    ( sched_y_push_en_ungated     ),
  .y_height_i   ( z_buffer_ctrl.y_height      ),
  .read_rst_i   ( y_reg_lock                  ),  // Reset at y_push restart start
  .read_data_o  ( y_bias_from_yreg            )
);

`ifndef SYNTHESIS
// Debug: Y register write and read monitoring
always @(posedge clk_i) begin
  if (z_buffer_flgs.y_ready)
    $display("[DBG][YREG] t=%0t WRITE w_idx=%0d/%0d data[0:1]=0x%04h 0x%04h",
             $time, z_buf_w_index, z_buffer_ctrl.y_width,
             y_buffer_fifo.data[15:0], y_buffer_fifo.data[31:16]);
  if (z_buffer_ctrl.y_push_enable && y_bias_from_yreg !== y_bias_q)
    $display("[DBG][YREG] t=%0t MISMATCH d_idx=%0d yreg[0]=0x%04h zbuf[0]=0x%04h",
             $time, z_buf_d_index, y_bias_from_yreg[0], y_bias_q[0]);
end
`endif

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

// ============ DEBUG: Incrementing W override ============
// When +W_INCR_OVERRIDE is passed, replaces W buffer output with incrementing
// FP16 values so engine consumption order is immediately visible.
// Each shift cycle: w[h] = 0x4b00 + shift_count (same value for all h)
// This makes fill_shift output directly reveal which W shift produced each K position.
`ifndef SYNTHESIS
logic [Height-1:0][BITW-1:0] w_engine_input;
bit dbg_w_incr;
initial dbg_w_incr = $test$plusargs("W_INCR_OVERRIDE");

logic [15:0] w_shift_cnt_dbg;
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni || clear) begin
    w_shift_cnt_dbg <= '0;
  end else if (w_buffer_ctrl.shift) begin
    w_shift_cnt_dbg <= w_shift_cnt_dbg + 1;
  end
end

always_comb begin
  if (dbg_w_incr) begin
    for (int h = 0; h < Height; h++) begin
      w_engine_input[h] = 16'h4b00 + w_shift_cnt_dbg[9:0];
    end
  end else begin
    w_engine_input = w_buffer_q;
  end
end

// Dump engine output during fill when override is active
bit dbg_w_incr_fill;
initial dbg_w_incr_fill = $test$plusargs("W_INCR_OVERRIDE");
always @(posedge clk_i) begin
  if (dbg_w_incr_fill && z_buffer_ctrl.fill) begin
    $display("[DBG][WINCR] fill z_buf_d r0=0x%04h r1=0x%04h r15=0x%04h r31=0x%04h",
             z_buffer_d[0], z_buffer_d[1], z_buffer_d[15], z_buffer_d[31]);
  end
end
`else
logic [Height-1:0][BITW-1:0] w_engine_input;
assign w_engine_input = w_buffer_q;
`endif
// ============ END DEBUG ============

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
  .y_bias_i           ( y_bias_from_yreg  ),  // From Y register (survives z_avail fill)
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
  .MX_DATA_W     ( MX_DATA_W     ),
  .BITW          ( BITW          ),
  .Width         ( Width         ),
  .Height        ( Height        ),
  .SysDataWidth  ( SysDataWidth  ),
  .MX_NUM_LANES  ( MX_NUM_LANES  )
) i_mx_output_stage (
  .clk_i              ( clk_i                   ),
  .rst_ni             ( rst_ni                  ),
  .clear_i            ( clear                   ),
  .mx_enable_i        ( cntrl_flags.mx_enable   ),
  .mx_format_i        ( cntrl_flags.mx_format   ),
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
  .cntrl_streamer_o  ( cntrl_streamer  ),
  .x_exp_total_count_o ( x_exp_total_count ),
  .w_exp_total_count_o ( w_exp_total_count ),
  .x_exp_segment_size_o ( x_exp_segment_size )
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
  .mx_enable_i       ( cntrl_flags.mx_enable ),
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
  .mx_x_pending_i    ( x_mx_unpack_pending ),
  .mx_w_pending_i    ( w_mx_unpack_pending ),
  .w_replaying_i     ( w_fifo_replaying    ),
  .reg_enable_o      ( reg_enable          ),
  .cntrl_engine_o    ( cntrl_engine        ),
  .cntrl_x_buffer_o  ( x_buffer_ctrl       ),
  .cntrl_w_buffer_o  ( w_buffer_ctrl       ),
  .cntrl_z_buffer_o  ( z_buffer_ctrl       ),
  .flgs_scheduler_o  ( flgs_scheduler      ),
  .x_exp_mark_o      ( x_exp_mark          ),
  .x_exp_rewind_o    ( x_exp_rewind        ),
  .w_exp_mark_o      ( w_exp_mark          ),
  .w_exp_rewind_o    ( w_exp_rewind        ),
  .y_reg_lock_o      ( y_reg_lock          ),
  .y_push_en_ungated_o ( sched_y_push_en_ungated ),
  .m_tile_transition_o ( m_tile_transition       ),
  .w_scm_clear_o       ( w_scm_clear             ),
  .w_fifo_mark_o       ( w_fifo_mark             ),
  .w_fifo_rewind_o     ( w_fifo_rewind           ),
  .w_shadow_capture_o  ( w_shadow_capture        ),
  .w_shadow_bypass_o   ( w_shadow_bypass         ),
  .w_shadow_width_o    ( w_shadow_width_raw      )
);

endmodule : redmule_top
