// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
// Andrea Belano <andrea.belano2@unibo.it>
//

module redmule_w_buffer
  import fpnew_pkg::*;
  import redmule_pkg::*;
#(
  parameter int unsigned  DW        = 288               ,
  parameter fp_format_e   FpFormat  = FP16              ,
  parameter int unsigned  Height    = ARRAY_HEIGHT      , // Number of PEs per row
  parameter int unsigned  N_REGS    = PIPE_REGS         , // Number of registers per PE
  localparam int unsigned BITW      = fp_width(FpFormat), // Number of bits for the given format
  localparam int unsigned H         = Height            ,
  localparam int unsigned D         = DW/BITW
)(
  input  logic                             clk_i     ,
  input  logic                             rst_ni    ,
  input  logic                             clear_i   ,
  input  logic                             scm_clear_i,  // Clear SCM data + reset counters
  input  logic                             cnt_reset_i,  // Reset read counters only (preserve SCM data)
  input  w_buffer_ctrl_t                   ctrl_i    ,
  output w_buffer_flgs_t                   flags_o   ,
  output logic           [H-1:0][BITW-1:0] w_buffer_o,
  input  logic                    [DW-1:0] w_buffer_i
);

localparam int unsigned C         = (D+N_REGS)/(N_REGS+1);
localparam int unsigned EL_ADDR_W = $clog2(N_REGS+1);
localparam int unsigned EL_DATA_W = (N_REGS+1)*BITW;

logic [$clog2(H):0]            w_row;

logic [EL_ADDR_W-1:0]          el_addr_d, el_addr_q;
logic [$clog2(C)-1:0]          col_addr_d, col_addr_q;

logic [D-1:0][BITW-1:0]        w_data;

logic [H-1:0][$clog2(H)-1:0]   buffer_r_addr_d, buffer_r_addr_q;
logic [H-1:0]                  buffer_r_addr_valid_d, buffer_r_addr_valid_q;

logic                 buf_write_en;
logic [$clog2(H)-1:0] buf_write_addr;

for (genvar d = 0; d < D; d++) begin : gen_zero_padding
  assign w_data[d] = (d < ctrl_i.width && w_row < ctrl_i.height) ? w_buffer_i[(d+1)*BITW-1:d*BITW] : '0;
end

assign buf_write_en   = ctrl_i.load;
assign buf_write_addr = w_row;

// SCM output (active bank)
logic [H-1:0][BITW-1:0] scm_rdata;

redmule_w_buffer_scm #(
  .WORD_SIZE ( BITW     ),
  .ROWS      ( H        ),
  .COLS      ( C        ),
  .ELMS      ( N_REGS+1 )
) i_w_buf (
  .clk_i            ( clk_i                    ),
  .rst_ni           ( rst_ni                    ),
  .clear_i          ( clear_i                   ),
  .data_clear_i     ( scm_clear_i              ),
  .write_en_i       ( buf_write_en    ),
  .write_addr_i     ( buf_write_addr  ),
  .wdata_i          ( w_data          ),
  .read_en_i        ( ctrl_i.shift    ),
  .elms_read_addr_i ( el_addr_q       ),
  .cols_read_offs_i ( col_addr_q      ),
  .rows_read_addr_i ( buffer_r_addr_d ),
  .rdata_o          ( scm_rdata       )
);

assign w_buffer_o = scm_rdata;

assign flags_o.w_ready = buf_write_en;

always_comb begin : buffer_r_addr_assignment
  buffer_r_addr_q       = '0;
  buffer_r_addr_d       = '0;
  buffer_r_addr_valid_q = '0;
  buffer_r_addr_valid_d = '0;

  for (int h = 0; h < H; h++) begin
    buffer_r_addr_q[h] = h;
  end

  for (int h = 0; h < H; h++) begin
    buffer_r_addr_d[h] = h;
  end
end

// Write side

always_ff @(posedge clk_i or negedge rst_ni) begin : element_counter
  if(~rst_ni) begin
    el_addr_q <= '0;
  end else begin
    if (clear_i || cnt_reset_i)
      el_addr_q <= '0;
    else if (ctrl_i.shift)
      el_addr_q <= el_addr_d;
  end
end

always_ff @(posedge clk_i or negedge rst_ni) begin : section_counter
  if(~rst_ni) begin
    col_addr_q <= '0;
  end else begin
    if (clear_i || cnt_reset_i)
      col_addr_q <= '0;
    else if (ctrl_i.shift)
      col_addr_q <= col_addr_d;
  end
end

assign el_addr_d  = (el_addr_q == N_REGS) ? '0 : el_addr_q + 1;
assign col_addr_d = (el_addr_q == N_REGS) ? (col_addr_q == (C-1) ? '0 : col_addr_q + 1) : col_addr_q;

// Counter to track the number of shifts per row
always_ff @(posedge clk_i or negedge rst_ni) begin : row_load_counter
  if(~rst_ni) begin
    w_row <= '0;
  end else begin
    if (clear_i || w_row == H )
      w_row <= '0;
    else if (ctrl_i.load)
      w_row <= w_row + 1;
    else
      w_row <= w_row;
  end
end

`ifndef SYNTHESIS
  bit dbg_wbuf;
  initial dbg_wbuf = $test$plusargs("MX_WBUF_DUMP");

  always @(posedge clk_i) begin
    if (dbg_wbuf && ctrl_i.load) begin
      // Print element 57 (K=57): column 28, element 1
      $display("[DBG][WBUF] t=%0t row=%0d d57=0x%04h d56=0x%04h d58=0x%04h d25=0x%04h d0=0x%04h d31=0x%04h d32=0x%04h d63=0x%04h",
               $time, w_row,
               w_data[57], w_data[56], w_data[58],
               w_data[25], w_data[0], w_data[31], w_data[32], w_data[63]);
    end
  end
`endif

endmodule : redmule_w_buffer
