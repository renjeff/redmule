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
add wave -noupdate -group MX-Decoder-Arbiter -label {Owner is X} -color Orange -height $MinHeight $Testbench/$TopLevelPath/owner_is_x
add wave -noupdate -group MX-Decoder-Arbiter -label {Owner is W} -color Orange -height $MinHeight $Testbench/$TopLevelPath/owner_is_w
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
add wave -noupdate -group X-Input-Streams -label {X Exp Valid} -color Green -height $MinHeight $Testbench/x_mx_exp_stream.valid
add wave -noupdate -group X-Input-Streams -label {X Exp Ready} -color Green -height $MinHeight $Testbench/x_mx_exp_stream.ready
add wave -noupdate -group X-Input-Streams -label {X Exp Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/x_mx_exp_stream.data
# W Input Streams
add wave -noupdate -group W-Input-Streams -label {W Buffer Valid} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_buffer_d.valid
add wave -noupdate -group W-Input-Streams -label {W Buffer Ready} -color Green -height $MinHeight $Testbench/$TopLevelPath/w_buffer_d.ready
add wave -noupdate -group W-Input-Streams -label {W Buffer Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/$TopLevelPath/w_buffer_d.data
add wave -noupdate -group W-Input-Streams -label {W Exp Valid} -color Green -height $MinHeight $Testbench/w_mx_exp_stream.valid
add wave -noupdate -group W-Input-Streams -label {W Exp Ready} -color Green -height $MinHeight $Testbench/w_mx_exp_stream.ready
add wave -noupdate -group W-Input-Streams -label {W Exp Data} -color Cyan -height $MinHeight -radix $WavesRadix $Testbench/w_mx_exp_stream.data
# MX Decoder Internal
add wave -noupdate -group MX-Decoder-Internal -color {} -height $MinHeight -max $MaxHeight -radix $WavesRadix $Testbench/$TopLevelPath/i_mx_decoder_shared/*

# Remove the hierarchial strip from signals
config wave -signalnamewidth 1
