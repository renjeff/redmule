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
  input  logic                             shadow_capture_i, // Capture current load into shadow reg file
  input  logic                             shadow_bypass_i,  // MUX output from shadow instead of SCM
  input  logic [$clog2(DW/BITW):0]         shadow_width_i,   // Zero-mask shadow for d >= shadow_width_i
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

// Shadow register file: stores first H rows of K0 data for M-tile bypass.
// Same layout as SCM: shadow[row][col][elm]. Captured during M0 K0 loads.
// Read using same addresses as SCM: PE h reads shadow[h][col_addr][el_addr].
logic [H-1:0][C-1:0][N_REGS:0][BITW-1:0] shadow_q;
logic [H-1:0][BITW-1:0] shadow_rdata;

// Shadow capture: write one row per LOAD_W cycle during M0 K0
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    shadow_q <= '0;
  end else if (clear_i) begin
    shadow_q <= '0;
  end else if (shadow_capture_i && buf_write_en) begin
    shadow_q[buf_write_addr] <= w_data;
`ifndef SYNTHESIS
    $display("[DBG][SHADOW_CAP] t=%0t w_row=%0d data[0]=%04h data[1]=%04h",
             $time, buf_write_addr, w_data[0], w_data[1]);
`endif
  end
end

// Shadow read addresses: must match SCM's internal registered copies.
// The SCM registers cols_read_offs_i and elms_read_addr_i on read_en_i (shift).
// This creates a 1-cycle delay. Mirror that delay here.
logic [EL_ADDR_W-1:0]  shadow_el_q;
logic [$clog2(C)-1:0]  shadow_col_q;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    shadow_el_q  <= '0;
    shadow_col_q <= '0;
  end else if (clear_i) begin
    shadow_el_q  <= '0;
    shadow_col_q <= '0;
  end else if (ctrl_i.shift) begin
    shadow_el_q  <= el_addr_q;
    shadow_col_q <= col_addr_q;
  end
end

// Shadow read with registered addresses (matches SCM output timing)
// Mask to zero for physical K-columns beyond the last K-tile's width,
// matching the SCM's zero-padding pattern from the leftover K-tile.
for (genvar r = 0; r < H; r++) begin : gen_shadow_read
  logic [$clog2(C)-1:0] shadow_col_addr;
  logic [$clog2(D):0] shadow_d_idx;  // physical K-column index
  assign shadow_col_addr = shadow_col_q >= r[$clog2(C)-1:0]
                           ? shadow_col_q - r[$clog2(C)-1:0]
                           : C[$clog2(C)-1:0] - (r[$clog2(C)-1:0] - shadow_col_q);
  assign shadow_d_idx = {shadow_col_addr, shadow_el_q};  // col*(N_REGS+1) + el
  assign shadow_rdata[r] = (shadow_d_idx < shadow_width_i)
                           ? shadow_q[r][shadow_col_addr][shadow_el_q]
                           : '0;
end

// Output mux
assign w_buffer_o = shadow_bypass_i ? shadow_rdata : scm_rdata;

`ifndef SYNTHESIS
// Check for mismatches between shadow (with masking) and SCM during bypass
always @(posedge clk_i) begin
  if (shadow_bypass_i && ctrl_i.shift) begin
    for (int r = 0; r < H; r++) begin
      if (scm_rdata[r] !== shadow_rdata[r]) begin
        $display("[MISMATCH] t=%0t PE=%0d scm=%04h shd=%04h el=%0d col=%0d",
                 $time, r, scm_rdata[r], shadow_rdata[r], shadow_el_q, shadow_col_q);
      end
    end
  end
end
`endif

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

  // Dump engine W outputs during bypass window (and a few cycles before/after)
  // to compare shadow vs SCM values seen by each PE
  always @(posedge clk_i) begin
    if (ctrl_i.shift && shadow_bypass_i) begin
      $display("[BYPASS_W] t=%0t scm[0]=%04h shd[0]=%04h out[0]=%04h scm[1]=%04h shd[1]=%04h out[1]=%04h el=%0d col=%0d",
               $time,
               scm_rdata[0], shadow_rdata[0], w_buffer_o[0],
               scm_rdata[1], shadow_rdata[1], w_buffer_o[1],
               shadow_el_q, shadow_col_q);
    end
  end

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
