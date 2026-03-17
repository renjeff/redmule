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
  output cntrl_streamer_t       cntrl_streamer_o ,
  // Total valid exponent counts for exp buffer write-capping
  output logic [15:0]           x_exp_total_count_o,
  output logic [15:0]           w_exp_total_count_o,
  // X exponent segment size (exponents per M-tile) for segment gating
  output logic [15:0]           x_exp_segment_size_o
);
  localparam int unsigned JMP = NumByte*(DATA_W/MemDw - 1);
  localparam int unsigned BYTES_PER_BEAT = DW/8;
  localparam int unsigned WORDS_PER_BEAT = DW/16;
  localparam int unsigned MX_PACK_FACTOR = 2;
  localparam int unsigned FP16_BLOCK_BYTES = W * (ELW/8);
  localparam int unsigned FP16_BLOCKS_PER_BEAT_RAW = (FP16_BLOCK_BYTES == 0) ? 0 : (BYTES_PER_BEAT / FP16_BLOCK_BYTES);
  localparam int unsigned FP16_BLOCKS_PER_BEAT = (FP16_BLOCKS_PER_BEAT_RAW == 0) ? 1 : FP16_BLOCKS_PER_BEAT_RAW;
  localparam int unsigned MX_BLOCK_BYTES = 32;
  localparam int unsigned Z_BLOCKS_PER_BEAT_RAW = BYTES_PER_BEAT / MX_BLOCK_BYTES;
  localparam int unsigned Z_BLOCKS_PER_BEAT = (Z_BLOCKS_PER_BEAT_RAW == 0) ? 1 : Z_BLOCKS_PER_BEAT_RAW;

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

  // NOTE: reg_file_i is the post-tiler map (MCFIG0/1 are aliased to X/W iters),
  // so derive MX dimensions from X/W iteration and leftover fields.
  logic [15:0] x_rows_iter_cfg, w_rows_iter_cfg, w_cols_iter_cfg;
  logic [7:0]  x_rows_lftovr_cfg, w_rows_lftovr_cfg, w_cols_lftovr_cfg;
  logic [31:0] m_size_systolic, n_size_systolic;
  logic [31:0] m_size_unpacked, n_size_unpacked, k_size_unpacked;
  logic [31:0] total_x_values, total_w_values;
  logic [31:0] x_exp_beats, w_exp_beats;
  // Packed M-tile count for memory addressing: x_rows_iter_cfg is the unpacked
  // value (m*2/ARRAY_WIDTH for MX). Divide by MX_PACK_FACTOR to get memory passes.
  logic [15:0] mem_m_tiles;
  assign mem_m_tiles = cntrl_flags_i.mx_enable
      ? ((x_rows_iter_cfg + MX_PACK_FACTOR - 1) / MX_PACK_FACTOR)
      : x_rows_iter_cfg;
`ifndef SYNTHESIS
  bit dbg_disable_exp_req;
  initial begin
    dbg_disable_exp_req = $test$plusargs("MX_DISABLE_EXP_REQ");
  end
`else
  localparam bit dbg_disable_exp_req = 1'b0;
`endif

  assign x_rows_iter_cfg   = reg_file_i.hwpe_params[X_ITERS][31:16];
  assign w_rows_iter_cfg   = reg_file_i.hwpe_params[W_ITERS][31:16];
  assign w_cols_iter_cfg   = reg_file_i.hwpe_params[W_ITERS][15:0];
  assign x_rows_lftovr_cfg = reg_file_i.hwpe_params[LEFTOVERS][31:24];
  assign w_rows_lftovr_cfg = reg_file_i.hwpe_params[LEFTOVERS][15:8];
  assign w_cols_lftovr_cfg = reg_file_i.hwpe_params[LEFTOVERS][7:0];

    // Systolic-space M from X row iterations/leftovers.
    assign m_size_systolic = (x_rows_lftovr_cfg != '0) ?
      (((x_rows_iter_cfg > 16'd0) ? (x_rows_iter_cfg - 16'd1) : 16'd0) * W + x_rows_lftovr_cfg) :
      (x_rows_iter_cfg * W);

    // Systolic-space N from W row iterations/leftovers.
    assign n_size_systolic = (w_rows_lftovr_cfg != '0) ?
      (((w_rows_iter_cfg > H) ? (w_rows_iter_cfg - H) : 16'd0) + w_rows_lftovr_cfg) :
      w_rows_iter_cfg;

    // M/N recovered from X/W iteration fields are already logical element-space
    // dimensions. Do not de-pack again in MX mode.
    assign m_size_unpacked = m_size_systolic;
    assign n_size_unpacked = n_size_systolic;

  // Unpacked K from W column iterations/leftovers.
  assign k_size_unpacked = (w_cols_lftovr_cfg != '0) ?
      (((w_cols_iter_cfg > 16'd0) ? (w_cols_iter_cfg - 16'd1) : 16'd0) * D + w_cols_lftovr_cfg) :
      (w_cols_iter_cfg * D);

  assign total_x_values = m_size_unpacked * n_size_unpacked;
  assign total_w_values = n_size_unpacked * k_size_unpacked;

  // Calculate exponent beats based on actual matrix dimensions
  // X exponents: 1 byte per block, blocks = (M*K)/32
  logic [31:0] x_blocks, w_blocks;
  logic [31:0] x_exp_bytes, w_exp_bytes;
  
  assign x_blocks = (total_x_values + 31) >> 5;  // ceil(M*N / 32)
  assign w_blocks = (total_w_values + 31) >> 5;  // ceil(N*K / 32)
  
  assign x_exp_bytes = x_blocks;              // 1 byte per X block
  assign w_exp_bytes = w_blocks << 2;              // 4 byte per W block
  
  assign x_exp_beats = (x_exp_bytes + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
  assign w_exp_beats = (w_exp_bytes + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;

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

  assign x_cols_offs_d = x_cols_iters_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1 ? '0 :
                          (cntrl_flags_i.mx_enable ? '0 : x_cols_offs_q + JMP);

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

  // In MX mode, X data is packed along the row dimension (2 FP8 per 16-bit word).
  // Packed rows = ceil(actual_rows/2); row length in words = k_size (actual).
  // beats_needed = packed_rows * k_size / WORDS_PER_BEAT
  logic [$clog2(W):0] num_x_reads_raw;
  logic [31:0]        x_rows_packed;
  logic [31:0]        x_total_words;
  assign num_x_reads_raw = x_rows_iters_q == reg_file_i.hwpe_params[X_ITERS][31:16]-1 && reg_file_i.hwpe_params[LEFTOVERS][31:24] != '0 ? reg_file_i.hwpe_params[LEFTOVERS][31:24] : W;
  assign x_rows_packed = (num_x_reads_raw + MX_PACK_FACTOR - 1) / MX_PACK_FACTOR;
  assign x_total_words = x_rows_packed * n_size_unpacked;
  assign num_x_reads = cntrl_flags_i.mx_enable ? ((x_total_words + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT) : num_x_reads_raw;

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
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d1_len = cntrl_flags_i.mx_enable ? num_x_reads : W;
  // In MX mode, X data is read linearly (packed FP8), so use beat size (DW/8 bytes) as stride
  // In FP16 mode, use row stride from tiler
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d1_stride =
      cntrl_flags_i.mx_enable ? (DW/8) : reg_file_i.hwpe_params[X_D1_STRIDE];
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d2_stride = '0;
  assign cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;


  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.base_addr = reg_file_i.hwpe_params[W_ADDR];
  logic [31:0] w_total_words;
  logic [31:0] w_beats;
  logic [31:0] w_rows_packed;
  logic [31:0] w_words_per_x_tile;
  // W payload words in MX are packed over logical N rows (2 elements/word).
  assign w_rows_packed = cntrl_flags_i.mx_enable ?
                         ((n_size_unpacked + MX_PACK_FACTOR - 1) / MX_PACK_FACTOR) :
                         ((w_rows_iter_cfg + MX_PACK_FACTOR - 1) / MX_PACK_FACTOR);
  assign w_words_per_x_tile = k_size_unpacked * w_rows_packed;
  // Single-pass W beat count: covers one full W matrix read.
  // tot_len is multiplied by x_rows_iter_cfg so the hwpe addressgen cycles the
  // same W_ADDR..W_ADDR+(w_beats-1) address window once per M-tile pass,
  // matching the baseline FP16 strategy: d1 wraps back to 0 every w_beats
  // beats while tot_len keeps the stream open for all passes.
  assign w_total_words = w_words_per_x_tile;
  assign w_beats = (w_total_words + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT;

  // Fire W req_start exactly once (same as baseline), then let tot_len cover
  // all x_rows_iter M-tile passes with the addressgen cycling W addresses.
  assign cntrl_streamer_o.w_stream_source_ctrl.req_start =
      cntrl_scheduler_i.first_load &&
      flgs_streamer_i.z_stream_sink_flags.ready_start &&
      flgs_streamer_i.w_stream_source_flags.ready_start;

  // x_rows_iter_cfg is the unpacked M-tile iteration count (matches scheduler FSM loops).
  // w_beats already covers ALL K-tiles (computed from k_size_unpacked), so do NOT
  // multiply by w_cols_iter_cfg again — that would double-count K.
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.tot_len   = cntrl_flags_i.mx_enable ? w_beats * x_rows_iter_cfg : reg_file_i.hwpe_params[W_TOT_LEN];
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d0_len   = cntrl_flags_i.mx_enable ? 32'd1 : reg_file_i.hwpe_params[W_ITERS][31:16];

  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d0_stride= cntrl_flags_i.mx_enable ? 32'd0 : reg_file_i.hwpe_params[W_D0_STRIDE];
  // d1_len = w_beats (single pass) so the addressgen wraps back to W_ADDR
  // after each pass, providing fresh W data for subsequent M-tile passes.
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d1_len   = cntrl_flags_i.mx_enable ? w_beats : reg_file_i.hwpe_params[W_ITERS][15:0];
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d1_stride= cntrl_flags_i.mx_enable ? (DW/8) : JMP;
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d2_stride = 'd0;
  assign cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

  // Here we initialize the streamer source signals
  // for the Y stream source
  logic [31:0] z_store_tot_len;
  logic [31:0] y_load_tot_len;
  logic [31:0] z_store_d0_stride;
  logic [31:0] z_store_d2_stride;
  logic [31:0] z_store_d0_len;
  logic [31:0] z_store_d1_len;
  logic [31:0] z_store_d1_stride;
  logic [1:0]  z_store_dim_enable;
  // Keep legacy row-based semantics for Y preload also in MX mode.
  // z_buffer consumes one logical Y row per handshake; scaling tot_len by
  // beat packing drops rows on wide buses (e.g. 1024b -> tail mismatch).
  assign y_load_tot_len = reg_file_i.hwpe_params[Z_TOT_LEN];
  logic [31:0] z_total_words;
  logic [31:0] z_total_beats;
  // In MX mode, Z output is FP8 (8-bit per element). Two FP8 values pack into
  // each 16-bit word slot, so divide total element count by MX_PACK_FACTOR.
  assign z_total_words = ((m_size_unpacked * k_size_unpacked) + MX_PACK_FACTOR - 1) / MX_PACK_FACTOR;
  assign z_total_beats = (z_total_words + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT;
  assign z_store_tot_len = cntrl_flags_i.mx_enable ? z_total_beats
                                                    : reg_file_i.hwpe_params[Z_TOT_LEN];
  assign z_store_d0_stride = cntrl_flags_i.mx_enable ? (DW/8) : reg_file_i.hwpe_params[Z_D0_STRIDE];
  assign z_store_d2_stride = reg_file_i.hwpe_params[Z_D2_STRIDE];
  assign z_store_d0_len = cntrl_flags_i.mx_enable ? 32'd1 : W;
  assign z_store_d1_len = cntrl_flags_i.mx_enable ? z_store_tot_len : reg_file_i.hwpe_params[W_ITERS][15:0];
  assign z_store_d1_stride = cntrl_flags_i.mx_enable ? (DW/8) : JMP;
  assign z_store_dim_enable = cntrl_flags_i.mx_enable ? 2'b01 : 2'b11;

  assign cntrl_streamer_o.y_stream_source_ctrl.req_start = cntrl_scheduler_i.first_load && reg_file_i.hwpe_params[OP_SELECTION][0] && flgs_streamer_i.y_stream_source_flags.ready_start;
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.base_addr = reg_file_i.hwpe_params[Z_ADDR];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.tot_len = y_load_tot_len;
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d0_len = W;
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d0_stride = reg_file_i.hwpe_params[Z_D0_STRIDE];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d1_len = reg_file_i.hwpe_params[W_ITERS][15:0];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d1_stride = JMP;
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d2_stride = reg_file_i.hwpe_params[Z_D2_STRIDE];
  assign cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b11;

  // Here we initialize the streamer sink signals for
  // the Z stream sink
  assign cntrl_streamer_o.z_stream_sink_ctrl.req_start = cntrl_scheduler_i.first_load && flgs_streamer_i.z_stream_sink_flags.ready_start;
  // In MX mode, write Z output to a separate buffer (Z_OUT_ADDR) to avoid
  // overwriting the FP16 Y bias that later K-tiles still need to consume.
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.base_addr =
      cntrl_flags_i.mx_enable ? reg_file_i.hwpe_params[Z_OUT_ADDR]
                              : reg_file_i.hwpe_params[Z_ADDR];
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.tot_len = z_store_tot_len;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d0_len = z_store_d0_len;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d0_stride = z_store_d0_stride;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d1_len = z_store_d1_len;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d1_stride = z_store_d1_stride;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d2_stride = z_store_d2_stride;
  assign cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.dim_enable_1h = z_store_dim_enable;

  // MX exponent streams (linear addressing, enabled only when MX mode is active)
    assign cntrl_streamer_o.x_exp_stream_source_ctrl.req_start = cntrl_flags_i.mx_enable &&
      !dbg_disable_exp_req &&
      cntrl_scheduler_i.first_load && flgs_streamer_i.x_exp_stream_source_flags.ready_start;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.base_addr =
      reg_file_i.hwpe_params[X_EXP_ADDR];
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.tot_len = x_exp_beats;
  // Treat each 64B exponent beat as its own dimension to avoid mid-request jumps
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d0_len = 32'd1;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d0_stride = 32'd0;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d1_len = x_exp_beats;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d1_stride = BYTES_PER_BEAT;
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.d2_stride = 32'd0;
  // Only two dimensions (d0 then d1) required for exponent beats
  assign cntrl_streamer_o.x_exp_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b01;

    assign cntrl_streamer_o.w_exp_stream_source_ctrl.req_start = cntrl_flags_i.mx_enable &&
      !dbg_disable_exp_req &&
      cntrl_scheduler_i.first_load && flgs_streamer_i.w_exp_stream_source_flags.ready_start;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.base_addr =
      reg_file_i.hwpe_params[W_EXP_ADDR];
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.tot_len = w_exp_beats;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d0_len = 32'd1;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d0_stride = 32'd0;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d1_len = w_exp_beats;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d1_stride = BYTES_PER_BEAT;
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.d2_stride = 32'd0;
  // Only two dimensions (d0 then d1) required for exponent beats
  assign cntrl_streamer_o.w_exp_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 2'b01;

  assign cntrl_streamer_o.input_cast_src_fmt  = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][15:13]);
  assign cntrl_streamer_o.input_cast_dst_fmt  = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][12:10]);
  assign cntrl_streamer_o.output_cast_src_fmt = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][12:10]);
  assign cntrl_streamer_o.output_cast_dst_fmt = fpnew_pkg::fp_format_e'(reg_file_i.hwpe_params[OP_SELECTION][15:13]);

  assign cntrl_streamer_o.mx_enable = cntrl_flags_i.mx_enable;
  assign cntrl_streamer_o.z_priority = z_priority_i;

  // Expose total valid exponent counts for exp buffer write-capping.
  // In MX mode, the last exp beat may have fewer valid exponents than
  // EXPS_PER_BEAT; these counts let the buffer avoid storing junk padding.
  assign x_exp_total_count_o = cntrl_flags_i.mx_enable ? x_blocks[15:0] : '0;
  assign w_exp_total_count_o = cntrl_flags_i.mx_enable ? w_blocks[15:0] : '0;

  // X exponent segment size: exponents per M-tile = ARRAY_WIDTH * n_size_unpacked / 32.
  // Since ARRAY_WIDTH = W = 32, this simplifies to n_size_unpacked.
  assign x_exp_segment_size_o = cntrl_flags_i.mx_enable ? n_size_unpacked[15:0] : '0;

`ifndef SYNTHESIS
  bit dbg_msched;
  initial dbg_msched = $test$plusargs("MX_DEBUG_DUMP");

  always_ff @(posedge clk_i) begin
    if (dbg_msched && cntrl_flags_i.mx_enable) begin
      if (cntrl_streamer_o.x_stream_source_ctrl.req_start ||
          flgs_streamer_i.x_stream_source_flags.done ||
          cntrl_scheduler_i.first_load) begin
        $display("[DBG][MSCHED][%0t] X req_start=%0b ready_start=%0b done=%0b first_load=%0b idle=%0b tot_x_read_q=%0d TOT_X_READ=%0d",
                 $time,
                 cntrl_streamer_o.x_stream_source_ctrl.req_start,
                 flgs_streamer_i.x_stream_source_flags.ready_start,
                 flgs_streamer_i.x_stream_source_flags.done,
                 cntrl_scheduler_i.first_load,
                 cntrl_flags_i.idle,
                 tot_x_read_q,
                 reg_file_i.hwpe_params[TOT_X_READ]);
      end
      if (cntrl_scheduler_i.first_load) begin
        $display("[DBG][MSCHED][%0t] dims m_unpack=%0d n_unpack=%0d k_unpack=%0d total_x=%0d x_exp_beats=%0d num_x_reads=%0d",
                 $time,
                 m_size_unpacked,
                 n_size_unpacked,
                 k_size_unpacked,
                 total_x_values,
                 x_exp_beats,
                 num_x_reads);
        $display("[DBG][MSCHED][%0t] Y_STREAM: tot_len=%0d d0_len=%0d d1_len=%0d Z_TOT_LEN_REG=%0d z_store_tot_len=%0d z_total_words=%0d z_total_beats=%0d",
                 $time,
                 y_load_tot_len,
                 W,
                 reg_file_i.hwpe_params[W_ITERS][15:0],
                 reg_file_i.hwpe_params[Z_TOT_LEN],
                 z_store_tot_len,
                 z_total_words,
                 z_total_beats);
        $display("[DBG][MSCHED][%0t] W_STREAM: tot_len=%0d w_beats=%0d w_rows_packed=%0d w_words=%0d x_rows_iter=%0d w_cols_iter=%0d W_TOT_LEN_REG=%0d",
                 $time,
                 cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.tot_len,
                 w_beats,
                 w_rows_packed,
                 w_total_words,
                 x_rows_iter_cfg,
                 w_cols_iter_cfg,
                 reg_file_i.hwpe_params[W_TOT_LEN]);
      end
    end
  end
`endif
endmodule : redmule_memory_scheduler
