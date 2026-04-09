// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
// Andrea Belano <andrea.belano2@unibo.it>
//

module redmule_scheduler
  import fpnew_pkg::*;
  import hci_package::*;
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
  import hwpe_stream_package::*;
#(
  parameter  int unsigned Height      = ARRAY_HEIGHT  ,
  parameter  int unsigned Width       = ARRAY_WIDTH   ,
  parameter  int unsigned NumPipeRegs = PIPE_REGS     ,
  localparam int unsigned D           = TOT_DEPTH     ,
  localparam int unsigned H           = Height        ,
  localparam int unsigned W           = Width
)(
  /********************************************************/
  /*                        Inputs                        */
  /********************************************************/
  input  logic                            clk_i            ,
  input  logic                            rst_ni           ,
  input  logic                            test_mode_i      ,
  input  logic                            clear_i          ,
  input  logic                            mx_enable_i      ,

  input  logic                            x_valid_i        ,
  input  logic                            w_valid_i        ,
  input  logic                            y_valid_i        ,
  input  logic                            z_ready_i        ,

  input  logic                            engine_flush_i   ,

  input  ctrl_regfile_t                   reg_file_i       ,

  input  flgs_streamer_t                  flgs_streamer_i  ,
  input  x_buffer_flgs_t                  flgs_x_buffer_i  ,
  input  w_buffer_flgs_t                  flgs_w_buffer_i  ,
  input  z_buffer_flgs_t                  flgs_z_buffer_i  ,

  input  flgs_engine_t                    flgs_engine_i    ,
  input  cntrl_scheduler_t                cntrl_scheduler_i,

  // MX beat-unpack pending flags: high while a packed beat is still
  // being emitted.  Used to keep the handoff stall active until the
  // MX ingress pipeline has drained.
  input  logic                            mx_x_pending_i   ,
  input  logic                            mx_w_pending_i   ,
  // W FIFO replay active: freeze engine/X/counters while SCM is refreshed
  input  logic                            w_replaying_i    ,

  /********************************************************/
  /*                       Outputs                        */
  /********************************************************/
  output logic                            reg_enable_o     ,
  output cntrl_engine_t                   cntrl_engine_o   ,
  output x_buffer_ctrl_t                  cntrl_x_buffer_o ,
  output w_buffer_ctrl_t                  cntrl_w_buffer_o ,
  output z_buffer_ctrl_t                  cntrl_z_buffer_o ,
  output flgs_scheduler_t                 flgs_scheduler_o ,
  // Exponent buffer mark/rewind for MX multi-tile replay
  output logic                            x_exp_mark_o     ,
  output logic                            x_exp_rewind_o   ,
  output logic                            w_exp_mark_o     ,
  output logic                            w_exp_rewind_o   ,
  // Y register write lock: prevents Y register overwrite during y_push restart
  output logic                            y_reg_lock_o     ,
  // Y push enable (ungated by y_reg_lock) for Y register's own read counter
  output logic                            y_push_en_ungated_o,
  // M-tile transition: active from boundary to z_avail+drain completion
  output logic                            m_tile_transition_o,
  // W SCM clear: pulse at M-tile boundary to zero SCM and reset w_row
  output logic                            w_scm_clear_o,
  // W FIFO rewind (disabled)
  output logic                            w_fifo_mark_o,
  output logic                            w_fifo_rewind_o,
  // Shadow register file: capture during M0 K0, bypass during M1 K0
  output logic                            w_shadow_capture_o,
  output logic                            w_shadow_bypass_o,
  // Shadow width mask: LEFTOVERS K-column width (0 = full tile D)
  output logic [7:0]                      w_shadow_width_o
);

  typedef enum logic [1:0] {
    IDLE,
    PRELOAD,
    LOAD_W,
    WAIT
  } redmule_fsm_state_e;

  redmule_fsm_state_e current_state, next_state;

  logic start;

  logic stall_engine,
        first_load,
        start_computation,
        computing,
        x_refill,
        pushing_y;

  // Forward declaration: engine clock gate (registered) used for fill alignment
  logic [W-1:0] row_clk_en_d, row_clk_en_q;

  // Forward declaration: gen_toggle_pulse (defined near M-tile boundary logic)
  logic gen_toggle_pulse;
  // Forward declarations for M-tile boundary logic (defined near bottom)
  logic m_tile_rst_pending_q;
  logic w_replay_just_ended;
  logic m_tile_boundary_not_last;


  /************************
   * X Iteration counters *
   ************************/
  logic [15:0] x_cols_iter_d, x_cols_iter_q,
               x_w_iters_d, x_w_iters_q,
               x_rows_iter_d, x_rows_iter_q;

  logic        x_done;

  logic        x_cols_iter_en, x_w_iters_en, x_rows_iter_en,
               x_done_en;

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_columns_iteration
    if(~rst_ni) begin
      x_cols_iter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        x_cols_iter_q <= '0;
      end else if (x_cols_iter_en && ~x_done) begin
        x_cols_iter_q <= x_cols_iter_d;
      end
    end
  end

  assign x_cols_iter_en = flgs_x_buffer_i.empty;  //We can do this as the flag is only raised for one cycle
  assign x_cols_iter_d  = x_cols_iter_en ? (x_cols_iter_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1 ? '0 : x_cols_iter_q + 1) : x_cols_iter_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : weight_iteration_counter
    if(~rst_ni) begin
      x_w_iters_q <= 0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst)
        x_w_iters_q <= '0;
      else if (x_w_iters_en && ~x_done)
        x_w_iters_q <= x_w_iters_d;
    end
  end

  assign x_w_iters_en = x_cols_iter_en && x_cols_iter_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1;
  assign x_w_iters_d  = x_w_iters_en ? (x_w_iters_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1 ? '0 : x_w_iters_q + 1) : x_w_iters_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_rows_iteration
    if(~rst_ni) begin
      x_rows_iter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        x_rows_iter_q <= '0;
      end else if (x_rows_iter_en && ~x_done) begin
        x_rows_iter_q <= x_rows_iter_d;
      end
    end
  end

  assign x_rows_iter_en = x_w_iters_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1 && x_w_iters_en;
  assign x_rows_iter_d  = x_rows_iter_en ? x_rows_iter_q + 1 : x_rows_iter_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_done_register
    if(~rst_ni) begin
      x_done <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        x_done <= '0;
      end else if (x_done_en) begin
        x_done <= '1;
      end
    end
  end

  assign x_done_en = x_rows_iter_en && x_rows_iter_q == reg_file_i.hwpe_params[X_ITERS][31:16]-1;

  assign cntrl_x_buffer_o.height = x_cols_iter_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1 && reg_file_i.hwpe_params[LEFTOVERS][23:16] != '0 ? reg_file_i.hwpe_params[LEFTOVERS][23:16] : D;
  assign cntrl_x_buffer_o.slots  = x_cols_iter_q == reg_file_i.hwpe_params[X_ITERS][15:0]-1 && reg_file_i.hwpe_params[LEFTOVERS][23:16] != '0 ? reg_file_i.hwpe_params[X_SLOTS] : D;
  assign cntrl_x_buffer_o.width  = x_rows_iter_q == reg_file_i.hwpe_params[X_ITERS][31:16]-1 && reg_file_i.hwpe_params[LEFTOVERS][31:24] != '0 ? reg_file_i.hwpe_params[LEFTOVERS][31:24] : W;

  /******************************
   *      X Shift Control       *
   ******************************/
  logic [$clog2(H-1)-1:0] x_shift_cnt_d, x_shift_cnt_q;
  logic                   x_shift_cnt_en;

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_shift_counter
    if(~rst_ni) begin
      x_shift_cnt_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst)
        x_shift_cnt_q <= '0;
      else if (x_shift_cnt_en)
        x_shift_cnt_q <= x_shift_cnt_d;
    end
  end

  assign x_shift_cnt_en = (current_state == LOAD_W) && ~stall_engine;
  assign x_shift_cnt_d  = x_shift_cnt_q == H-1 ? '0 : x_shift_cnt_q + 1;

  assign cntrl_x_buffer_o.h_shift = x_shift_cnt_en;

  /******************************
   *     X Reload Control       *
   ******************************/
  logic x_reload_q;
  logic x_reload_en, x_reload_rst;

  logic x_empty;

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_reload_register
    if(~rst_ni) begin
      x_reload_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst || x_reload_rst)
        x_reload_q <= '0;
      else if (x_reload_en)
        x_reload_q <= '1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_empty_register
    if(~rst_ni) begin
      x_empty <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst || ~flgs_x_buffer_i.full)
        x_empty <= '0;
      else if (flgs_x_buffer_i.full && flgs_x_buffer_i.empty)
        x_empty <= '1;
    end
  end

  assign x_reload_en  = start || x_cols_iter_en || x_empty && ~flgs_x_buffer_i.full;
  assign x_reload_rst = flgs_x_buffer_i.full && ~x_reload_en;

  assign cntrl_x_buffer_o.pad_setup   = current_state == PRELOAD && next_state == LOAD_W;
  assign cntrl_x_buffer_o.load        = (x_reload_q && ~x_reload_rst) && x_valid_i;
  assign cntrl_x_buffer_o.rst_w_index = (current_state == LOAD_W && x_shift_cnt_q == H-1) && flgs_x_buffer_i.full && ~stall_engine;
  assign cntrl_x_buffer_o.last_x      = x_done_en;

  /************************
   * W Iteration counters *
   ************************/
  logic [15:0] w_cols_iter_d, w_cols_iter_q,
               w_rows_iter_d, w_rows_iter_q,
               w_mat_iters_q;

  logic        w_done;

  logic        w_cols_iter_en, w_rows_iter_en,
               w_mat_iters_en, w_done_en;

  logic        w_stride_cnt;
  logic        w_needs_stream_valid;

  // Detect replay end: falling edge of w_replaying_i
  logic w_replaying_prev_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) w_replaying_prev_q <= 1'b0;
    else         w_replaying_prev_q <= w_replaying_i;
  end
  logic w_replay_just_ended;
  assign w_replay_just_ended = w_replaying_prev_q && !w_replaying_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin : w_rows_iteration
    if(~rst_ni) begin
      w_rows_iter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        w_rows_iter_q <= '0;
      end else if (w_rows_iter_en && ~w_done) begin
        w_rows_iter_q <= w_rows_iter_d;
      end
    end
  end

  // Always require w_valid_i so the scheduler stalls until decoded W data is
  // available in the FIFO on every M-tile pass.
  assign w_needs_stream_valid = 1'b1;
  // Freeze w_rows_iter during replay only (not drain — drain runs like baseline).
  assign w_rows_iter_en = current_state == LOAD_W && ~stall_engine &&
                          (w_valid_i || ~w_needs_stream_valid);
  assign w_rows_iter_d  = w_rows_iter_q == reg_file_i.hwpe_params[W_ITERS][31:16]-1 ? '0 : w_rows_iter_q + 1;

`ifndef SYNTHESIS
  bit dbg_sched;
  initial dbg_sched = $test$plusargs("MX_DEBUG_DUMP");

  always @(posedge clk_i) begin
    if (dbg_sched && w_rows_iter_en) begin
      $display("[DBG][SCHED] LOAD_W cycle: w_rows_iter_q=%0d -> %0d, W_ITERS[31:16]=%0d, x_shift_cnt=%0d, x_slots=%0d, x_width=%0d, w_width=%0d, w_height=%0d",
               w_rows_iter_q, w_rows_iter_d, reg_file_i.hwpe_params[W_ITERS][31:16], x_shift_cnt_q,
               cntrl_x_buffer_o.slots, cntrl_x_buffer_o.width, cntrl_w_buffer_o.width, cntrl_w_buffer_o.height);
    end
  end

  // Stall watchdog — fires once after 2000 cycles of continuous stall
  integer stall_cnt;
  logic stall_reported;
  always @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni || clear_i || cntrl_scheduler_i.rst) begin
      stall_cnt <= 0;
      stall_reported <= 0;
    end else if (stall_engine) begin
      stall_cnt <= stall_cnt + 1;
      if (dbg_sched && stall_cnt == 2000 && !stall_reported) begin
        stall_reported <= 1;
        $display("[DBG][STALL] ====== HANG DETECTED at t=%0t ======", $time);
        $display("[DBG][STALL] state=%0d (LOAD_W=2)", current_state);
        $display("[DBG][STALL] w_valid=%b  w_valid_en=%b (w_done=%b)",
                 w_valid_i, check_w_valid_en, w_done);
        $display("[DBG][STALL] x_full=%b   x_full_en=%b  (x_refill=%b x_shift=%0d x_done=%b)",
                 check_x_full, check_x_full_en, x_refill, x_shift_cnt_q, x_done);
        $display("[DBG][STALL] y_loaded=%b y_loaded_en=%b (z_wait_cnt=%0d)",
                 check_y_loaded, check_y_loaded_en, z_wait_counter_q);
        $display("[DBG][STALL] w_rows_q=%0d/%0d  w_cols_q=%0d/%0d  w_mat_q=%0d",
                 w_rows_iter_q, reg_file_i.hwpe_params[W_ITERS][31:16],
                 w_cols_iter_q, reg_file_i.hwpe_params[W_ITERS][15:0],
                 w_mat_iters_q);
        $display("[DBG][STALL] x_cols_q=%0d/%0d  x_w_q=%0d  x_rows_q=%0d/%0d",
                 x_cols_iter_q, reg_file_i.hwpe_params[X_ITERS][15:0],
                 x_w_iters_q,
                 x_rows_iter_q, reg_file_i.hwpe_params[X_ITERS][31:16]);
        $display("[DBG][STALL] LEFTOVERS=0x%08h", reg_file_i.hwpe_params[LEFTOVERS]);
        $display("[DBG][STALL] z_wait_en=%b z_avail_en=%b y_push_en=%b",
                 z_wait_en, z_avail_en, y_push_en);
        $display("[DBG][STALL] y_valid_i=%b z_ready_i=%b",
                 y_valid_i, z_ready_i);
        $display("[DBG][STALL] zbuf: loaded=%b empty=%b y_pushed=%b y_ready=%b z_valid=%b",
                 flgs_z_buffer_i.loaded, flgs_z_buffer_i.empty,
                 flgs_z_buffer_i.y_pushed, flgs_z_buffer_i.y_ready,
                 flgs_z_buffer_i.z_valid);
        $display("[DBG][STALL] y_cols_q=%0d y_rows_q=%0d  y_width=%0d y_height=%0d",
                 y_cols_iter_q, y_rows_iter_q, y_width, y_height);
        $display("[DBG][STALL] z_width=%0d z_height=%0d  reg_enable=%b",
                 z_width, z_height, reg_enable_o);
      end
    end else begin
      stall_cnt <= 0;
    end
  end
`endif

  always_ff @(posedge clk_i or negedge rst_ni) begin : w_columns_iteration
    if(~rst_ni) begin
      w_cols_iter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        w_cols_iter_q <= '0;
      end else if (w_cols_iter_en && ~w_done) begin
        w_cols_iter_q <= w_cols_iter_d;
      end
    end
  end

  assign w_cols_iter_en = w_rows_iter_q == reg_file_i.hwpe_params[W_ITERS][31:16]-1 && w_rows_iter_en;
  assign w_cols_iter_d  = w_cols_iter_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1 ? '0 : w_cols_iter_q + 1;

  always_ff @(posedge clk_i or negedge rst_ni) begin : w_matrix_iterations
    if(~rst_ni) begin
      w_mat_iters_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        w_mat_iters_q <= '0;
      end else if (w_mat_iters_en && ~w_done) begin
        w_mat_iters_q <= w_mat_iters_q + 1;
      end
    end
  end

  assign w_mat_iters_en = w_cols_iter_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1 && w_cols_iter_en;

  always_ff @(posedge clk_i or negedge rst_ni) begin : w_done_register
    if(~rst_ni) begin
      w_done <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        w_done <= '0;
      end else if (w_done_en) begin
        w_done <= '1;
      end
    end
  end


  assign w_done_en = w_mat_iters_en && w_mat_iters_q == reg_file_i.hwpe_params[X_ITERS][31:16]-1;

  assign cntrl_w_buffer_o.height = w_rows_iter_q >= reg_file_i.hwpe_params[W_ITERS][31:16]-(PIPE_REGS+1) && reg_file_i.hwpe_params[LEFTOVERS][15:8] != '0 ? reg_file_i.hwpe_params[LEFTOVERS][15:8] : H;
  assign cntrl_w_buffer_o.width  = w_cols_iter_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1 && reg_file_i.hwpe_params[LEFTOVERS][7:0] != '0 ? reg_file_i.hwpe_params[LEFTOVERS][7:0] : D;

  // Only load into W buffer when a new FIFO word is valid. In MX reuse passes
  // (after first pass) we keep shifting without re-loading.
  // During m_tile transition: freeze load AND shift to prevent inner FIFO consumption.
  // No freeze: replay data flows as normal LOAD_W cycles
  assign cntrl_w_buffer_o.load  = current_state == LOAD_W && ~stall_engine && w_valid_i;
  assign cntrl_w_buffer_o.shift = (current_state == LOAD_W || current_state == WAIT) && ~stall_engine;

  /****************************
   * Y & Z Iteration counters *
   ****************************/
  logic [15:0]                    y_cols_iter_d, y_cols_iter_q,
                                  y_rows_iter_d, y_rows_iter_q;

  logic                           y_cols_iter_en, y_rows_iter_en;

  logic [$clog2(PIPE_REGS+1)-1:0] z_wait_counter_d, z_wait_counter_q;
  logic [$clog2(D)-1:0]           z_avail_counter_d, z_avail_counter_q,
                                  y_push_counter_d, y_push_counter_q;

  logic                           z_wait_en, z_wait_clr,
                                  z_avail_en, z_avail_clr,
                                  y_push_en, y_push_clr;

  logic [$clog2(W):0]             y_width, z_width;
  logic [$clog2(D):0]             y_height, z_height;

  always_ff @(posedge clk_i or negedge rst_ni) begin : y_columns_iteration
    if(~rst_ni) begin
      y_cols_iter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        y_cols_iter_q <= '0;
      end else if (y_cols_iter_en) begin
        y_cols_iter_q <= y_cols_iter_d;
      end
    end
  end

  assign y_cols_iter_en = flgs_z_buffer_i.empty;
  assign y_cols_iter_d  = y_cols_iter_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1 ? '0 : y_cols_iter_q + 1;

  always_ff @(posedge clk_i or negedge rst_ni) begin : y_rows_iteration
    if(~rst_ni) begin
      y_rows_iter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        y_rows_iter_q <= '0;
      end else if (y_rows_iter_en) begin
        y_rows_iter_q <= y_rows_iter_d;
      end
    end
  end

  assign y_rows_iter_en = y_cols_iter_q == reg_file_i.hwpe_params[W_ITERS][15:0]-1 && y_cols_iter_en;
  assign y_rows_iter_d  =  y_rows_iter_q == reg_file_i.hwpe_params[W_ITERS][31:16]-1 ? '0 : y_rows_iter_q + 1;

`ifndef SYNTHESIS
  // K-tile transition debug
  always @(posedge clk_i) begin
    if (y_cols_iter_en) begin
      $display("[DBG][KTILE] t=%0t y_cols_iter %0d -> %0d  y_height=%0d z_height=%0d  y_rows_q=%0d  first_load=%b  LEFTOVERS[7:0]=%0d  W_ITERS[15:0]=%0d  w_cols_iter_q=%0d  m_tile_rst=%b",
               $time, y_cols_iter_q, y_cols_iter_d, y_height, z_height,
               y_rows_iter_q,
               y_cols_iter_q == '0 && y_rows_iter_q == '0,
               reg_file_i.hwpe_params[LEFTOVERS][7:0],
               reg_file_i.hwpe_params[W_ITERS][15:0],
               w_cols_iter_q, m_tile_rst_pending_q);
    end

    if (w_cols_iter_q == 1 && computing) begin
      if (z_avail_en && row_clk_en_q[0] && (z_avail_counter_q == 0 || z_avail_counter_q == z_height-1))
        $display("[DBG][FILL] t=%0t fill_cnt=%0d/%0d z_height=%0d y_height=%0d",
                 $time, z_avail_counter_q, z_height, z_height, y_height);
      if (y_push_en && (y_push_counter_q == 0 || y_push_counter_q == y_height-1))
        $display("[DBG][YPUSH] t=%0t y_push_cnt=%0d/%0d y_height=%0d accum=%b pushing_y=%b w_rows=%0d",
                 $time, y_push_counter_q, y_height, y_height, ~pushing_y, pushing_y, w_rows_iter_q);
    end
    if (flgs_z_buffer_i.empty && computing)
      $display("[DBG][ZEMPTY] t=%0t w_cols_q=%0d y_cols_q=%0d y_height=%0d z_height=%0d first_load=%b",
               $time, w_cols_iter_q, y_cols_iter_q, y_height, z_height,
               y_cols_iter_q == '0 && y_rows_iter_q == '0);
    if (w_cols_iter_en && computing)
      $display("[DBG][KWAIT] t=%0t w_cols_iter_en w_cols_q=%0d->%0d w_rows_q=%0d z_height_now=%0d y_height_now=%0d",
               $time, w_cols_iter_q, w_cols_iter_d, w_rows_iter_q, z_height, y_height);
  end
`endif

  always_ff @(posedge clk_i or negedge rst_ni) begin : z_wait_enable_register
    if(~rst_ni) begin
      z_wait_en <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst || z_wait_clr) begin
        z_wait_en <= '0;
      end else if (w_cols_iter_en) begin
        z_wait_en <= '1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : z_wait_counter
    if(~rst_ni) begin
      z_wait_counter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        z_wait_counter_q <= '0;
      end else if (z_wait_en && ~stall_engine) begin
        z_wait_counter_q <= z_wait_counter_d;
      end
    end
  end

  assign z_wait_counter_d = z_wait_counter_q == PIPE_REGS ? '0 : z_wait_counter_q + 1;
  assign z_wait_clr       = z_wait_en && ~stall_engine && z_wait_counter_q == PIPE_REGS;

  // Z buffer drain guard: prevent z_avail fill/counter during PUSHED state
  logic z_buf_draining;
  assign z_buf_draining = flgs_z_buffer_i.z_valid;  // Z buffer in PUSHED state

  // Delayed drain flag: aligns fill resumption with engine clock gate (registered).
  // Without this, fill resumes 1 cycle before the engine clock, causing a duplicate
  // capture at the drain→fill transition.
  logic z_buf_was_draining;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      z_buf_was_draining <= 1'b0;
    else if (clear_i || cntrl_scheduler_i.rst)
      z_buf_was_draining <= 1'b0;
    else
      z_buf_was_draining <= z_buf_draining;
  end

  // Combined guard: blocks fill for 1 extra cycle after drain ends
  logic z_drain_guard;
  assign z_drain_guard = z_buf_draining || z_buf_was_draining;

  always_ff @(posedge clk_i or negedge rst_ni) begin : z_avail_enable_register
    if(~rst_ni) begin
      z_avail_en <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst || z_avail_clr) begin
        z_avail_en <= '0;
      end else if (z_wait_clr) begin
        z_avail_en <= '1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : z_availability_counter
    if(~rst_ni) begin
      z_avail_counter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        z_avail_counter_q <= '0;
      end else if (z_avail_en && row_clk_en_q[0]) begin
        z_avail_counter_q <= z_avail_counter_d;
      end
    end
  end

  assign z_avail_counter_d = z_avail_counter_q == z_height-1 ? '0 : z_avail_counter_q + 1;
  assign z_avail_clr       = z_avail_en && row_clk_en_q[0] && z_avail_counter_q == z_height-1;

  always_ff @(posedge clk_i or negedge rst_ni) begin : y_push_enable_register
    if(~rst_ni) begin
      y_push_en <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst || y_push_clr) begin
        y_push_en <= '0;
      end else if (z_wait_en && ~stall_engine && z_wait_counter_q == PIPE_REGS-1 || start_computation) begin
        y_push_en <= '1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : y_push_counter
    if(~rst_ni) begin
      y_push_counter_q <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        y_push_counter_q <= '0;
      end else if (y_push_en && ~stall_engine) begin
        y_push_counter_q <= y_push_counter_d;
      end
    end
  end

  assign y_push_counter_d = y_push_counter_q == y_height-1 ? '0 : y_push_counter_q + 1;
  assign y_push_clr       = y_push_en && ~stall_engine && y_push_counter_q == y_height-1;

  // Y register lock and ungated y_push (disabled — y_push restart not active)
  assign y_reg_lock_o = 1'b0;
  assign y_push_en_ungated_o = y_push_en && ~stall_engine;

  assign y_width  = y_rows_iter_q == reg_file_i.hwpe_params[W_ITERS][31:16]-1 && reg_file_i.hwpe_params[LEFTOVERS][15:8] != '0 ? reg_file_i.hwpe_params[LEFTOVERS][15:8] : W;
  // MX mode: use engine-side K-tile counter (w_cols_iter_q) because the Z buffer's
  // y_cols_iter_q advances prematurely via the first_load empty path.
  // FP16 mode: use y_cols_iter_q (original design) — w_cols_iter_q races ahead of
  // y_push timing in FP16 and causes 1520 errors on 96×96×96.
  assign y_height = (mx_enable_i ? w_cols_iter_q : y_cols_iter_q) == reg_file_i.hwpe_params[W_ITERS][15:0]-1 && reg_file_i.hwpe_params[LEFTOVERS][7:0] != '0 ? reg_file_i.hwpe_params[LEFTOVERS][7:0] : D;

  always_ff @(posedge clk_i or negedge rst_ni) begin : z_width_register
    if(~rst_ni) begin
      z_width <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        z_width <= '0;
      end else if (flgs_z_buffer_i.empty || start_computation) begin
        z_width <= y_width;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : z_height_register
    if(~rst_ni) begin
      z_height <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        z_height <= '0;
      end else if (flgs_z_buffer_i.empty || start_computation) begin
        z_height <= y_height;
      end
    end
  end

  assign cntrl_z_buffer_o.ready         = z_ready_i;
  assign cntrl_z_buffer_o.y_valid       = y_valid_i;
  assign cntrl_z_buffer_o.y_push_enable = y_push_en && ~stall_engine;
  // Gate fill by registered row_clk_en_q to perfectly align with the engine
  // clock gate (which is also derived from row_clk_en_q via tc_clk_gating).
  // This prevents fill from advancing when the engine is frozen due to
  // stall_engine or z_buf_draining transitions (1-cycle gate delay).
  assign cntrl_z_buffer_o.fill          = z_avail_en && row_clk_en_q[0];
  assign cntrl_z_buffer_o.first_load    = y_cols_iter_q == '0 && y_rows_iter_q == '0;

  assign cntrl_z_buffer_o.y_width       = y_width;
  assign cntrl_z_buffer_o.y_height      = y_height;
  assign cntrl_z_buffer_o.z_width       = z_width;
  assign cntrl_z_buffer_o.z_height      = z_height;


  /**********************************
   *           Counters             *
   **********************************/

  logic [$clog2(NumPipeRegs+1)-1:0] waits_cnt;
  logic                             waits_cnt_en;

  always_ff @(posedge clk_i or negedge rst_ni) begin : waits_counter
    if(~rst_ni) begin
      waits_cnt <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst)
        waits_cnt <= '0;
      else if (waits_cnt_en)
        waits_cnt <= waits_cnt == NumPipeRegs ? '0 : waits_cnt + 1;
    end
  end

  assign waits_cnt_en = ~stall_engine && current_state != IDLE && current_state != PRELOAD;

  /*****************************
   *       ENGINE CONTROL      *
   *****************************/

  logic reg_enable_d, reg_enable_q;

  assign reg_enable_d = computing;

  always_ff @(posedge clk_i or negedge rst_ni) begin : reg_enable_register
    if (~rst_ni) begin
      reg_enable_q <= '0;
    end else begin
      if (clear_i) begin
        reg_enable_q <= '0;
      end else begin
        reg_enable_q <= reg_enable_d;
      end
    end
  end

  assign reg_enable_o = reg_enable_q;

  assign cntrl_engine_o.fma_is_boxed     = 3'b111;
  assign cntrl_engine_o.noncomp_is_boxed = 2'b11;
  assign cntrl_engine_o.stage1_rnd       = fpnew_pkg::roundmode_e'(reg_file_i.hwpe_params[OP_SELECTION][31:29]);
  assign cntrl_engine_o.stage2_rnd       = fpnew_pkg::roundmode_e'(reg_file_i.hwpe_params[OP_SELECTION][28:26]);
  assign cntrl_engine_o.op1              = fpnew_pkg::operation_e'(reg_file_i.hwpe_params[OP_SELECTION][25:21]);
  assign cntrl_engine_o.op2              = fpnew_pkg::operation_e'(reg_file_i.hwpe_params[OP_SELECTION][20:16]);
  assign cntrl_engine_o.op_mod           = 1'b0;
  assign cntrl_engine_o.in_valid         = 1'b1;
  assign cntrl_engine_o.flush            = engine_flush_i;
  assign cntrl_engine_o.out_ready        = 1'b1;
  assign cntrl_engine_o.accumulate       = ~pushing_y;

  always_comb begin
    row_clk_en_d = '0;

    // Pause engine during z_avail + drain overlap. No replay freeze.
    if (computing && ~stall_engine && ~(z_avail_en && z_drain_guard)) begin
      for (int i = 0; i < z_width; i++) begin
        row_clk_en_d[i] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : row_clk_en_register
    if (~rst_ni) begin
      row_clk_en_q <= '0;
    end else begin
      if (clear_i) begin
        row_clk_en_q <= '0;
      end else begin
        row_clk_en_q <= row_clk_en_d;
      end
    end
  end

  assign cntrl_engine_o.row_clk_gate_en = row_clk_en_q;

  /*****************************
   *         CHECKS            *
   *****************************/

  // During the LOAD_W state we perform a series of checks to determine if the
  // computation can proceed or we have to stall the accelerator

  logic check_w_valid, check_w_valid_en;
  logic check_x_full, check_x_full_en;
  logic check_y_loaded, check_y_loaded_en;

  // Check if the next w row is valid
  // Keep the check active while MX unpack still has a beat in flight,
  // even after w_done fires, so the scheduler stalls until the last
  // unpacked row reaches the FIFO.
  assign check_w_valid     = w_valid_i;
  assign check_w_valid_en  = (~w_done | mx_w_pending_i) && w_needs_stream_valid;

  // Check if the x buffer is full
  // Only enable this check when a new set of x columns is to be loaded.
  // Extend the guard while MX unpack is still draining so that the
  // scheduler does not release the handoff before unpacked X data lands.
  assign check_x_full      = flgs_x_buffer_i.full;
  assign check_x_full_en   = x_refill && x_shift_cnt_q == H-1 && (~x_done | mx_x_pending_i);

  // Check if the new Y rows are loaded and ready to be pushed
  // Only enable this check when the results of an iteration are available
  assign check_y_loaded    = flgs_z_buffer_i.loaded;
  assign check_y_loaded_en = z_wait_counter_q == PIPE_REGS && ~w_done;

  /******************************
   *           FLAGS            *
   ******************************/

  assign stall_engine = current_state == LOAD_W && (
                          ~check_w_valid  && check_w_valid_en  ||
                          ~check_x_full   && check_x_full_en   ||
                          ~check_y_loaded && check_y_loaded_en
                        );


  always_ff @(posedge clk_i or negedge rst_ni) begin : first_load_register
    if(~rst_ni) begin
      first_load <= '1;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        first_load <= '1;
      end else if (current_state == LOAD_W && ~stall_engine) begin
        first_load <= '0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : computing_flag_register
    if(~rst_ni) begin
      computing <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        computing <= '0;
      end else if (current_state == PRELOAD && next_state == LOAD_W) begin
        computing <= '1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : x_refill_register
    if(~rst_ni) begin
      x_refill <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst || cntrl_x_buffer_o.rst_w_index) begin
        x_refill <= '0;
      end else if (flgs_x_buffer_i.empty) begin
        x_refill <= '1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : pushing_y_register
    if(~rst_ni) begin
      pushing_y <= '0;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst) begin
        pushing_y <= '0;
      end else begin
        pushing_y <= y_push_en;
      end
    end
  end

  assign start             = current_state == IDLE && cntrl_scheduler_i.first_load;
  assign start_computation = first_load && next_state == LOAD_W && ~stall_engine;

  assign flgs_scheduler_o.w_loaded = current_state == LOAD_W && ~stall_engine;

  /*********************************
   *            FSM                *
   *********************************/

  always_ff @(posedge clk_i or negedge rst_ni) begin : state_register
    if(~rst_ni) begin
      current_state <= IDLE;
    end else begin
      if (clear_i || cntrl_scheduler_i.rst)
        current_state <= IDLE;
      else
        current_state <= next_state;
    end
  end

  always_comb begin : fsm
    next_state = current_state;

    case (current_state)
      IDLE: begin
        if (cntrl_scheduler_i.first_load) begin
          next_state = PRELOAD;
        end
      end

      // Wait for the X and Y buffers to be full
      PRELOAD: begin
        if (reg_file_i.hwpe_params[OP_SELECTION][0]) begin
          if (flgs_x_buffer_i.full && flgs_z_buffer_i.loaded) begin
            next_state = LOAD_W;
          end
        end else begin // The Y matrix is not required
          if (flgs_x_buffer_i.full) begin
            next_state = LOAD_W;
          end
        end
      end

      // in this state we should check that everything is ready to be loaded and
      // if something's amiss stall the engine
      LOAD_W: begin
        if (~stall_engine) begin
          next_state = WAIT;
        end
      end

      WAIT: begin
        if (waits_cnt == NumPipeRegs && ~stall_engine) begin
          next_state = LOAD_W;
        end
      end
    endcase
  end

  /*************************************
   * Exponent buffer mark/rewind logic *
   *************************************/
  // K-tile boundary (not last): rewind X exponents to replay same M-tile's exponents
  // Use X-side timing (x_w_iters_en) rather than engine-side (w_cols_iter_en):
  // with the exp buffer total_count cap, the buffer runs dry before the engine
  // finishes the K-tile, so an engine-side trigger would deadlock.
  logic x_side_k_tile_not_last;
  assign x_side_k_tile_not_last = x_w_iters_en &&
      (x_w_iters_q != reg_file_i.hwpe_params[W_ITERS][15:0]-1);

  // M-tile boundary (not last): mark X exponents (new segment), rewind W exponents
  // (m_tile_boundary_not_last forward-declared near top of module)
  assign m_tile_boundary_not_last = w_mat_iters_en && !w_done_en;

  // X exp mark: save read_ptr at M-tile boundaries using X-SIDE timing.
  // x_rows_iter_en fires when the last K-tile's last N-tile empties the X buffer —
  // i.e., all X data for one M-tile has been consumed.  Using X-side timing ensures
  // the mark fires before the engine finishes, so the decoder can immediately start
  // filling the X buffer for the next M-tile (no gap from segment gating).
  // The first M-tile's mark (position 0) comes from reset/clear.
  logic x_side_m_tile_not_last;
  assign x_side_m_tile_not_last = x_rows_iter_en &&
      (x_rows_iter_q != reg_file_i.hwpe_params[X_ITERS][31:16]-1);

  assign x_exp_mark_o   = mx_enable_i && x_side_m_tile_not_last;

  // X exp rewind: replay exponents for K-tile > 0 within same M-tile
  assign x_exp_rewind_o = mx_enable_i && x_side_k_tile_not_last;

  // W exp mark: position 0 from reset/clear is correct. No explicit mark needed,
  // because start_computation fires AFTER the W decoder has already consumed exponents.
  assign w_exp_mark_o   = '0;

  // W exp rewind: replay all W exponents for each new M-tile
  assign w_exp_rewind_o = mx_enable_i && m_tile_boundary_not_last;

  /*************************************
   * M-tile transition tracking        *
   *************************************/
  // Track pending M-tile transition: set at boundary, cleared after z_avail + drain.
  // z_buf_draining and z_buf_was_draining already declared above (near z_avail logic)
  // (m_tile_rst_pending_q forward-declared near top of module)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      m_tile_rst_pending_q <= 1'b0;
    else if (clear_i || cntrl_scheduler_i.rst)
      m_tile_rst_pending_q <= 1'b0;
    else if (m_tile_boundary_not_last && mx_enable_i)
      m_tile_rst_pending_q <= 1'b1;
    else if (m_tile_rst_pending_q && !z_wait_en && !z_avail_en && !z_buf_draining && !z_buf_was_draining)
      m_tile_rst_pending_q <= 1'b0;
  end

  // gen_toggle_pulse: fires for 1 cycle when M-tile transition completes
  // (after z_avail + drain + z_buf_was_draining all clear)
  assign gen_toggle_pulse = m_tile_rst_pending_q && !z_wait_en && !z_avail_en && !z_buf_draining && !z_buf_was_draining;

  assign m_tile_transition_o = m_tile_rst_pending_q;

  // Clear W SCM at M-tile boundary for multi-K-tile MX configs.
  // During y_push (accumulate=0), the cascade is overwritten with Y_bias,
  // discarding X × 0 contributions from the zeroed SCM. After y_push ends
  // (~32 LOAD_W cycles), the SCM is fully refreshed with K0 data.
  assign w_scm_clear_o = 1'b0;

  // W FIFO rewind: mark at computation start (capture first H W FIFO entries),
  // rewind at M-tile boundary (replay captured entries to refresh SCM).
  // Mark fires once at the start of computation. The rewind FIFO captures
  // the first H entries that pass through during M0's K0 processing.
  // Rewind fires at gen_toggle_pulse (after M0's cascade drain completes),
  // replaying those H entries before M1's K0 computation starts.
  assign w_fifo_mark_o   = 1'b0;
  assign w_fifo_rewind_o = 1'b0;

  // Shadow register file capture/bypass for M-tile W buffer fix.
  // Capture: active during first H loads of M0 K0 (fills shadow with K0 data).
  // Bypass: active during first H loads after M-tile boundary (engine reads
  //         from shadow instead of stale SCM while SCM is being refreshed).
  // Separate counters for capture and bypass to avoid sharing conflicts
  logic [$clog2(H):0] shadow_cap_cnt_q, shadow_byp_cnt_q;
  logic shadow_capture_q, shadow_bypass_q, shadow_bypass_raw_q;

  // Capture: re-triggered at every K0 start to track the current w_row offset.
  // The shadow stores the first H W rows of each K0 pass at whatever w_row
  // positions the buffer happens to be at. At bypass time (after gen_toggle_pulse),
  // the FIFO delivers the same K0 data at the same w_row positions, so the shadow
  // matches the expected fresh data.
  logic k0_start_capture;
  assign k0_start_capture = (start_computation ||
      (w_cols_iter_en && w_cols_iter_q == reg_file_i.hwpe_params[W_ITERS][15:0] - 1))
      && mx_enable_i
      && reg_file_i.hwpe_params[W_ITERS][15:0] > 1
      && reg_file_i.hwpe_params[X_ITERS][31:16] > 1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      shadow_capture_q  <= 1'b0;
      shadow_cap_cnt_q  <= '0;
    end else if (clear_i || cntrl_scheduler_i.rst) begin
      shadow_capture_q  <= 1'b0;
      shadow_cap_cnt_q  <= '0;
    end else if (k0_start_capture) begin
      shadow_capture_q  <= 1'b1;
      shadow_cap_cnt_q  <= '0;
    end else if (shadow_capture_q && cntrl_w_buffer_o.load) begin
      if (shadow_cap_cnt_q == H - 1)
        shadow_capture_q <= 1'b0;
      shadow_cap_cnt_q <= shadow_cap_cnt_q + 1;
    end
  end

  // Bypass counter: active for first H loads after M-tile boundary
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      shadow_bypass_raw_q <= 1'b0;
      shadow_byp_cnt_q    <= '0;
    end else if (clear_i || cntrl_scheduler_i.rst) begin
      shadow_bypass_raw_q <= 1'b0;
      shadow_byp_cnt_q    <= '0;
    end else if (gen_toggle_pulse && mx_enable_i &&
                 reg_file_i.hwpe_params[W_ITERS][15:0] > 1) begin
      shadow_bypass_raw_q <= 1'b1;
      shadow_byp_cnt_q    <= '0;
    end else if (shadow_bypass_raw_q && cntrl_w_buffer_o.load) begin
      if (shadow_byp_cnt_q == H - 1)
        shadow_bypass_raw_q <= 1'b0;
      shadow_byp_cnt_q <= shadow_byp_cnt_q + 1;
    end
  end

  // Shadow bypass active after gen_toggle_pulse (M-tile transition complete).
  // During z_avail the engine reads stale SCM for M0's cascade tail (correct).
  // After gen_toggle_pulse: engine reads shadow K0 data for M1's first H loads,
  // while SCM is being refreshed with fresh K0 data from the FIFO.
  assign shadow_bypass_q = 1'b0;  // Shadow bypass not needed with SCM write-forwarding

  assign w_shadow_capture_o = shadow_capture_q;
  assign w_shadow_bypass_o  = shadow_bypass_q;
  // Shadow always has K0 data (full TILE width). Use D (TOT_DEPTH) not leftover.
  assign w_shadow_width_o   = D;

`ifndef SYNTHESIS
  always @(posedge clk_i) begin
    if (gen_toggle_pulse)
      $display("[DBG][GEN_TOGGLE] t=%0t w_rows_q=%0d w_cols_q=%0d shadow_byp_raw=%0b shadow_cap=%0b cap_cnt=%0d byp_cnt=%0d",
               $time, w_rows_iter_q, w_cols_iter_q, shadow_bypass_raw_q, shadow_capture_q, shadow_cap_cnt_q, shadow_byp_cnt_q);
    if (k0_start_capture)
      $display("[DBG][K0_CAP_START] t=%0t w_rows_q=%0d w_cols_q=%0d",
               $time, w_rows_iter_q, w_cols_iter_q);
    if (shadow_bypass_raw_q && cntrl_w_buffer_o.load && shadow_byp_cnt_q < 3)
      $display("[DBG][BYPASS_LOAD] t=%0t byp_cnt=%0d w_rows_q=%0d",
               $time, shadow_byp_cnt_q, w_rows_iter_q);
  end
`endif

endmodule : redmule_scheduler
