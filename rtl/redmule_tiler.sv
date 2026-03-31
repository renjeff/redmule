// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
// Francesco Conti <f.conti@unibo.it>

module redmule_tiler
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
(
  input  logic              clk_i      ,
  input  logic              rst_ni     ,
  input  logic              clear_i    ,
  input  logic              setback_i  ,
  input  logic              start_cfg_i,
  input  ctrl_regfile_t     reg_file_i ,
  output logic              valid_o    ,
  output ctrl_regfile_t     reg_file_o
);

logic clk_en;
logic clk_int;

redmule_config_t config_d, config_q;

always_ff @(posedge clk_i, negedge rst_ni) begin: clock_gate_enabler
  if (~rst_ni) begin
    clk_en <= 1'b0;
  end else begin
    if (clear_i || setback_i) begin
      clk_en <= 1'b0;
    end else if (start_cfg_i) begin
      clk_en <= 1'b1;
    end
  end
end

tc_clk_gating i_tiler_clockg (
  .clk_i      ( clk_i   ),
  .en_i       ( clk_en  ),
  .test_en_i  ( '0      ),
  .clk_o      ( clk_int )
);

assign config_d.x_addr          = reg_file_i.hwpe_params[X_ADDR];
assign config_d.w_addr          = reg_file_i.hwpe_params[W_ADDR];
assign config_d.z_addr          = reg_file_i.hwpe_params[Z_ADDR];
assign config_d.x_exp_addr      = reg_file_i.hwpe_params[X_EXP_ADDR];
assign config_d.w_exp_addr      = reg_file_i.hwpe_params[W_EXP_ADDR];
assign config_d.m_size          = reg_file_i.hwpe_params[MCFIG0][15: 0];
assign config_d.k_size          = reg_file_i.hwpe_params[MCFIG0][31:16];
assign config_d.n_size          = reg_file_i.hwpe_params[MCFIG1][15: 0];
assign config_d.gemm_ops        = gemm_op_e' (reg_file_i.hwpe_params[MACFG][12:10]);
assign config_d.gemm_input_fmt  = gemm_fmt_e'(reg_file_i.hwpe_params[MACFG][ 9: 7]);
assign config_d.gemm_output_fmt = gemm_fmt_e'(reg_file_i.hwpe_params[MACFG][ 9: 7]);

// MX mode enable flag (bit 16 of MACFG/ARITH register)
logic mx_enable;
assign mx_enable = reg_file_i.hwpe_params[MACFG][16];
mx_format_e mx_format;
assign mx_format = mx_format_e'(reg_file_i.hwpe_params[MACFG][19:17]);

// TILE size for iteration calculations. Match the actual TCDM beat width so we
// request the correct number of beats even when ARRAY_HEIGHT*(PIPE_REGS+1)
// exceeds DATAW/BITW.
localparam int unsigned TILE = TOT_DEPTH;

// Runtime pack factor as fraction: elements_per_beat / FP16_elements_per_beat
// FP8:  128/64 = 2/1.   FP4: 256/64 = 4/1.   FP6: 160/64 = 5/2.
logic [3:0] mx_pack_num;  // numerator
logic [1:0] mx_pack_den;  // denominator
logic [2:0] mx_pack_factor;  // integer pack factor (for modules that need it)
always_comb begin
  case (mx_format)
    MX_FMT_E2M1: begin mx_pack_num = 4'd4; mx_pack_den = 2'd1; mx_pack_factor = 3'd4; end
    MX_FMT_E3M2,
    MX_FMT_E2M3: begin mx_pack_num = 4'd5; mx_pack_den = 2'd2; mx_pack_factor = 3'd2; end // integer approx for non-fraction uses
    default:     begin mx_pack_num = 4'd2; mx_pack_den = 2'd1; mx_pack_factor = 3'd2; end
  endcase
end

// Unpack m_size and n_size for X buffer and systolic control
// FP4: 4 elements per 16-bit word. All others: 2 elements per word.
logic [15:0] m_size_for_x_buffer;
logic [15:0] n_size_for_systolic;
always_comb begin
  if (!mx_enable) begin
    m_size_for_x_buffer = config_d.m_size;
    n_size_for_systolic = config_d.n_size;
  end else if (mx_format == MX_FMT_E2M1) begin
    m_size_for_x_buffer = config_d.m_size << 2;  // * 4
    n_size_for_systolic = config_d.n_size << 2;
  end else begin
    m_size_for_x_buffer = config_d.m_size << 1;  // * 2
    n_size_for_systolic = config_d.n_size << 1;
  end
end

// Calculating the number of iterations alng the two dimensions of the X matrix
// X buffer iterations need UNPACKED sizes for correct buffer allocation
logic [15:0] x_rows_iter_nolftovr;
logic [15:0] x_cols_iter_nolftovr;
assign x_rows_iter_nolftovr = m_size_for_x_buffer/ARRAY_WIDTH;  // Use unpacked m_size
assign x_cols_iter_nolftovr = n_size_for_systolic/TILE;          // Use unpacked n_size

// Memory iterations use PACKED sizes for correct TCDM fetch count
logic [15:0] mem_x_rows_iter_nolftovr;
logic [15:0] mem_x_cols_iter_nolftovr;
assign mem_x_rows_iter_nolftovr = config_d.m_size/ARRAY_WIDTH;  // Use packed m_size for memory
assign mem_x_cols_iter_nolftovr = config_d.n_size/TILE;          // Use packed n_size for memory

// Calculating the number of iterations along the two dimensions of the W matrix
logic [15:0] w_cols_iter_nolftovr;
logic [15:0] w_rows_iter_lftovr,
             w_rows_iter_nolftovr;
assign w_cols_iter_nolftovr = config_d.k_size/TILE;
assign w_rows_iter_lftovr = w_rows_iter_nolftovr + ARRAY_HEIGHT - config_d.w_rows_lftovr;
assign w_rows_iter_nolftovr = n_size_for_systolic;  // Unpacked for systolic control

// Calculating the residuals along the input dimensions
// Use unpacked sizes for X buffer pad allocation (width and slots)
assign config_d.x_rows_lftovr = m_size_for_x_buffer - (x_rows_iter_nolftovr*ARRAY_WIDTH);
assign config_d.x_cols_lftovr = n_size_for_systolic - (x_cols_iter_nolftovr*TILE);

// Calculating the residuals along the weight dimensions
assign config_d.w_rows_lftovr = n_size_for_systolic - (ARRAY_HEIGHT*(n_size_for_systolic/ARRAY_HEIGHT));
assign config_d.w_cols_lftovr = config_d.k_size - (w_cols_iter_nolftovr*TILE);

// Calculate w_cols, x_cols, x_rows iterations (for X buffer control)
assign config_d.w_cols_iter = config_d.w_cols_lftovr != '0 ? w_cols_iter_nolftovr + 1 : w_cols_iter_nolftovr;
assign config_d.w_rows_iter = config_d.w_rows_lftovr != '0 ? w_rows_iter_lftovr       : w_rows_iter_nolftovr;
assign config_d.x_cols_iter = config_d.x_cols_lftovr != '0 ? x_cols_iter_nolftovr + 1 : x_cols_iter_nolftovr;
assign config_d.x_rows_iter = config_d.x_rows_lftovr != '0 ? x_rows_iter_nolftovr + 1 : x_rows_iter_nolftovr;

// Calculate memory iterations using PACKED sizes for tot_x_read
logic [7:0] mem_x_rows_lftovr, mem_x_cols_lftovr;
logic [15:0] mem_x_rows_iter, mem_x_cols_iter;
assign mem_x_rows_lftovr = config_d.m_size - (mem_x_rows_iter_nolftovr*ARRAY_WIDTH);
assign mem_x_cols_lftovr = config_d.n_size - (mem_x_cols_iter_nolftovr*TILE);
assign mem_x_rows_iter = mem_x_rows_lftovr != '0 ? mem_x_rows_iter_nolftovr + 1 : mem_x_rows_iter_nolftovr;
assign mem_x_cols_iter = mem_x_cols_lftovr != '0 ? mem_x_cols_iter_nolftovr + 1 : mem_x_cols_iter_nolftovr;

// Sequential multiplier x_rows x w_cols (for MEMORY addressing - uses packed sizes)
logic [31:0] x_rows_by_w_cols_iter;
logic        x_rows_by_w_cols_iter_valid, x_rows_by_w_cols_iter_valid_d, x_rows_by_w_cols_iter_valid_q;
logic        x_rows_by_w_cols_iter_ready;
hwpe_ctrl_seq_mult #(
  .AW ( 16 ),
  .BW ( 16 )
) i_x_rows_by_w_cols_seqmult (
  .clk_i    ( clk_i                         ),
  .rst_ni   ( rst_ni                        ),
  .clear_i  ( clear_i | setback_i           ),
  .start_i  ( start_cfg_i                   ),
  .a_i      ( mem_x_rows_iter               ),  // Use memory iterations (packed)
  .b_i      ( config_d.w_cols_iter          ),
  .invert_i ( 1'b0                          ),
  .valid_o  ( x_rows_by_w_cols_iter_valid_d ),
  .ready_o  ( x_rows_by_w_cols_iter_ready   ),
  .prod_o   ( x_rows_by_w_cols_iter         )
);

// Buffer-path product: x_rows_iter * w_cols_iter (unpacked M-tiles × K-tiles).
// Computed as a direct combinational product instead of a sequential multiplier.
// The sequential multiplier reads a_i/b_i continuously during its shift-and-add
// loop, but config_d.x_rows_iter depends on mx_enable which settles after
// start_cfg_i. By the time config_q latches (after the 3rd multiplier, ~48
// cycles later), config_d is guaranteed stable, so a combinational product
// sampled at latch time is correct.
logic [31:0] buf_x_rows_by_w_cols_iter;
assign buf_x_rows_by_w_cols_iter = config_d.x_rows_iter * config_d.w_cols_iter;
always_ff @(posedge clk_int or negedge rst_ni) begin
  if(~rst_ni) begin
    x_rows_by_w_cols_iter_valid_q <= '0;
    x_rows_by_w_cols_iter_valid <= '0;
  end else if(clear_i | setback_i) begin
    x_rows_by_w_cols_iter_valid_q <= '0;
    x_rows_by_w_cols_iter_valid <= '0;
  end else begin
    x_rows_by_w_cols_iter_valid_q <= x_rows_by_w_cols_iter_valid_d;
    x_rows_by_w_cols_iter_valid <= ~x_rows_by_w_cols_iter_valid_q & x_rows_by_w_cols_iter_valid_d;
  end
end

// Sequential multiplier x_rows x w_cols x x_cols
logic [47:0] x_rows_by_w_cols_by_x_cols_iter;
logic        x_rows_by_w_cols_by_x_cols_iter_valid;
logic        x_rows_by_w_cols_by_x_cols_iter_ready;
hwpe_ctrl_seq_mult #(
  .AW ( 16 ),
  .BW ( 32 )
) i_x_rows_by_w_cols_by_x_cols_seqmult (
  .clk_i    ( clk_int                               ),
  .rst_ni   ( rst_ni                                ),
  .clear_i  ( clear_i | setback_i                   ),
  .start_i  ( x_rows_by_w_cols_iter_valid           ),
  .a_i      ( mem_x_cols_iter                       ),  // Use memory iterations (packed)
  .b_i      ( x_rows_by_w_cols_iter                 ),
  .invert_i ( 1'b0                                  ),
  .valid_o  ( x_rows_by_w_cols_by_x_cols_iter_valid ),
  .ready_o  ( x_rows_by_w_cols_by_x_cols_iter_ready ),
  .prod_o   ( x_rows_by_w_cols_by_x_cols_iter       )
);

// Sequential multiplier x_rows x w_cols x w_rows
logic [47:0] x_rows_by_w_cols_by_w_rows_iter;
logic        x_rows_by_w_cols_by_w_rows_iter_valid;
logic        x_rows_by_w_cols_by_w_rows_iter_ready;
hwpe_ctrl_seq_mult #(
  .AW ( 16 ),
  .BW ( 32 )
) i_x_rows_by_w_cols_by_w_rows_seqmult (
  .clk_i    ( clk_int                               ),
  .rst_ni   ( rst_ni                                ),
  .clear_i  ( clear_i | setback_i                   ),
  .start_i  ( x_rows_by_w_cols_iter_valid           ),
  .a_i      ( config_d.w_rows_iter                  ),
  .b_i      ( x_rows_by_w_cols_iter                 ),
  .invert_i ( 1'b0                                  ),
  .valid_o  ( x_rows_by_w_cols_by_w_rows_iter_valid ),
  .ready_o  ( x_rows_by_w_cols_by_w_rows_iter_ready ),
  .prod_o   ( x_rows_by_w_cols_by_w_rows_iter       )
);

// Calculate x_buffer_slots
logic [31:0] buffer_slots;
//assign buffer_slots = config_d.x_cols_lftovr/(DATAW/(ARRAY_HEIGHT*BITW));
//assign config_d.x_buffer_slots = ((config_d.x_cols_lftovr % (DATAW/(ARRAY_HEIGHT*BITW)) != '0) ? buffer_slots + 1 :
//                                                                                                buffer_slots) * (DATAW/(ARRAY_HEIGHT*BITW));

assign buffer_slots = config_d.x_cols_lftovr/ARRAY_HEIGHT;
assign config_d.x_buffer_slots =
    (((config_d.x_cols_lftovr % ARRAY_HEIGHT != '0) ? buffer_slots + 1 : buffer_slots) * ARRAY_HEIGHT);


// Calculating the number of total stores (uses buffer iterations for actual computations)
assign config_d.tot_stores = buf_x_rows_by_w_cols_iter[15:0];

assign config_d.stage_1_rnd_mode = config_d.gemm_ops == MATMUL ? RNE :
                                   config_d.gemm_ops == GEMM   ? RNE :
                                   config_d.gemm_ops == ADDMAX ? RNE :
                                   config_d.gemm_ops == ADDMIN ? RNE :
                                   config_d.gemm_ops == MULMAX ? RNE :
                                   config_d.gemm_ops == MULMIN ? RNE :
                                   config_d.gemm_ops == MAXMIN ? RTZ :
                                                                 RNE ;
assign config_d.stage_2_rnd_mode = config_d.gemm_ops == MATMUL ? RNE :
                                   config_d.gemm_ops == GEMM   ? RNE :
                                   config_d.gemm_ops == ADDMAX ? RTZ :
                                   config_d.gemm_ops == ADDMIN ? RNE :
                                   config_d.gemm_ops == MULMAX ? RTZ :
                                   config_d.gemm_ops == MULMIN ? RNE :
                                   config_d.gemm_ops == MAXMIN ? RNE :
                                                                 RTZ;
assign config_d.stage_1_op       = config_d.gemm_ops == MATMUL ? FPU_FMADD :
                                   config_d.gemm_ops == GEMM   ? FPU_FMADD :
                                   config_d.gemm_ops == ADDMAX ? FPU_ADD :
                                   config_d.gemm_ops == ADDMIN ? FPU_ADD :
                                   config_d.gemm_ops == MULMAX ? FPU_MUL :
                                   config_d.gemm_ops == MULMIN ? FPU_MUL :
                                   config_d.gemm_ops == MAXMIN ? FPU_MINMAX :
                                                                 FPU_MINMAX;
assign config_d.stage_2_op       = FPU_MINMAX;
assign config_d.input_format     = config_d.gemm_input_fmt == Float16    ? FPU_FP16 :
                                   config_d.gemm_input_fmt == Float8     ? FPU_FP8 :
                                   config_d.gemm_input_fmt == Float16Alt ? FPU_FP16ALT :
                                                                           FPU_FP8ALT;
assign config_d.computing_format = config_d.gemm_output_fmt == Float16    ? FPU_FP16 :
                                   config_d.gemm_output_fmt == Float8     ? FPU_FP8 :
                                   config_d.gemm_output_fmt == Float16Alt ? FPU_FP16ALT :
                                                                            FPU_FP8ALT;
assign config_d.gemm_selection   = config_d.gemm_ops == MATMUL ? 1'b0 : 1'b1;

assign config_d.x_d1_stride = ((NumByte*BITW)/ADDR_W)*(((DATAW/BITW)*mem_x_cols_iter_nolftovr) + mem_x_cols_lftovr);  // Use memory iterations for X addressing
assign config_d.x_rows_offs = ARRAY_WIDTH*config_d.x_d1_stride;
// W replay count uses buffer-path (unpacked) M-tiles, not memory-path (packed).
// The engine replays W for each systolic M-tile (x_rows_iter), but the memory-path
// multiplier uses mem_x_rows_iter (packed, smaller). Using the buffer-path product
// ensures W_TOT_LEN provides enough beats for all M-tile replays.
logic [31:0] w_tot_len_raw;
assign w_tot_len_raw = config_d.w_rows_iter * buf_x_rows_by_w_cols_iter[15:0];
assign config_d.w_tot_len   = mx_enable ? (mx_format == MX_FMT_E2M1 ? ((w_tot_len_raw + 3) >> 2) : ((w_tot_len_raw + 1) >> 1))
                                        : w_tot_len_raw;
assign config_d.w_d0_stride = ((NumByte*BITW)/ADDR_W)*(((DATAW/BITW)*w_cols_iter_nolftovr) + config_d.w_cols_lftovr);
assign config_d.yz_tot_len  = ARRAY_WIDTH*buf_x_rows_by_w_cols_iter[15:0];  // Use buffer iterations for output
assign config_d.yz_d0_stride = config_d.w_d0_stride;
assign config_d.yz_d2_stride = ARRAY_WIDTH*config_d.w_d0_stride;
// Calculate tot_x_read: number of X memory-stream launches.
// In MX mode, one X stream launch covers ALL N-tiles (the MX decode pipeline
// handles N-tiling internally via buffer empty/refill cycles), so x_cols_iter
// must NOT be included.  In FP16 mode, each N-tile is a separate launch.
logic [31:0] tot_x_read_raw;
assign tot_x_read_raw = mx_enable
    ? (config_d.x_rows_iter * config_d.w_cols_iter)
    : (config_d.x_rows_iter * config_d.w_cols_iter * config_d.x_cols_iter);
assign config_d.tot_x_read   = tot_x_read_raw;
assign config_d.z_out_addr   = reg_file_i.hwpe_params[Z_OUT_ADDR];

// register configuration to avoid critical paths (maybe removable!)
bit dbg_tiler;
initial dbg_tiler = $test$plusargs("MX_DEBUG_DUMP");

always_ff @(posedge clk_int or negedge rst_ni) begin
  if(~rst_ni)
    config_q <= '0;
  else if (clear_i)
    config_q <= '0;
  else if(x_rows_by_w_cols_by_w_rows_iter_valid & x_rows_by_w_cols_by_w_rows_iter_ready) begin
    config_q <= config_d;
    if (dbg_tiler) begin
      $display("[DBG][TILER] mx_enable=%0d n_size=%0d n_size_for_systolic=%0d w_rows_iter=%0d w_cols_iter=%0d w_cols_lftovr=%0d",
               mx_enable, config_d.n_size, n_size_for_systolic, config_d.w_rows_iter,
               config_d.w_cols_iter, config_d.w_cols_lftovr);
      $display("[DBG][TILER] m_size=%0d m_size_for_x_buffer=%0d x_rows_lftovr=%0d x_rows_iter=%0d",
               config_d.m_size, m_size_for_x_buffer, config_d.x_rows_lftovr, config_d.x_rows_iter);
      $display("[DBG][TILER] x_cols_lftovr=%0d x_buffer_slots=%0d x_cols_iter=%0d LEFTOVERS[31:24]=%0d",
               config_d.x_cols_lftovr, config_d.x_buffer_slots, config_d.x_cols_iter, config_d.x_rows_lftovr);
      $display("[DBG][TILER] yz_tot_len=%0d w_tot_len=%0d tot_x_read=%0d tot_stores=%0d buf_xr_wc=%0d mem_xr_wc=%0d",
               config_d.yz_tot_len, config_d.w_tot_len, config_d.tot_x_read, config_d.tot_stores,
               buf_x_rows_by_w_cols_iter[15:0], x_rows_by_w_cols_iter[15:0]);
    end
  end
end

// generate output valid
always_ff @(posedge clk_int or negedge rst_ni) begin
  if(~rst_ni)
    valid_o <= '0;
  else if (clear_i | setback_i)
    valid_o <= '0;
  else if(x_rows_by_w_cols_by_w_rows_iter_ready)
    valid_o <= x_rows_by_w_cols_by_w_rows_iter_valid;
end

// re-encode in older RedMulE regfile map
assign reg_file_o.generic_params = '0;
assign reg_file_o.ext_data = '0;
assign reg_file_o.hwpe_params[REGFILE_N_MAX_IO_REGS-1:REDMULE_REGS] = '0;
assign reg_file_o.hwpe_params[      X_ADDR]        = config_d.x_addr; // do not register (these are straight from regfile)
assign reg_file_o.hwpe_params[      W_ADDR]        = config_d.w_addr; // do not register (these are straight from regfile)
assign reg_file_o.hwpe_params[      Z_ADDR]        = config_d.z_addr; // do not register (these are straight from regfile)
assign reg_file_o.hwpe_params[  X_EXP_ADDR]        = config_d.x_exp_addr; // do not register (these are straight from regfile)
assign reg_file_o.hwpe_params[  W_EXP_ADDR]        = config_d.w_exp_addr; // do not register (these are straight from regfile)
assign reg_file_o.hwpe_params[     X_ITERS][31:16] = config_q.x_rows_iter;
assign reg_file_o.hwpe_params[     X_ITERS][15: 0] = config_q.x_cols_iter;
assign reg_file_o.hwpe_params[     W_ITERS][31:16] = config_q.w_rows_iter;
assign reg_file_o.hwpe_params[     W_ITERS][15: 0] = config_q.w_cols_iter;
assign reg_file_o.hwpe_params[   LEFTOVERS][31:24] = config_q.x_rows_lftovr;
assign reg_file_o.hwpe_params[   LEFTOVERS][23:16] = config_q.x_cols_lftovr;
assign reg_file_o.hwpe_params[   LEFTOVERS][15: 8] = config_q.w_rows_lftovr;
assign reg_file_o.hwpe_params[   LEFTOVERS][ 7: 0] = config_q.w_cols_lftovr;
assign reg_file_o.hwpe_params[ LEFT_PARAMS][31:16] = config_q.tot_stores;
assign reg_file_o.hwpe_params[ LEFT_PARAMS][15: 0] = '0;
assign reg_file_o.hwpe_params[ X_D1_STRIDE]        = config_q.x_d1_stride;
assign reg_file_o.hwpe_params[   W_TOT_LEN]        = config_q.w_tot_len;
assign reg_file_o.hwpe_params[  TOT_X_READ]        = config_q.tot_x_read;
assign reg_file_o.hwpe_params[ W_D0_STRIDE]        = config_q.w_d0_stride;
assign reg_file_o.hwpe_params[   Z_TOT_LEN]        = config_q.yz_tot_len;
assign reg_file_o.hwpe_params[ Z_D0_STRIDE]        = config_q.yz_d0_stride;
assign reg_file_o.hwpe_params[ Z_D2_STRIDE]        = config_q.yz_d2_stride;
assign reg_file_o.hwpe_params[ X_ROWS_OFFS]        = config_q.x_rows_offs;
assign reg_file_o.hwpe_params[     X_SLOTS]        = config_q.x_buffer_slots;
assign reg_file_o.hwpe_params[ Z_OUT_ADDR]        = config_d.z_out_addr; // do not register (straight from regfile)
assign reg_file_o.hwpe_params[OP_SELECTION][31:29] = config_q.stage_1_rnd_mode;
assign reg_file_o.hwpe_params[OP_SELECTION][28:26] = config_q.stage_2_rnd_mode;
assign reg_file_o.hwpe_params[OP_SELECTION][25:21] = config_q.stage_1_op;
assign reg_file_o.hwpe_params[OP_SELECTION][20:16] = config_q.stage_2_op;
assign reg_file_o.hwpe_params[OP_SELECTION][15:13] = config_q.input_format;
assign reg_file_o.hwpe_params[OP_SELECTION][12:10] = config_q.computing_format;
assign reg_file_o.hwpe_params[OP_SELECTION][ 9: 1] = '0;
assign reg_file_o.hwpe_params[OP_SELECTION][0]     = config_q.gemm_selection;

endmodule: redmule_tiler
