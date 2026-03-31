# Copyright 2021 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Yvan Tortorella <yvan.tortorella@unibo.it>

onerror {resume}
quietly WaveActivateNextPane {} 0

set Testbench redmule_tb_wrap/i_redmule_tb
set DutPath i_dut
set TopLevelPath $DutPath/i_redmule_top
if {$XifSel == {1}} {
  set CorePath $DutPath/gen_cv32e40x/i_core
} else {
  set CorePath $DutPath/gen_cv32e40p/i_core
}
set MinHeight 16
set MaxHeight 32
set WavesRadix hexadecimal
set SchedPath $TopLevelPath/i_scheduler
set WbufPath  $TopLevelPath/i_w_buffer
set ZbufPath  $TopLevelPath/i_z_buffer

# (Core, Streamer, Buffers, Engine omitted — add manually if needed)

# ---------------------------------------------------------------
# Scheduler (full — collapsed by default)
# ---------------------------------------------------------------
add wave -noupdate -group Scheduler -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$SchedPath/*

# (Controller, MX Encoder omitted — add manually if needed)

# ===============================================================
# M-tile Debug  (K-leftover investigation)
# Compare K=128 (passes) vs K=96 (fails, leftover=32)
# Key question: how z_height/y_height affect cascade flush at M-tile boundary
# ===============================================================

# -- Scheduler tile counters --
add wave -noupdate -group {M-tile Debug} -group {Tile Counters} -label {w_rows_iter_q} -color Cyan -height $MinHeight -radix unsigned $Testbench/$SchedPath/w_rows_iter_q
add wave -noupdate -group {M-tile Debug} -group {Tile Counters} -label {w_cols_iter_q} -color Cyan -height $MinHeight -radix unsigned $Testbench/$SchedPath/w_cols_iter_q
add wave -noupdate -group {M-tile Debug} -group {Tile Counters} -label {w_mat_iters_q} -color Cyan -height $MinHeight -radix unsigned $Testbench/$SchedPath/w_mat_iters_q
add wave -noupdate -group {M-tile Debug} -group {Tile Counters} -label {x_rows_iter_q} -color Green -height $MinHeight -radix unsigned $Testbench/$SchedPath/x_rows_iter_q
add wave -noupdate -group {M-tile Debug} -group {Tile Counters} -label {x_cols_iter_q} -color Green -height $MinHeight -radix unsigned $Testbench/$SchedPath/x_cols_iter_q
add wave -noupdate -group {M-tile Debug} -group {Tile Counters} -label {x_shift_cnt_q} -color Green -height $MinHeight -radix unsigned $Testbench/$SchedPath/x_shift_cnt_q
add wave -noupdate -group {M-tile Debug} -group {Tile Counters} -label {y_cols_iter_q} -color Magenta -height $MinHeight -radix unsigned $Testbench/$SchedPath/y_cols_iter_q
add wave -noupdate -group {M-tile Debug} -group {Tile Counters} -label {y_rows_iter_q} -color Magenta -height $MinHeight -radix unsigned $Testbench/$SchedPath/y_rows_iter_q

# -- FSM & stall --
add wave -noupdate -group {M-tile Debug} -group {FSM} -label {state} -color Yellow -height $MinHeight -radix unsigned $Testbench/$SchedPath/current_state
add wave -noupdate -group {M-tile Debug} -group {FSM} -label {stall_engine} -color Red -height $MinHeight $Testbench/$SchedPath/stall_engine
add wave -noupdate -group {M-tile Debug} -group {FSM} -label {computing} -color Yellow -height $MinHeight $Testbench/$SchedPath/computing
add wave -noupdate -group {M-tile Debug} -group {FSM} -label {w_done} -color Yellow -height $MinHeight $Testbench/$SchedPath/w_done

# -- M-tile boundary --
add wave -noupdate -group {M-tile Debug} -group {M-tile Boundary} -label {m_tile_boundary} -color Red -height $MinHeight $Testbench/$SchedPath/m_tile_boundary_not_last
add wave -noupdate -group {M-tile Debug} -group {M-tile Boundary} -label {m_tile_rst_pending} -color Red -height $MinHeight $Testbench/$SchedPath/m_tile_rst_pending_q
add wave -noupdate -group {M-tile Debug} -group {M-tile Boundary} -label {gen_toggle_pulse} -color Red -height $MinHeight $Testbench/$SchedPath/gen_toggle_pulse

# -- z_avail / z_wait / fill --
add wave -noupdate -group {M-tile Debug} -group {Z-avail} -label {z_wait_en} -color Orange -height $MinHeight $Testbench/$SchedPath/z_wait_en
add wave -noupdate -group {M-tile Debug} -group {Z-avail} -label {z_wait_counter} -color Orange -height $MinHeight -radix unsigned $Testbench/$SchedPath/z_wait_counter_q
add wave -noupdate -group {M-tile Debug} -group {Z-avail} -label {z_avail_en} -color Orange -height $MinHeight $Testbench/$SchedPath/z_avail_en
add wave -noupdate -group {M-tile Debug} -group {Z-avail} -label {z_avail_counter} -color Orange -height $MinHeight -radix unsigned $Testbench/$SchedPath/z_avail_counter_q
add wave -noupdate -group {M-tile Debug} -group {Z-avail} -label {z_height} -color {Orange Red} -height $MinHeight -radix unsigned $Testbench/$SchedPath/z_height
add wave -noupdate -group {M-tile Debug} -group {Z-avail} -label {z_width} -color {Orange Red} -height $MinHeight -radix unsigned $Testbench/$SchedPath/z_width
add wave -noupdate -group {M-tile Debug} -group {Z-avail} -label {z_buf_draining} -color Orange -height $MinHeight $Testbench/$SchedPath/z_buf_draining
add wave -noupdate -group {M-tile Debug} -group {Z-avail} -label {z_buf_was_draining} -color Orange -height $MinHeight $Testbench/$SchedPath/z_buf_was_draining

# -- y_push --
add wave -noupdate -group {M-tile Debug} -group {Y-push} -label {y_push_en} -color Magenta -height $MinHeight $Testbench/$SchedPath/y_push_en
add wave -noupdate -group {M-tile Debug} -group {Y-push} -label {y_push_counter} -color Magenta -height $MinHeight -radix unsigned $Testbench/$SchedPath/y_push_counter_q
add wave -noupdate -group {M-tile Debug} -group {Y-push} -label {y_height} -color {Magenta} -height $MinHeight -radix unsigned $Testbench/$SchedPath/y_height
add wave -noupdate -group {M-tile Debug} -group {Y-push} -label {y_width} -color Magenta -height $MinHeight -radix unsigned $Testbench/$SchedPath/y_width
add wave -noupdate -group {M-tile Debug} -group {Y-push} -label {pushing_y} -color Magenta -height $MinHeight $Testbench/$SchedPath/pushing_y
add wave -noupdate -group {M-tile Debug} -group {Y-push} -label {accumulate} -color Magenta -height $MinHeight $Testbench/$SchedPath/cntrl_engine_o.accumulate

# -- Engine clock gate --
add wave -noupdate -group {M-tile Debug} -group {Engine Gate} -label {row_clk_en_d[0]} -color Green -height $MinHeight $Testbench/$SchedPath/row_clk_en_d(0)
add wave -noupdate -group {M-tile Debug} -group {Engine Gate} -label {row_clk_en_q[0]} -color Green -height $MinHeight $Testbench/$SchedPath/row_clk_en_q(0)

# -- W buffer internals --
add wave -noupdate -group {M-tile Debug} -group {W-buffer} -label {w_row} -color Cyan -height $MinHeight -radix unsigned $Testbench/$WbufPath/w_row
add wave -noupdate -group {M-tile Debug} -group {W-buffer} -label {el_addr_q} -color Cyan -height $MinHeight -radix unsigned $Testbench/$WbufPath/el_addr_q
add wave -noupdate -group {M-tile Debug} -group {W-buffer} -label {col_addr_q} -color Cyan -height $MinHeight -radix unsigned $Testbench/$WbufPath/col_addr_q
add wave -noupdate -group {M-tile Debug} -group {W-buffer} -label {ctrl.load} -color Cyan -height $MinHeight $Testbench/$WbufPath/ctrl_i.load
add wave -noupdate -group {M-tile Debug} -group {W-buffer} -label {ctrl.shift} -color Cyan -height $MinHeight $Testbench/$WbufPath/ctrl_i.shift
add wave -noupdate -group {M-tile Debug} -group {W-buffer} -label {ctrl.height} -color Cyan -height $MinHeight -radix unsigned $Testbench/$WbufPath/ctrl_i.height
add wave -noupdate -group {M-tile Debug} -group {W-buffer} -label {ctrl.width} -color Cyan -height $MinHeight -radix unsigned $Testbench/$WbufPath/ctrl_i.width

# -- Z buffer state --
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {state} -color Yellow -height $MinHeight -radix unsigned $Testbench/$ZbufPath/current_state
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {d_index} -color Yellow -height $MinHeight -radix unsigned $Testbench/$ZbufPath/d_index
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {fill_shift} -color Yellow -height $MinHeight -radix unsigned $Testbench/$ZbufPath/fill_shift
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {w_index} -color Yellow -height $MinHeight -radix unsigned $Testbench/$ZbufPath/w_index
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {store_shift_q} -color Yellow -height $MinHeight -radix unsigned $Testbench/$ZbufPath/store_shift_q
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {loaded} -color Yellow -height $MinHeight $Testbench/$ZbufPath/flags_o.loaded
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {empty} -color Yellow -height $MinHeight $Testbench/$ZbufPath/flags_o.empty
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {z_valid} -color Yellow -height $MinHeight $Testbench/$ZbufPath/flags_o.z_valid
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {y_push_enable} -color Magenta -height $MinHeight $Testbench/$ZbufPath/ctrl_i.y_push_enable
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {fill} -color Orange -height $MinHeight $Testbench/$ZbufPath/ctrl_i.fill
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {first_load} -color Yellow -height $MinHeight $Testbench/$ZbufPath/ctrl_i.first_load
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {ctrl_i.y_height (struct)} -color Yellow -height $MinHeight -radix unsigned $Testbench/$ZbufPath/ctrl_i.y_height
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {ctrl_i.z_height (struct)} -color Yellow -height $MinHeight -radix unsigned $Testbench/$ZbufPath/ctrl_i.z_height
# Direct scheduler registers (bypass struct — more reliable in QuestaSim)
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {SCHED y_height} -color {Orange Red} -height $MinHeight -radix unsigned $Testbench/$SchedPath/y_height
add wave -noupdate -group {M-tile Debug} -group {Z-buffer} -label {SCHED z_height} -color {Orange Red} -height $MinHeight -radix unsigned $Testbench/$SchedPath/z_height

# -- Cascade output --
add wave -noupdate -group {M-tile Debug} -group {Cascade} -label {z_buffer_d[0]} -color White -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_d(0)
add wave -noupdate -group {M-tile Debug} -group {Cascade} -label {z_buffer_d[15]} -color White -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_d(15)
add wave -noupdate -group {M-tile Debug} -group {Cascade} -label {z_buffer_d[31]} -color White -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_d(31)

# -- Stall checks --
add wave -noupdate -group {M-tile Debug} -group {Stall Checks} -label {check_w_valid} -color Red -height $MinHeight $Testbench/$SchedPath/check_w_valid
add wave -noupdate -group {M-tile Debug} -group {Stall Checks} -label {check_w_valid_en} -color Red -height $MinHeight $Testbench/$SchedPath/check_w_valid_en
add wave -noupdate -group {M-tile Debug} -group {Stall Checks} -label {check_x_full} -color Red -height $MinHeight $Testbench/$SchedPath/check_x_full
add wave -noupdate -group {M-tile Debug} -group {Stall Checks} -label {check_x_full_en} -color Red -height $MinHeight $Testbench/$SchedPath/check_x_full_en
add wave -noupdate -group {M-tile Debug} -group {Stall Checks} -label {check_y_loaded} -color Red -height $MinHeight $Testbench/$SchedPath/check_y_loaded
add wave -noupdate -group {M-tile Debug} -group {Stall Checks} -label {check_y_loaded_en} -color Red -height $MinHeight $Testbench/$SchedPath/check_y_loaded_en

# Remove the hierarchical strip from signals
config wave -signalnamewidth 1
