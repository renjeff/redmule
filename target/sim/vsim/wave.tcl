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

# Core
add wave -noupdate -group Core -group top -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$CorePath/*
# Top level
add wave -noupdate -group RedMulE -group top -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/*
add wave -noupdate -group RedMulE -group periph -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/periph/*
add wave -noupdate -group RedMulE -group tcdm -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/tcdm/*
# Streamer
add wave -noupdate -group Streamer -group top -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/*
add wave -noupdate -group Streamer -group LDST-Mux -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/i_ldst_mux/*
## X stream
add wave -noupdate -group Streamer -group X-Stream -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/gen_tcdm2stream[0]/i_load_tcdm_fifo/*
## W stream
add wave -noupdate -group Streamer -group W-Stream -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/gen_tcdm2stream[1]/i_load_tcdm_fifo/*
## Y stream
add wave -noupdate -group Streamer -group Y-Stream -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/gen_tcdm2stream[2]/i_load_tcdm_fifo/*
## Z stream
add wave -noupdate -group Streamer -group Z-Stream -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/i_stream_sink/*
add wave -noupdate -group Streamer -group Z-Stream -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/i_store_cast/*
add wave -noupdate -group Streamer -group Z-Stream -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/i_store_fifo/*
# Buffers and FIFOs
## X
add wave -noupdate -group X-channel -group x-buffer_fifo -group fifo_interface -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_fifo/*
add wave -noupdate -group X-channel -group x-buffer_fifo -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_x_buffer_fifo/*
add wave -noupdate -group X-channel -group x-buffer -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_x_buffer/*
# X Debug Path
add wave -noupdate -group X-Debug-Path -label {X Buffer Muxed Valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/x_buffer_muxed.valid
add wave -noupdate -group X-Debug-Path -label {X Buffer Muxed Ready} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/x_buffer_muxed.ready
add wave -noupdate -group X-Debug-Path -label {X Buffer Muxed Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_muxed.data
add wave -noupdate -group X-Debug-Path -label {X FIFO Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/x_buffer_fifo.valid
add wave -noupdate -group X-Debug-Path -label {X FIFO Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/x_buffer_fifo.ready
add wave -noupdate -group X-Debug-Path -label {X FIFO Data} -color Magenta -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_fifo.data
add wave -noupdate -group X-Debug-Path -label {X Buffer Load} -color Red -height $MinHeight $Testbench/$TopLevelPath/x_buffer_ctrl.load
add wave -noupdate -group X-Debug-Path -label {X Buffer All Ctrl} -color Red -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_ctrl
add wave -noupdate -group X-Debug-Path -label {X Buffer All Flags} -color Green -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_flgs
## W
add wave -noupdate -group W-channel -group w-buffer_fifo -group fifo_interface -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_buffer_fifo/*
add wave -noupdate -group W-channel -group w-buffer_fifo -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_w_buffer_fifo/*
add wave -noupdate -group W-channel -group w-buffer -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_w_buffer/*
## Y
add wave -noupdate -group Y-channel -group y-buffer_fifo -group fifo_interface -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/y_buffer_fifo/*
add wave -noupdate -group Y-channel -group y-buffer_fifo -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_y_buffer_fifo/*
## Z
add wave -noupdate -group Z-channel -group z-buffer_fifo -group fifo_interface -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_fifo/*
add wave -noupdate -group Z-channel -group z-buffer_fifo -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_z_buffer_fifo/*
add wave -noupdate -group Z-channel -group z-buffer -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_z_buffer/*
# Engine
set NumRows [examine -radix dec redmule_pkg::ARRAY_WIDTH]
set NumCols [examine -radix dec redmule_pkg::ARRAY_HEIGHT]

# High-level Engine Debug (avoid drilling into individual CEs)
add wave -noupdate -group Engine -group Engine-Top-Level -label {Engine Input Valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/in_valid
add wave -noupdate -group Engine -group Engine-Top-Level -label {Engine Output Ready} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/out_ready
add wave -noupdate -group Engine -group Engine-Top-Level -label {Engine Z Output} -color Green -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_d
add wave -noupdate -group Engine -group Engine-Top-Level -label {X Buffer to Engine} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_q
add wave -noupdate -group Engine -group Engine-Top-Level -label {W Buffer to Engine} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_buffer_q
add wave -noupdate -group Engine -group Engine-Top-Level -label {Y Bias to Engine} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/y_bias_q
add wave -noupdate -group Engine -group Engine-Top-Level -label {Any Out Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/any_out_valid
add wave -noupdate -group Engine -group Engine-Top-Level -label {Any In Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/any_in_ready
add wave -noupdate -group Engine -group Engine-Top-Level -label {FMA Op1} -color Magenta -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/op1
add wave -noupdate -group Engine -group Engine-Top-Level -label {FMA Op2} -color Magenta -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/op2
add wave -noupdate -group Engine -group Engine-Top-Level -label {Engine Enable} -color Red -height $MinHeight $Testbench/$TopLevelPath/reg_enable
# Engine FMA Internal Debug
add wave -noupdate -group Engine -group FMA-Internal-Debug -label {Engine Enable Signal} -color Red -height $MinHeight $Testbench/$TopLevelPath/reg_enable
add wave -noupdate -group Engine -group FMA-Internal-Debug -label {Engine Clear Signal} -color Pink -height $MinHeight $Testbench/$TopLevelPath/clear
add wave -noupdate -group Engine -group FMA-Internal-Debug -label {Row 0 X Input} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/x_input_i
add wave -noupdate -group Engine -group FMA-Internal-Debug -label {Row 0 W Input} -color Yellow -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/w_input_i
add wave -noupdate -group Engine -group FMA-Internal-Debug -label {Row 0 Z Output} -color Orange -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/z_output_o
add wave -noupdate -group Engine -group FMA-Internal-Debug -label {Row 0 Valid In} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/in_valid_i
add wave -noupdate -group Engine -group FMA-Internal-Debug -label {Row 0 Ready Out} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/in_ready_o
# Compute Element CE[0] Debug
add wave -noupdate -group Engine -group CE0-Debug -label {CE0 X Input} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/x_input_i
add wave -noupdate -group Engine -group CE0-Debug -label {CE0 W Input} -color Yellow -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/w_input_i
add wave -noupdate -group Engine -group CE0-Debug -label {CE0 Y Bias} -color Orange -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/y_bias_i
add wave -noupdate -group Engine -group CE0-Debug -label {CE0 Z Output} -color Red -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/z_output_o
add wave -noupdate -group Engine -group CE0-Debug -label {CE0 Valid In} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/in_valid_i
add wave -noupdate -group Engine -group CE0-Debug -label {CE0 Ready Out} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/in_ready_o
add wave -noupdate -group Engine -group CE0-Debug -label {CE0 Reg Enable} -color Pink -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/reg_enable_i
# Register Enable Debug Chain
add wave -noupdate -group Engine -group Enable-Debug -label {Top Level Reg Enable} -color Red -height $MinHeight $Testbench/$TopLevelPath/reg_enable
add wave -noupdate -group Engine -group Enable-Debug -label {Engine Reg Enable Input} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/reg_enable_i
add wave -noupdate -group Engine -group Enable-Debug -label {Row Reg Enable Input} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/reg_enable_i
# Pipeline and Output Registration Debug  
add wave -noupdate -group Engine -group Pipeline-Debug -label {CE0 Out Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/out_valid_o
add wave -noupdate -group Engine -group Pipeline-Debug -label {CE0 Out Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/gen_computing_element[0]/i_computing_element/out_ready_i
add wave -noupdate -group Engine -group Pipeline-Debug -label {Row Partial Result} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/partial_result[0]
add wave -noupdate -group Engine -group Pipeline-Debug -label {Row Output Q Register} -color Magenta -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/output_q[0]
# MX Output Path Debug - Correct Signal Chain
add wave -noupdate -group MX-Output-Path -label {Engine Output} -color Red -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_d
add wave -noupdate -group MX-Output-Path -label {MX Stage Input (WRONG)} -color Gray -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_output_stage/z_engine_data_i
add wave -noupdate -group MX-Output-Path -label {MX Stage Input (STREAM)} -color Yellow -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_q.data
add wave -noupdate -group MX-Output-Path -label {MX Stream Valid} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/z_buffer_q.valid
add wave -noupdate -group MX-Output-Path -label {MX Stage Output} -color Orange -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_output_stage/z_muxed_o.data
add wave -noupdate -group MX-Output-Path -label {MX Stage Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/z_muxed_o.valid
add wave -noupdate -group MX-Output-Path -label {MX Enable} -color Pink -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/mx_enable_i
# MX Output Valid Debug - Internal Signals
add wave -noupdate -group MX-Valid-Debug -label {MX Val Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/mx_val_valid
add wave -noupdate -group MX-Valid-Debug -label {MX Mux Valid Q} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/mx_mux_valid_q
add wave -noupdate -group MX-Valid-Debug -label {Z Engine Stream Valid} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/z_buffer_q.valid
add wave -noupdate -group MX-Valid-Debug -label {Final Valid Logic} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/z_muxed_o.valid
# Z Buffer Control Debug
add wave -noupdate -group Z-Buffer-Control -label {Z Buffer Flags Z Valid} -color Red -height $MinHeight $Testbench/$TopLevelPath/z_buffer_flgs.z_valid
add wave -noupdate -group Z-Buffer-Control -label {Z Buffer Ctrl Load} -color Green -height $MinHeight $Testbench/$TopLevelPath/z_buffer_ctrl.load
add wave -noupdate -group Z-Buffer-Control -label {Z Buffer Ctrl Clear} -color Pink -height $MinHeight $Testbench/$TopLevelPath/z_buffer_ctrl.clear
add wave -noupdate -group Z-Buffer-Control -label {Z Buffer All Ctrl} -color Orange -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_ctrl
add wave -noupdate -group Z-Buffer-Control -label {Z Buffer All Flags} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_flgs
# Z Valid Debug - Internal Components
add wave -noupdate -group Z-Valid-Debug -label {Z Buffer Store En} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_z_buffer/store_en
add wave -noupdate -group Z-Valid-Debug -label {Z Buffer Ctrl Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_z_buffer/ctrl_i.ready
add wave -noupdate -group Z-Valid-Debug -label {Z Valid Result} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_z_buffer/flags_o.z_valid
add wave -noupdate -group Z-Valid-Debug -label {Z Buffer State} -color Pink -height $MinHeight $Testbench/$TopLevelPath/i_z_buffer/current_state
add wave -noupdate -group Z-Valid-Debug -label {Z Buffer Load En} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/i_z_buffer/load_en
# Z Buffer Fill Signal Chain Debug
add wave -noupdate -group Z-Fill-Chain -label {Scheduler Fill Signal} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/cntrl_z_buffer_o.fill
add wave -noupdate -group Z-Fill-Chain -label {Z Avail En} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/z_avail_en
add wave -noupdate -group Z-Fill-Chain -label {Z Wait En} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/z_wait_en
add wave -noupdate -group Z-Fill-Chain -label {W Cols Iter En} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/w_cols_iter_en
add wave -noupdate -group Z-Fill-Chain -label {Reg Enable O} -color Pink -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/reg_enable_o
# W Iteration Debug - MX vs FP16 Iteration Mismatch
add wave -noupdate -group W-Iteration-Debug -label {W Rows Iter En} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/w_rows_iter_en
add wave -noupdate -group W-Iteration-Debug -label {W Rows Iter Q} -color Green -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_scheduler/w_rows_iter_q
add wave -noupdate -group W-Iteration-Debug -label {W Rows Threshold} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_scheduler/reg_file_i.hwpe_params[W_ITERS][31:16]
add wave -noupdate -group W-Iteration-Debug -label {Scheduler State} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/current_state
add wave -noupdate -group W-Iteration-Debug -label {W Valid I} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/w_valid_i
add wave -noupdate -group W-Iteration-Debug -label {Stall Engine} -color Pink -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/stall_engine
# Engine Stall Debug - What causes stall_engine
add wave -noupdate -group Engine-Stall-Debug -label {Stall Engine} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/stall_engine
add wave -noupdate -group Engine-Stall-Debug -label {Current State} -color White -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/current_state
add wave -noupdate -group Engine-Stall-Debug -label {check_w_valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_w_valid
add wave -noupdate -group Engine-Stall-Debug -label {check_w_valid_en} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_w_valid_en
add wave -noupdate -group Engine-Stall-Debug -label {check_x_full} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_x_full
add wave -noupdate -group Engine-Stall-Debug -label {check_x_full_en} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_x_full_en
add wave -noupdate -group Engine-Stall-Debug -label {check_y_loaded} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_y_loaded
add wave -noupdate -group Engine-Stall-Debug -label {check_y_loaded_en} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_y_loaded_en
add wave -noupdate -group Engine-Stall-Debug -label {w_valid_i} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/w_valid_i
add wave -noupdate -group Engine-Stall-Debug -label {w_done} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/w_done

# W Buffer FIFO Debug - trace w_valid_i source
add wave -noupdate -group W-Buffer-FIFO-Debug -label {w_buffer_fifo.valid} -color Red -height $MinHeight $Testbench/$TopLevelPath/w_buffer_fifo.valid
add wave -noupdate -group W-Buffer-FIFO-Debug -label {w_buffer_fifo.ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_buffer_fifo.ready
add wave -noupdate -group W-Buffer-FIFO-Debug -label {w_buffer_flgs.w_ready} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/w_buffer_flgs.w_ready
add wave -noupdate -group W-Buffer-FIFO-Debug -label {w_buffer_ctrl.load} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_buffer_ctrl.load
add wave -noupdate -group W-Buffer-FIFO-Debug -label {w_buffer_ctrl.clear} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/w_buffer_ctrl.clear
# Engine-Aggregation - Debug MX vs Non-MX Engine Behavior
add wave -noupdate -group Engine-Aggregation -label {Row 0 Final Output} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/z_output_o
add wave -noupdate -group Engine-Aggregation -label {Engine Result Array[0]} -color Magenta -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/result[0]
add wave -noupdate -group Engine-Aggregation -label {Engine Z Output} -color Red -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/z_output_o[0]
# MX Control Effect on Engine
add wave -noupdate -group MX-Control-Effect -label {MX Flags Enable} -color Green -height $MinHeight $Testbench/$TopLevelPath/cntrl_flags.mx_enable
add wave -noupdate -group MX-Control-Effect -label {Engine Control Accumulate} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/cntrl_engine.accumulate
add wave -noupdate -group MX-Control-Effect -label {Engine Control Clear} -color Pink -height $MinHeight $Testbench/$TopLevelPath/cntrl_engine.clear
add wave -noupdate -group MX-Control-Effect -label {Engine In Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/in_valid
add wave -noupdate -group MX-Control-Effect -label {Engine Out Ready} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/out_ready

for {set row 0}  {$row < $NumRows} {incr row} {
  for {set col 0}  {$col < $NumCols} {incr col} {
    add wave -noupdate -group Engine -group row_$row -group CE_$col -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[$row]/i_row/gen_computing_element[$col]/i_computing_element/*
  }
}
# Scheduler
add wave -noupdate -group Scheduler -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_scheduler/*
# Memory scheduler
add wave -noupdate -group Scheduler -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_memory_scheduler/*
# Controller
add wave -noupdate -group Controller -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_control/*
add wave -noupdate -group Controller -group RegFile -label {MACFG Register} -color Yellow -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_control/reg_file_q.hwpe_params(5)
add wave -noupdate -group Controller -group RegFile -label {MACFG bit 16} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_control/reg_file_q.hwpe_params(5)(16)
add wave -noupdate -group Controller -group RegFile -label {X_ADDR (idx 0)} -color Cyan -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_control/reg_file_q.hwpe_params(0)
add wave -noupdate -group Controller -group RegFile -label {All reg_file_q} -color Cyan -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_control/reg_file_q
add wave -noupdate -group Controller -group Tiler -label {MACFG from tiler input} -color Orange -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_control/i_cfg_tiler/reg_file_i.hwpe_params(5)
add wave -noupdate -group Controller -group Tiler -label {MACFG to tiler output} -color Orange -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_control/i_cfg_tiler/reg_file_o.hwpe_params(5)
# MX Data Path
add wave -noupdate -group MX-DataPath -label {MX Enable} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/mx_enable
# Engine Stall Root Cause - which check is failing?
add wave -noupdate -group Stall-Root-Cause -label {stall_engine (OVERALL)} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/stall_engine
add wave -noupdate -group Stall-Root-Cause -label {current_state} -color White -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/current_state
add wave -noupdate -group Stall-Root-Cause -label {w_check FAIL} -color Yellow -height $MinHeight -expand $Testbench/$TopLevelPath/i_scheduler/check_w_valid_en
add wave -noupdate -group Stall-Root-Cause -label {w_check PASS} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_w_valid
add wave -noupdate -group Stall-Root-Cause -label {x_check FAIL} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_x_full_en
add wave -noupdate -group Stall-Root-Cause -label {x_check PASS} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_x_full
add wave -noupdate -group Stall-Root-Cause -label {y_check FAIL} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_y_loaded_en
add wave -noupdate -group Stall-Root-Cause -label {y_check PASS} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/check_y_loaded
# W Data Path in MX Mode - why is w_valid_i intermittent?
add wave -noupdate -group W-MX-DataPath -label {w_buffer_fifo.valid (to sched)} -color Red -height $MinHeight $Testbench/$TopLevelPath/w_buffer_fifo.valid
add wave -noupdate -group W-MX-DataPath -label {w_buffer_muxed.valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_buffer_muxed.valid
add wave -noupdate -group W-MX-DataPath -label {target_is_w (arbiter)} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/target_is_w
add wave -noupdate -group W-MX-DataPath -label {w_mx_fp16_valid (decoder)} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_mx_fp16_valid
add wave -noupdate -group W-MX-DataPath -label {w_slot_valid (slot buf)} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/w_slot_valid
add wave -noupdate -group W-MX-DataPath -label {w_slot_exp_valid} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/w_slot_exp_valid
# Arbiter Priority Debug - is W getting prioritized?
add wave -noupdate -group Arbiter-Priority -label {w_fifo_empty} -color Red -height $MinHeight $Testbench/$TopLevelPath/w_fifo_flgs.empty
add wave -noupdate -group Arbiter-Priority -label {w_fifo_full} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_fifo_flgs.full
add wave -noupdate -group Arbiter-Priority -label {target_is_w (decoder)} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/target_is_w
add wave -noupdate -group Arbiter-Priority -label {target_is_x (decoder)} -color Green -height $MinHeight $Testbench/$TopLevelPath/target_is_x
add wave -noupdate -group Arbiter-Priority -label {w_buffer_fifo.valid} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/w_buffer_fifo.valid
add wave -noupdate -group Arbiter-Priority -label {stall_engine} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_scheduler/stall_engine
# Z Output Path - why is output data all zeros?
add wave -noupdate -group Z-Output-Path -label {z_buffer_d (engine out)} -color Red -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/z_buffer_d
add wave -noupdate -group Z-Output-Path -label {z_buffer_q.valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/z_buffer_q.valid
add wave -noupdate -group Z-Output-Path -label {z_buffer_q.ready} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/z_buffer_q.ready
add wave -noupdate -group Z-Output-Path -label {z_buffer_q.data} -color Green -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/z_buffer_q.data
add wave -noupdate -group Z-Output-Path -label {z_buffer_muxed.valid} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/z_buffer_muxed.valid
add wave -noupdate -group Z-Output-Path -label {z_buffer_muxed.data} -color Magenta -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/z_buffer_muxed.data
add wave -noupdate -group Z-Output-Path -label {z_buffer_fifo.valid} -color Pink -height $MinHeight $Testbench/$TopLevelPath/z_buffer_fifo.valid
add wave -noupdate -group Z-Output-Path -label {z_buffer_fifo.data} -color White -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/z_buffer_fifo.data
# MX Encoder Debug - is it producing FP8 data?
add wave -noupdate -group MX-Encoder-Debug -label {fifo_valid (eng FIFO)} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/fifo_valid
add wave -noupdate -group MX-Encoder-Debug -label {fifo_data_out (FP16)} -color Orange -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_mx_output_stage/fifo_data_out
add wave -noupdate -group MX-Encoder-Debug -label {mx_val_valid (FP8)} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/mx_val_valid
add wave -noupdate -group MX-Encoder-Debug -label {mx_val_data (FP8)} -color Green -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_mx_output_stage/mx_val_data
add wave -noupdate -group MX-Encoder-Debug -label {mx_z_buffer_data} -color Cyan -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_mx_output_stage/mx_z_buffer_data
add wave -noupdate -group MX-Encoder-Debug -label {mx_mux_valid_q} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/mx_mux_valid_q
add wave -noupdate -group MX-Encoder-Debug -label {mx_mux_data_q} -color Pink -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/i_mx_output_stage/mx_mux_data_q
# Z FIFO Handshake - why isn't data getting into the FIFO?
add wave -noupdate -group Z-FIFO-Handshake -label {z_buffer_muxed.valid (push)} -color Red -height $MinHeight $Testbench/$TopLevelPath/z_buffer_muxed.valid
add wave -noupdate -group Z-FIFO-Handshake -label {z_buffer_muxed.ready (push)} -color Orange -height $MinHeight $Testbench/$TopLevelPath/z_buffer_muxed.ready
add wave -noupdate -group Z-FIFO-Handshake -label {z_buffer_muxed.data} -color Yellow -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/z_buffer_muxed.data
add wave -noupdate -group Z-FIFO-Handshake -label {z_buffer_fifo.valid (pop)} -color Green -height $MinHeight $Testbench/$TopLevelPath/z_buffer_fifo.valid
add wave -noupdate -group Z-FIFO-Handshake -label {z_buffer_fifo.ready (pop)} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/z_buffer_fifo.ready
add wave -noupdate -group Z-FIFO-Handshake -label {z_buffer_fifo.data} -color Magenta -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/z_buffer_fifo.data
add wave -noupdate -group Z-FIFO-Handshake -label {z_fifo_flgs.empty} -color Pink -height $MinHeight $Testbench/$TopLevelPath/z_fifo_flgs.empty
add wave -noupdate -group Z-FIFO-Handshake -label {z_fifo_flgs.full} -color White -height $MinHeight $Testbench/$TopLevelPath/z_fifo_flgs.full
# Z Streamer Control - why isn't streamer reading from FIFO?
add wave -noupdate -group Z-Streamer-Control -label {z_stream_sink req_start} -color Red -height $MinHeight $Testbench/$TopLevelPath/cntrl_streamer.z_stream_sink_ctrl.req_start
add wave -noupdate -group Z-Streamer-Control -label {z_sink ready_start flag} -color Orange -height $MinHeight $Testbench/$TopLevelPath/flgs_streamer.z_stream_sink_flags.ready_start
add wave -noupdate -group Z-Streamer-Control -label {first_load} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/cntrl_scheduler.first_load
add wave -noupdate -group Z-Streamer-Control -label {z_stream_sink base_addr} -color Green -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/cntrl_streamer.z_stream_sink_ctrl.addressgen_ctrl.base_addr
add wave -noupdate -group Z-Streamer-Control -label {z_buffer_fifo.ready} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/z_buffer_fifo.ready
# Register File Debug - why does Z_ADDR get cleared?
add wave -noupdate -group RegFile-Debug -label {Z_ADDR (idx 2)} -color Red -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/reg_file.hwpe_params(2)
add wave -noupdate -group RegFile-Debug -label {X_ADDR (idx 0)} -color Orange -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/reg_file.hwpe_params(0)
add wave -noupdate -group RegFile-Debug -label {W_ADDR (idx 1)} -color Yellow -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/reg_file.hwpe_params(1)
add wave -noupdate -group RegFile-Debug -label {clear} -color Green -height $MinHeight $Testbench/$TopLevelPath/clear
add wave -noupdate -group RegFile-Debug -label {ctrl rst} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/cntrl_scheduler.rst
add wave -noupdate -group MX-DataPath -label {Any PE Valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/any_pe_valid
add wave -noupdate -group MX-DataPath -label {FIFO Push} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/fifo_push
add wave -noupdate -group MX-DataPath -label {FIFO Valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/fifo_valid
add wave -noupdate -group MX-DataPath -label {FIFO Pop} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/fifo_pop
add wave -noupdate -group MX-DataPath -label {Engine Output} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_d
add wave -noupdate -group MX-DataPath -label {FIFO Data Out} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/fifo_data_out
# MX Encoder
add wave -noupdate -group MX-Encoder -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_encoder/*
add wave -noupdate -group MX-Encoder -label {Shared Exponent} -color Yellow -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/mx_exp_data
add wave -noupdate -group MX-Encoder -label {Exponent Valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/mx_exp_valid
add wave -noupdate -group MX-Encoder -label {Exponent Ready} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/mx_exp_ready
# MX Exponent Stream
add wave -noupdate -group MX-Exponent-Stream -color Cyan -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/mx_exp_stream/*
# MX Decoder Arbiter Debug
add wave -noupdate -group MX-Decoder-Arbiter -label {MX Enable} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/mx_enable
add wave -noupdate -group MX-Decoder-Arbiter -label {FSM State (target_q)} -color Red -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/mx_dec_target_q
add wave -noupdate -group MX-Decoder-Arbiter -label {Group Counter} -color Red -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/mx_dec_group_cnt_q
add wave -noupdate -group MX-Decoder-Arbiter -label {X Request} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/x_req
add wave -noupdate -group MX-Decoder-Arbiter -label {W Request} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/w_req
add wave -noupdate -group MX-Decoder-Arbiter -label {Owner} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/mx_dec_owner
add wave -noupdate -group MX-Decoder-Arbiter -label {Target is X} -color Orange -height $MinHeight $Testbench/$TopLevelPath/target_is_x
# MX Decoder to Buffer Debug
add wave -noupdate -group MX-Decoder-Buffer -label {Engine X Buffer Input} -color Green -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_q
add wave -noupdate -group MX-Decoder-Buffer -label {Engine W Buffer Input} -color Green -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_buffer_q
add wave -noupdate -group MX-Decoder-Buffer -label {X MX FP16 Valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/x_mx_fp16_valid
add wave -noupdate -group MX-Decoder-Buffer -label {X MX FP16 Ready} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/x_mx_fp16_ready
add wave -noupdate -group MX-Decoder-Buffer -label {W MX FP16 Valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/w_mx_fp16_valid
add wave -noupdate -group MX-Decoder-Buffer -label {W MX FP16 Ready} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/w_mx_fp16_ready
add wave -noupdate -group MX-Decoder-Buffer -label {X MX FP16 Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_mx_fp16_data
add wave -noupdate -group MX-Decoder-Buffer -label {W MX FP16 Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_mx_fp16_data
add wave -noupdate -group MX-Decoder-Buffer -label {MX Dec Target} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/mx_dec_target
add wave -noupdate -group MX-Decoder-Buffer -label {Target is X} -color Orange -height $MinHeight $Testbench/$TopLevelPath/target_is_x
add wave -noupdate -group MX-Decoder-Buffer -label {Target is W} -color Orange -height $MinHeight $Testbench/$TopLevelPath/target_is_w
add wave -noupdate -group MX-Decoder-Buffer -label {X Buffer Muxed} -color Magenta -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_muxed
add wave -noupdate -group MX-Decoder-Buffer -label {W Buffer Muxed} -color Magenta -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_buffer_muxed
# MX Output Stage Debug
add wave -noupdate -group MX-Output-Stage -label {Engine Z Output} -color Green -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_d
add wave -noupdate -group MX-Output-Stage -label {Z Engine Stream} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_q
add wave -noupdate -group MX-Output-Stage -label {Z Buffer Muxed} -color Magenta -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/z_buffer_muxed
add wave -noupdate -group MX-Output-Stage -label {FIFO Grant} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/fifo_grant
add wave -noupdate -group MX-Output-Stage -label {FIFO Valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/fifo_valid
add wave -noupdate -group MX-Output-Stage -label {FIFO Pop} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/fifo_pop
add wave -noupdate -group MX-Output-Stage -label {FIFO Data Out} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/fifo_data_out
add wave -noupdate -group MX-Output-Stage -label {MX Val Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/mx_val_valid
add wave -noupdate -group MX-Output-Stage -label {MX Val Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/mx_val_ready
add wave -noupdate -group MX-Output-Stage -label {MX Val Data} -color Orange -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/mx_val_data
add wave -noupdate -group MX-Output-Stage -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_output_stage/*
add wave -noupdate -group MX-Decoder-Arbiter -label {Target is W} -color Orange -height $MinHeight $Testbench/$TopLevelPath/target_is_w
# MX Decoder Input Handshake
add wave -noupdate -group MX-Decoder-Input -label {Val Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/mx_dec_val_valid
add wave -noupdate -group MX-Decoder-Input -label {Val Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/mx_dec_val_ready
add wave -noupdate -group MX-Decoder-Input -label {Exp Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/mx_dec_exp_valid
add wave -noupdate -group MX-Decoder-Input -label {Exp Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/mx_dec_exp_ready
add wave -noupdate -group MX-Decoder-Input -label {Val Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/mx_dec_val_data
add wave -noupdate -group MX-Decoder-Input -label {Exp Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/mx_dec_exp_data
add wave -noupdate -group MX-Decoder-Input -label {Vector Mode} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/mx_dec_vector_mode
# MX Decoder Output Handshake
add wave -noupdate -group MX-Decoder-Output -label {FP16 Valid} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/mx_dec_fp16_valid
add wave -noupdate -group MX-Decoder-Output -label {FP16 Ready} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/mx_dec_fp16_ready
add wave -noupdate -group MX-Decoder-Output -label {FP16 Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/mx_dec_fp16_data
add wave -noupdate -group MX-Decoder-Output -label {X FP16 Valid} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/x_mx_fp16_valid
add wave -noupdate -group MX-Decoder-Output -label {W FP16 Valid} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/w_mx_fp16_valid
add wave -noupdate -group MX-Decoder-Output -label {X FP16 Ready} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/x_mx_fp16_ready
add wave -noupdate -group MX-Decoder-Output -label {W FP16 Ready} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/w_mx_fp16_ready
# X Input Streams
add wave -noupdate -group X-Input-Streams -label {X Buffer Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_buffer_d.valid
add wave -noupdate -group X-Input-Streams -label {X Buffer Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_buffer_d.ready
add wave -noupdate -group X-Input-Streams -label {X Buffer Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_d.data
add wave -noupdate -group X-Input-Streams -label {X Exp Stream Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_from_streamer.valid
add wave -noupdate -group X-Input-Streams -label {X Exp Stream Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_from_streamer.ready
add wave -noupdate -group X-Input-Streams -label {X Exp Stream Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_exp_from_streamer.data
add wave -noupdate -group X-Input-Streams -label {X Exp FIFO Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_stream_buffered.valid
add wave -noupdate -group X-Input-Streams -label {X Exp FIFO Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_stream_buffered.ready
add wave -noupdate -group X-Input-Streams -label {X Exp FIFO Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_exp_stream_buffered.data
add wave -noupdate -group X-Input-Streams -label {X Data Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_data_accept
add wave -noupdate -group X-Input-Streams -label {X Exp Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_exp_accept
# W Input Streams
add wave -noupdate -group W-Input-Streams -label {W Buffer Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_buffer_d.valid
add wave -noupdate -group W-Input-Streams -label {W Buffer Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_buffer_d.ready
add wave -noupdate -group W-Input-Streams -label {W Buffer Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_buffer_d.data
add wave -noupdate -group W-Input-Streams -label {W Exp Stream Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_exp_from_streamer.valid
add wave -noupdate -group W-Input-Streams -label {W Exp Stream Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_exp_from_streamer.ready
add wave -noupdate -group W-Input-Streams -label {W Exp Stream Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_exp_from_streamer.data
add wave -noupdate -group W-Input-Streams -label {W Exp FIFO Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_exp_stream_buffered.valid
add wave -noupdate -group W-Input-Streams -label {W Exp FIFO Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_exp_stream_buffered.ready
add wave -noupdate -group W-Input-Streams -label {W Exp FIFO Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_exp_stream_buffered.data
add wave -noupdate -group W-Input-Streams -label {W Data Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_data_accept
add wave -noupdate -group W-Input-Streams -label {W Exp Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_exp_accept
# X Slot Buffer
add wave -noupdate -group X-Slot-Buffer -label {X Data Ready For Beat} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_data_ready_for_beat
add wave -noupdate -group X-Slot-Buffer -label {X Data Count} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/x_data_count_q
add wave -noupdate -group X-Slot-Buffer -label {X Exp Count} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/x_exp_count_q
add wave -noupdate -group X-Slot-Buffer -label {X Slot Pair Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_slot_pair_ready
add wave -noupdate -group X-Slot-Buffer -label {X Slot Pop} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_slot_pop
add wave -noupdate -group X-Slot-Buffer -label {X Slot Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_slot_data
add wave -noupdate -group X-Slot-Buffer -label {X Slot Exp} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/x_slot_exp
add wave -noupdate -group X-Slot-Buffer -label {X Slot Valid} -color Red -height $MinHeight $Testbench/$TopLevelPath/x_slot_valid
add wave -noupdate -group X-Slot-Buffer -label {X Slot Exp Valid} -color Red -height $MinHeight $Testbench/$TopLevelPath/x_slot_exp_valid
add wave -noupdate -group X-Slot-Buffer -label {Consume X Slot} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/consume_x_slot
# W Slot Buffer
add wave -noupdate -group W-Slot-Buffer -label {W Data Ready For Beat} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_data_ready_for_beat
add wave -noupdate -group W-Slot-Buffer -label {W Data Count} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/w_data_count_q
add wave -noupdate -group W-Slot-Buffer -label {W Exp Count} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/w_exp_count_q
add wave -noupdate -group W-Slot-Buffer -label {W Slot Pair Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_slot_pair_ready
add wave -noupdate -group W-Slot-Buffer -label {W Slot Pop} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_slot_pop
add wave -noupdate -group W-Slot-Buffer -label {W Slot Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_slot_data
add wave -noupdate -group W-Slot-Buffer -label {W Slot Exp} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/w_slot_exp
add wave -noupdate -group W-Slot-Buffer -label {W Slot Valid} -color Red -height $MinHeight $Testbench/$TopLevelPath/w_slot_valid
add wave -noupdate -group W-Slot-Buffer -label {W Slot Exp Valid} -color Red -height $MinHeight $Testbench/$TopLevelPath/w_slot_exp_valid
add wave -noupdate -group W-Slot-Buffer -label {Consume W Slot} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/consume_w_slot
# X-Exp Stream from Streamer (TCDM source)
add wave -noupdate -group Streamer -group X-Exp-Stream -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/gen_tcdm2stream\[3\]/i_load_tcdm_fifo/*
# W-Exp Stream from Streamer (TCDM source)
add wave -noupdate -group Streamer -group W-Exp-Stream -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_streamer/gen_tcdm2stream\[4\]/i_load_tcdm_fifo/*
# MX exponent debug (single tab)
add wave -noupdate -group MX-Exponent-Debug -label {X Exp Stream Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_from_streamer.valid
add wave -noupdate -group MX-Exponent-Debug -label {X Exp Stream Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_from_streamer.ready
add wave -noupdate -group MX-Exponent-Debug -label {X Exp Stream Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_exp_from_streamer.data
add wave -noupdate -group MX-Exponent-Debug -label {X Exp FIFO Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_stream_buffered.valid
add wave -noupdate -group MX-Exponent-Debug -label {X Exp FIFO Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_stream_buffered.ready
add wave -noupdate -group MX-Exponent-Debug -label {X Exp FIFO Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_exp_stream_buffered.data
add wave -noupdate -group MX-Exponent-Debug -label {X Exp Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_exp_accept
add wave -noupdate -group MX-Exponent-Debug -label {X Exp Count} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/x_exp_count_q
add wave -noupdate -group MX-Exponent-Debug -label {X Slot Exp Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/x_slot_exp_valid
add wave -noupdate -group MX-Exponent-Debug -label {X Slot Exp} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/x_slot_exp
add wave -noupdate -group MX-Exponent-Debug -label {W Exp Stream Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_exp_from_streamer.valid
add wave -noupdate -group MX-Exponent-Debug -label {W Exp Stream Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_exp_from_streamer.ready
add wave -noupdate -group MX-Exponent-Debug -label {W Exp Stream Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_exp_from_streamer.data
add wave -noupdate -group MX-Exponent-Debug -label {W Exp FIFO Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_exp_stream_buffered.valid
add wave -noupdate -group MX-Exponent-Debug -label {W Exp FIFO Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_exp_stream_buffered.ready
add wave -noupdate -group MX-Exponent-Debug -label {W Exp FIFO Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_exp_stream_buffered.data
add wave -noupdate -group MX-Exponent-Debug -label {W Exp Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_exp_accept
add wave -noupdate -group MX-Exponent-Debug -label {W Exp Count} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/w_exp_count_q
add wave -noupdate -group MX-Exponent-Debug -label {W Slot Exp Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_slot_exp_valid
add wave -noupdate -group MX-Exponent-Debug -label {W Slot Exp} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/w_slot_exp

# MX Decoder Internal
add wave -noupdate -group MX-Decoder-Internal -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_decoder_shared/*

# X Exponent Buffer Debug
add wave -noupdate -group X-Exp-Buffer -label {Stream Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_x_exp_buffer/stream_i.valid
add wave -noupdate -group X-Exp-Buffer -label {Stream Ready (reg)} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_x_exp_buffer/ready_q
add wave -noupdate -group X-Exp-Buffer -label {Stream Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_x_exp_buffer/stream_i.data
add wave -noupdate -group X-Exp-Buffer -label {Input Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_x_exp_buffer/input_accept
add wave -noupdate -group X-Exp-Buffer -label {Occupancy} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_x_exp_buffer/occupancy_q
add wave -noupdate -group X-Exp-Buffer -label {Buffer Full} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_x_exp_buffer/buffer_full
add wave -noupdate -group X-Exp-Buffer -label {Buffer Empty} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_x_exp_buffer/buffer_empty
add wave -noupdate -group X-Exp-Buffer -label {Data Out} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_x_exp_buffer/data_o
add wave -noupdate -group X-Exp-Buffer -label {Valid Out} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_x_exp_buffer/valid_o
add wave -noupdate -group X-Exp-Buffer -label {Consume} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_x_exp_buffer/consume_i
add wave -noupdate -group X-Exp-Buffer -label {Write Ptr} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_x_exp_buffer/write_ptr_q
add wave -noupdate -group X-Exp-Buffer -label {Read Ptr} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_x_exp_buffer/read_ptr_q

# W Exponent Buffer Debug
add wave -noupdate -group W-Exp-Buffer -label {Stream Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_w_exp_buffer/stream_i.valid
add wave -noupdate -group W-Exp-Buffer -label {Stream Ready (reg)} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_w_exp_buffer/ready_q
add wave -noupdate -group W-Exp-Buffer -label {Stream Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_w_exp_buffer/stream_i.data
add wave -noupdate -group W-Exp-Buffer -label {Input Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_w_exp_buffer/input_accept
add wave -noupdate -group W-Exp-Buffer -label {Occupancy} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_w_exp_buffer/occupancy_q
add wave -noupdate -group W-Exp-Buffer -label {Buffer Full} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_w_exp_buffer/buffer_full
add wave -noupdate -group W-Exp-Buffer -label {Buffer Empty} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_w_exp_buffer/buffer_empty
add wave -noupdate -group W-Exp-Buffer -label {Data Out} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_w_exp_buffer/data_o
add wave -noupdate -group W-Exp-Buffer -label {Valid Out} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_w_exp_buffer/valid_o
add wave -noupdate -group W-Exp-Buffer -label {Consume} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_w_exp_buffer/consume_i
add wave -noupdate -group W-Exp-Buffer -label {Write Ptr} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_w_exp_buffer/write_ptr_q
add wave -noupdate -group W-Exp-Buffer -label {Read Ptr} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_w_exp_buffer/read_ptr_q

# Slot Buffer to Arbiter Interface
add wave -noupdate -group Slot-Buffer-Output -label {MX Enable} -color Red -height $MinHeight $Testbench/$TopLevelPath/cntrl_flags.mx_enable
add wave -noupdate -group Slot-Buffer-Output -label {X Slot Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_slot_valid
add wave -noupdate -group Slot-Buffer-Output -label {W Slot Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_slot_valid
add wave -noupdate -group Slot-Buffer-Output -label {X Slot Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_slot_data
add wave -noupdate -group Slot-Buffer-Output -label {W Slot Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_slot_data
add wave -noupdate -group Slot-Buffer-Output -label {X Slot Exp} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/x_slot_exp
add wave -noupdate -group Slot-Buffer-Output -label {W Slot Exp} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/w_slot_exp
add wave -noupdate -group Slot-Buffer-Output -label {Consume X Slot} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/consume_x_slot
add wave -noupdate -group Slot-Buffer-Output -label {Consume W Slot} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/consume_w_slot

# Arbiter State
add wave -noupdate -group Arbiter-State -label {MX Dec Target} -color Red -height $MinHeight $Testbench/$TopLevelPath/mx_dec_target
add wave -noupdate -group Arbiter-State -label {Target is X} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/target_is_x
add wave -noupdate -group Arbiter-State -label {Target is W} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/target_is_w
add wave -noupdate -group Arbiter-State -label {X Slot Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_slot_valid
add wave -noupdate -group Arbiter-State -label {X Slot Exp Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_slot_exp_valid
add wave -noupdate -group Arbiter-State -label {W Slot Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_slot_valid
add wave -noupdate -group Arbiter-State -label {W Slot Exp Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_slot_exp_valid
add wave -noupdate -group Arbiter-State -label {Decoder Val Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/mx_dec_val_ready
add wave -noupdate -group Arbiter-State -label {Decoder Exp Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/mx_dec_exp_ready

# Engine Input (X buffer)
add wave -noupdate -group Engine-Input -label {X Buffer Q Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_buffer_q.valid
add wave -noupdate -group Engine-Input -label {X Buffer Q Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_buffer_q.ready
add wave -noupdate -group Engine-Input -label {X Buffer Q Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/x_buffer_q.data
add wave -noupdate -group Engine-Input -label {W Buffer Q Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_buffer_q.valid
add wave -noupdate -group Engine-Input -label {W Buffer Q Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_buffer_q.ready
add wave -noupdate -group Engine-Input -label {W Buffer Q Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_buffer_q.data

# ===== MX INTEGRATION DEBUG - ALL CRITICAL SIGNALS IN ONE TAB =====
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[FSM] Target State} -color Red -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_arbiter/mx_dec_target_q
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[FSM] Owner (comb)} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_arbiter/mx_dec_owner
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[FSM] Start New} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/mx_dec_start_new
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[FSM] Group Counter} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_arbiter/mx_dec_group_cnt_q
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -divider {Latched Data (registered)}
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[REG] Val Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_arbiter/mx_dec_val_data_q
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[REG] Exp Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_arbiter/mx_dec_exp_data_q
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -divider {Slot Inputs (current)}
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[SLOT] X Data In} -color Green -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_arbiter/x_slot_data_i
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[SLOT] W Data In} -color Green -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_arbiter/w_slot_data_i
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -divider {Valid Signals (CRITICAL)}
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[OUT] Val Valid} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/mx_dec_val_valid_o
add wave -noupdate -group MX-Integration-Debug -group {1. Arbiter FSM & Timing} -label {[OUT] Exp Valid} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/mx_dec_exp_valid_o

add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[X] Data Count} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/x_data_count_q
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[X] Exp Count} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/x_exp_count_q
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[X] Count Diff} -color Red -height $MinHeight -radix decimal $Testbench/$TopLevelPath/i_mx_slot_buffer/x_data_count_q - $Testbench/$TopLevelPath/i_mx_slot_buffer/x_exp_count_q
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -divider
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[W] Data Count} -color Cyan -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/w_data_count_q
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[W] Exp Count} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_mx_slot_buffer/w_exp_count_q
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[W] Count Diff} -color Red -height $MinHeight -radix decimal $Testbench/$TopLevelPath/i_mx_slot_buffer/w_data_count_q - $Testbench/$TopLevelPath/i_mx_slot_buffer/w_exp_count_q
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -divider {Accept Signals}
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[X] Data Accept} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_data_accept
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[X] Exp Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_exp_accept
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[W] Data Accept} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_data_accept
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[W] Exp Accept} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_exp_accept
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -divider {Slot Pair Ready}
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[X] Slot Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_slot_valid
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[X] Slot Exp Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_slot_exp_valid
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[X] Pair Ready} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_slot_pair_ready
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[W] Slot Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_slot_valid
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[W] Slot Exp Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_slot_exp_valid
add wave -noupdate -group MX-Integration-Debug -group {2. Slot Buffer Sync} -label {[W] Pair Ready} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_slot_pair_ready

add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[X-EXP] Stream Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_stream_buffered.valid
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[X-EXP] Stream Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_stream_buffered.ready
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[X-EXP] Occupancy} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_x_exp_buffer/occupancy_q
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[X-EXP] Buffer Full} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_x_exp_buffer/buffer_full
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[X-EXP] Data Valid Out} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/x_exp_buf_valid
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[X-EXP] Consume} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/x_exp_buf_consume
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -divider
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[W-EXP] Stream Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_exp_stream_buffered.valid
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[W-EXP] Stream Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_exp_stream_buffered.ready
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[W-EXP] Occupancy} -color Orange -height $MinHeight -radix unsigned $Testbench/$TopLevelPath/i_w_exp_buffer/occupancy_q
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[W-EXP] Buffer Full} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_w_exp_buffer/buffer_full
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[W-EXP] Data Valid Out} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/w_exp_buf_valid
add wave -noupdate -group MX-Integration-Debug -group {3. Exp Buffer Backpressure} -label {[W-EXP] Consume} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/w_exp_buf_consume

add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[X-EXP] From Streamer Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_from_streamer.valid
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[X-EXP] From Streamer Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_exp_from_streamer.ready
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[X-EXP] From Streamer Data} -color Cyan -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/x_exp_from_streamer.data
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[X-EXP] Buffered Data} -color Yellow -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/x_exp_stream_buffered.data
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[X-EXP] Buffer Output Data} -color Orange -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/x_exp_buf_data
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -divider
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[W-EXP] From Streamer Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_exp_from_streamer.valid
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[W-EXP] From Streamer Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_exp_from_streamer.ready
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[W-EXP] From Streamer Data} -color Cyan -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/w_exp_from_streamer.data
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[W-EXP] Buffered Data} -color Yellow -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/w_exp_stream_buffered.data
add wave -noupdate -group MX-Integration-Debug -group {9. Exp Data Path} -label {[W-EXP] Buffer Output Data} -color Orange -height $MinHeight -radix hexadecimal $Testbench/$TopLevelPath/w_exp_buf_data

add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] Val Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/mx_dec_val_valid
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] Val Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/mx_dec_val_ready
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] Val Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/mx_dec_val_data
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] Exp Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/mx_dec_exp_valid
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] Exp Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/mx_dec_exp_ready
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] Exp Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/mx_dec_exp_data
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] Vector Mode} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/mx_dec_vector_mode
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -divider {Decoder Output}
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] FP16 Valid} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/mx_dec_fp16_valid
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] FP16 Ready} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/mx_dec_fp16_ready
add wave -noupdate -group MX-Integration-Debug -group {4. Decoder Interface} -label {[DEC] FP16 Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/mx_dec_fp16_data

add wave -noupdate -group MX-Integration-Debug -group {5. Slot Consume} -label {[ARB] Consume X Slot} -color Red -height $MinHeight $Testbench/$TopLevelPath/consume_x_slot
add wave -noupdate -group MX-Integration-Debug -group {5. Slot Consume} -label {[ARB] Consume W Slot} -color Red -height $MinHeight $Testbench/$TopLevelPath/consume_w_slot
add wave -noupdate -group MX-Integration-Debug -group {5. Slot Consume} -label {[SLOT] X Pop} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/x_slot_pop
add wave -noupdate -group MX-Integration-Debug -group {5. Slot Consume} -label {[SLOT] W Pop} -color Magenta -height $MinHeight $Testbench/$TopLevelPath/i_mx_slot_buffer/w_slot_pop

add wave -noupdate -group MX-Integration-Debug -group {6. FIFO Status} -label {[X-FIFO] Full} -color Red -height $MinHeight $Testbench/$TopLevelPath/x_fifo_flgs.full
add wave -noupdate -group MX-Integration-Debug -group {6. FIFO Status} -label {[X-FIFO] Empty} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/x_fifo_flgs.empty
add wave -noupdate -group MX-Integration-Debug -group {6. FIFO Status} -label {[W-FIFO] Full} -color Red -height $MinHeight $Testbench/$TopLevelPath/w_fifo_flgs.full
add wave -noupdate -group MX-Integration-Debug -group {6. FIFO Status} -label {[W-FIFO] Empty} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/w_fifo_flgs.empty

add wave -noupdate -group MX-Integration-Debug -group {7. Data Stream Handshakes} -label {[X] Data Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_buffer_d.valid
add wave -noupdate -group MX-Integration-Debug -group {7. Data Stream Handshakes} -label {[X] Data Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/x_buffer_d.ready
add wave -noupdate -group MX-Integration-Debug -group {7. Data Stream Handshakes} -label {[W] Data Valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_buffer_d.valid
add wave -noupdate -group MX-Integration-Debug -group {7. Data Stream Handshakes} -label {[W] Data Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/w_buffer_d.ready

add wave -noupdate -group MX-Integration-Debug -group {8. Arbiter Requests} -label {[ARB] X Req} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/x_req
add wave -noupdate -group MX-Integration-Debug -group {8. Arbiter Requests} -label {[ARB] W Req} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/w_req
add wave -noupdate -group MX-Integration-Debug -group {8. Arbiter Requests} -label {[ARB] X Req w/ Space} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/x_req_with_space
add wave -noupdate -group MX-Integration-Debug -group {8. Arbiter Requests} -label {[ARB] W Req w/ Space} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/w_req_with_space
add wave -noupdate -group MX-Integration-Debug -group {8. Arbiter Requests} -label {[ARB] X Slot Ready} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/x_slot_ready
add wave -noupdate -group MX-Integration-Debug -group {8. Arbiter Requests} -label {[ARB] W Slot Ready} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_mx_arbiter/w_slot_ready

add wave -noupdate -group MX-FIFO-Push-Debug -label {flgs_engine out_valid array} -color Red -height $MinHeight $Testbench/$TopLevelPath/flgs_engine.out_valid
add wave -noupdate -group MX-FIFO-Push-Debug -label {any_pe_valid} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/any_pe_valid
add wave -noupdate -group MX-FIFO-Push-Debug -label {fifo_push} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/fifo_push
add wave -noupdate -group MX-FIFO-Push-Debug -label {fifo_grant} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/fifo_grant_o
add wave -noupdate -group MX-FIFO-Push-Debug -label {mx_enable} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/mx_enable

add wave -noupdate -group MX-Enable-Timing -label {mx_enable} -color Red -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/mx_enable_i
add wave -noupdate -group MX-Enable-Timing -label {fifo_push} -color Orange -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/fifo_push
add wave -noupdate -group MX-Enable-Timing -label {fifo_valid} -color Yellow -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/fifo_valid
add wave -noupdate -group MX-Enable-Timing -label {encoder_ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/encoder_ready
add wave -noupdate -group MX-Enable-Timing -label {fifo_pop} -color Cyan -height $MinHeight $Testbench/$TopLevelPath/i_mx_output_stage/fifo_pop

add wave -noupdate -group Engine -group Pipeline-Debug -label {Row Partial Result[7]} -color Yellow -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/partial_result[7]
add wave -noupdate -group Engine -group Pipeline-Debug -label {Row Output Q[7]} -color Orange -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_redmule_engine/gen_redmule_rows[0]/i_row/output_q[7]

add wave -noupdate -group TCDM-Debug -label {TCDM Req} -color Red $Testbench/$TopLevelPath/tcdm.req
add wave -noupdate -group TCDM-Debug -label {TCDM Gnt} -color Green $Testbench/$TopLevelPath/tcdm.gnt
add wave -noupdate -group TCDM-Debug -label {TCDM Addr} -color Cyan -radix hexadecimal $Testbench/$TopLevelPath/tcdm.add
add wave -noupdate -group TCDM-Debug -label {TCDM Wen} -color Yellow $Testbench/$TopLevelPath/tcdm.wen
add wave -noupdate -group TCDM-Debug -label {TCDM Data} -color Magenta -radix hexadecimal $Testbench/$TopLevelPath/tcdm.data

add wave -noupdate -group Z-Sink-Debug -label {Z Sink Req Start} -color Red $Testbench/$TopLevelPath/cntrl_streamer.z_stream_sink_ctrl.req_start
add wave -noupdate -group Z-Sink-Debug -label {Z Sink Done} -color Green $Testbench/$TopLevelPath/flgs_streamer.z_stream_sink_flags.done
add wave -noupdate -group Z-Sink-Debug -label {Z Sink Base Addr} -color Cyan -radix hexadecimal $Testbench/$TopLevelPath/cntrl_streamer.z_stream_sink_ctrl.addressgen_ctrl.base_addr

add wave -noupdate -group Z-Sink-Debug -label {zstream2cast.data} -color Magenta -radix hexadecimal $Testbench/$TopLevelPath/i_streamer/zstream2cast.data
add wave -noupdate -group Z-Sink-Debug -label {zstream2cast.req} -color Red $Testbench/$TopLevelPath/i_streamer/zstream2cast.req
add wave -noupdate -group Z-Sink-Debug -label {zstream2cast.add} -color Cyan -radix hexadecimal $Testbench/$TopLevelPath/i_streamer/zstream2cast.add

add wave -noupdate -group MX-Timing-Debug -label {mx_enable} -color Red $Testbench/$TopLevelPath/cntrl_flags.mx_enable
add wave -noupdate -group MX-Timing-Debug -label {mx_mux_valid_q} -color Green $Testbench/$TopLevelPath/i_mx_output_stage/mx_mux_valid_q
add wave -noupdate -group MX-Timing-Debug -label {z_buffer_fifo.valid} -color Yellow $Testbench/$TopLevelPath/z_buffer_fifo.valid
add wave -noupdate -group MX-Timing-Debug -label {z_buffer_fifo.ready} -color Cyan $Testbench/$TopLevelPath/z_buffer_fifo.ready
add wave -noupdate -group MX-Timing-Debug -label {z_stream_sink done} -color Magenta $Testbench/$TopLevelPath/flgs_streamer.z_stream_sink_flags.done

# Remove the hierarchial strip from signals
config wave -signalnamewidth 1
