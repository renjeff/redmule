// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Andrea Belano <andrea.belano2@unibo.it>
//

module redmule_memory_scheduler
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
#(
  parameter int unsigned   DW   = DATAW,
  parameter int unsigned   W    = ARRAY_WIDTH,
  parameter int unsigned   H    = ARRAY_HEIGHT,
  parameter int unsigned   ELW  = BITW,
  localparam int unsigned  D    = TOT_DEPTH
) (
  input  logic                  clk_i            ,
  input  logic                  rst_ni           ,
  input  logic                  clear_i          ,
  input  logic                  z_priority_i     ,
  input  ctrl_regfile_t         reg_file_i       ,
  input  flgs_streamer_t        flgs_streamer_i  ,
  input  cntrl_scheduler_t      cntrl_scheduler_i,
  input  cntrl_flags_t          cntrl_flags_i    ,
  output cntrl_streamer_t       cntrl_streamer_o
);
  localparam int unsigned JMP = NumByte*(DATA_W/MemDw - 1);

  logic [31:0]        x_cols_offs_d, x_cols_offs_q;
  logic [31:0]        x_rows_offs_d, x_rows_offs_q;

  logic [15:0]        x_cols_iters_d, x_cols_iters_q,
                      x_rows_iters_d, x_rows_iters_q;

  logic [15:0]        w_iters_d, w_iters_q;

  logic [15:0]        tot_x_read_d, tot_x_read_q;

  // MX mode: latch addresses at first_load to survive regfile clearing
  logic [31:0]        x_addr_latched_q, w_addr_latched_q, z_addr_latched_q;
  logic [31:0]        x_exp_addr_latched_q, w_exp_addr_latched_q;

  logic [$clog2(W):0] num_x_reads;

  logic [15:0] m_size, n_size, k_size;
  logic [31:0] total_x_values, total_w_values;
  logic [31:0] x_exp_beats, w_exp_beats;

  assign m_size = reg_file_i.hwpe_params[MCFIG0][15:0];
  assign k_size = reg_file_i.hwpe_params[MCFIG0][31:16];
  assign n_size = reg_file_i.hwpe_params[MCFIG1][15:0];

  assign total_x_values = m_size * k_size;
  assign total_w_values = n_size * k_size;

  // Calculate exponent beats based on actual matrix dimensions
  // X exponents: 1 byte per block, blocks = (M*K)/32
  logic [31:0] x_blocks, w_blocks;
  logic [31:0] x_exp_bytes, w_exp_bytes;
  
  assign x_blocks = (total_x_values + 31) >> 5;  // ceil(M*K / 32)
  assign w_blocks = (total_w_values + 31) >> 5;  // ceil(N*K / 32)
  
  assign x_exp_bytes = x_blocks;              // 1 byte per X block
  assign w_exp_bytes = w_blocks;              // 1 byte per W block (same as X)
  
  assign x_exp_beats = (x_exp_bytes + 63) >> 6;  // ceil(x_exp_bytes / 64)
  assign w_exp_beats = (w_exp_bytes + 63) >> 6;  // ceil(w_exp_bytes / 64)

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_cols_iters_register
    if (~rst_ni) begin
        x_cols_iters_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        x_cols_iters_q <= '0;
      end else if (flgs_streamer_i.x_stream_source_flags.done) begin
        x_cols_iters_q <= x_cols_iters_d;
      end
    end
  end

  assign x_cols_iters_d = x_cols_iters_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1 ? '0 : x_cols_iters_q + 1;

  always_ff @(posedge clk_i or negedge rst_ni) begin : w_iters_register
    if (~rst_ni) begin
      w_iters_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        w_iters_q <= '0;
      end else if (flgs_streamer_i.x_stream_source_flags.done && x_cols_iters_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1) begin
        w_iters_q <= w_iters_d;
      end
    end
  end

  assign w_iters_d = w_iters_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1 ? '0 : w_iters_q + 1;

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_rows_iters_register
    if (~rst_ni) begin
      x_rows_iters_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        x_rows_iters_q <= '0;
      end else if (flgs_streamer_i.x_stream_source_flags.done && x_cols_iters_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1 && w_iters_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1) begin
        x_rows_iters_q <= x_rows_iters_d;
      end
    end
  end

  assign x_rows_iters_d = x_rows_iters_q == reg_file_i.hwpe_params[X_ITERS][31:16]-1 ? '0 : x_rows_iters_q + 1;

  always_ff @(posedge clk_i or negedge rst_ni) begin : tot_x_read_register
    if (~rst_ni) begin
      tot_x_read_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        tot_x_read_q <= '0;
      end else if (flgs_streamer_i.x_stream_source_flags.done) begin
        tot_x_read_q <= tot_x_read_q + 1;
      end
    end
  end

  assign tot_x_read_d = tot_x_read_q == reg_file_i.hwpe_params[TOT_X_READ] ? '0 : tot_x_read_q + 1;

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_cols_offs_register
    if (~rst_ni) begin
      x_cols_offs_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        x_cols_offs_q <= '0;
      end else if (flgs_streamer_i.x_stream_source_flags.done) begin
        x_cols_offs_q <= x_cols_offs_d;
      end
    end
  end

  assign x_cols_offs_d = x_cols_iters_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1 ? '0 : x_cols_offs_q + JMP;

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_rows_offs_register
    if (~rst_ni) begin
      x_rows_offs_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        x_rows_offs_q <= '0;
      end else if (flgs_streamer_i.x_stream_source_flags.done && x_cols_iters_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1 && w_iters_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1) begin
        x_rows_offs_q <= x_rows_offs_d;
      end
    end
  end

  assign x_rows_offs_d = x_rows_iters_q == reg_file_i.hwpe_params[X_ITERS][31:16]-1 ? '0 : x_rows_offs_q + reg_file_i.hwpe_params[X_ROWS_OFFS];

  // In MX mode, X data is packed (2 FP8 per 16-bit word), so we read half as many beats
  logic [$clog2(W):0] num_x_reads_raw;
  assign num_x_reads_raw = x_rows_iters_q == reg_file_i.hwpe_params[X_ITERS][31:16]-1 && reg_file_i.hwpe_params[LEFTOVERS][31:24] != '0 ? reg_file_i.hwpe_params[LEFTOVERS][31:24] : W;
  assign num_x_reads = cntrl_flags_i.mx_enable ? ((num_x_reads_raw + 1) >> 1) : num_x_reads_raw;

  // Here we initialize the streamer source signals
  // for the X stream source
  // Allow first X request while controller is in the first_load phase, but block additional
  // requests until TOT_X_READ indicates more tiles are required. Without this guard the X
  // stream can restart multiple times before W loading completes, effectively duplicating
  // the decoded blocks.
  logic x_first_req_pending;
  assign x_first_req_pending = cntrl_scheduler_i.first_load && (tot_x_read_q == '0);

  assign cntrl_streamer_o.x_stream_source_ctrl.req_start = !cntrl_flags_i.idle &&
                                                           flgs_streamer_i.x_stream_source_flags.ready_start &&
                                                           (x_first_req_pending ||
                                                            (tot_x_read_q < reg_file_i.hwpe_params[TOT_X_READ]));
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.base_addr = reg_file_i.hwpe_params[X_ADDR]
                                                                    + x_rows_offs_q + x_cols_offs_q;
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.tot_len = num_x_reads;
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d0_len = 'd1;
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d0_stride = 'd0;
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d1_len = cntrl_flags_i.mx_enable ? (W >> 1) : W;
  // In MX mode, X data is read linearly (packed FP8), so use beat size (DW/8 bytes) as stride
  // In FP16 mode, use row stride from tiler
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d1_stride =
      cntrl_flags_i.mx_enable ? (DW/8) : reg_file_i.hwpe_params[X_D1_STRIDE];
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d2_stride = '0;
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

  // Here we initialize the streamer source signals
  // for the W stream source
  assign cntrl_streamer_o.w_stream_source_ctrl.req_start = cntrl_scheduler_i.first_load && flgs_streamer_i.z_stream_sink_flags.ready_start;
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.base_addr = reg_file_i.hwpe_params[W_ADDR];
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.tot_len = reg_file_i.hwpe_params[W_TOT_LEN];
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d0_len = reg_file_i.hwpe_params[W_ITERS][31:16];
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d0_stride = reg_file_i.hwpe_params[W_D0_STRIDE];
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d1_len = reg_file_i.hwpe_params[W_ITERS][15:0];
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d1_stride = JMP;
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d2_stride = 'd0;
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

  // Here we initialize the streamer source signals
  // for the Y stream source
  assign cntrl_streamer_o.y_stream_source_ctrl.req_start = cntrl_scheduler_i.first_load && reg_file_i.hwpe_params[OP_SELECTION][0] && flgs_streamer_i.y_stream_source_flags.ready_start;
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.base_addr = reg_file_i.hwpe_params[Z_ADDR];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.tot_len = reg_file_i.hwpe_params[Z_TOT_LEN];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d0_len = W;
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d0_stride = reg_file_i.hwpe_params[Z_D0_STRIDE];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d1_len = reg_file_i.hwpe_params[W_ITERS][15:0];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d1_stride = JMP;
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d2_stride = reg_file_i.hwpe_params[Z_D2_STRIDE];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

  // Here we initialize the streamer sink signals for
  // the Z stream sink
  assign cntrl_streamer_o.z_stream_sink_ctrl.req_start = cntrl_scheduler_i.first_load && flgs_streamer_i.z_stream_sink_flags.ready_start;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.base_addr = reg_file_i.hwpe_params[Z_ADDR];
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.tot_len = reg_file_i.hwpe_params[Z_TOT_LEN];
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d0_len = W;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d0_stride = reg_file_i.hwpe_params[Z_D0_STRIDE];
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d1_len = reg_file_i.hwpe_params[W_ITERS][15:0];
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d1_stride = JMP;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d2_stride = reg_file_i.hwpe_params[Z_D2_STRIDE];
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

  // MX exponent streams (linear addressing, enabled only when MX mode is active)
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.req_start = cntrl_flags_i.mx_enable &&
      cntrl_scheduler_i.first_load && flgs_streamer_i.x_exp_stream_source_flags.ready_start;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.base_addr =
      reg_file_i.hwpe_params[X_EXP_ADDR];
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.tot_len = x_exp_beats;
  // Treat each 64B exponent beat as its own dimension to avoid mid-request jumps
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d0_len = 32'd1;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d0_stride = 32'd0;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d1_len = x_exp_beats;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d1_stride = 32'd64;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d2_stride = 32'd0;
  // Only two dimensions (d0 then d1) required for exponent beats
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b01;

  assign cntrl_streamer_o.w_exp_stream_source_ctrl.req_start = cntrl_flags_i.mx_enable &&
      cntrl_scheduler_i.first_load && flgs_streamer_i.w_exp_stream_source_flags.ready_start;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.base_addr =
      reg_file_i.hwpe_params[W_EXP_ADDR];
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.tot_len = w_exp_beats;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d0_len = 32'd1;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d0_stride = 32'd0;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d1_len = w_exp_beats;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d1_stride = 32'd64;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d2_stride = 32'd0;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b01;

  assign cntrl_streamer_o.input_cast_src_fmt  = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][15:13]);
  assign cntrl_streamer_o.input_cast_dst_fmt  = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][12:10]);
  assign cntrl_streamer_o.output_cast_src_fmt = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][12:10]);
  assign cntrl_streamer_o.output_cast_dst_fmt = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][15:13]);

  assign cntrl_streamer_o.mx_enable = cntrl_flags_i.mx_enable;
  assign cntrl_streamer_o.z_priority = z_priority_i;
endmodule : redmule_memory_scheduler
