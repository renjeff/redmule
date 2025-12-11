# waves_mx_decoder.do
# Clean wave window
delete wave *

# Add clock + reset
add wave -divider "Top-level"
add wave sim:/tb_redmule_mx_decoder/clk_i
add wave sim:/tb_redmule_mx_decoder/rst_ni

# Handshake signals
add wave -divider "MX input streams"
add wave sim:/tb_redmule_mx_decoder/mx_val_valid_i
add wave sim:/tb_redmule_mx_decoder/mx_val_ready_o
add wave sim:/tb_redmule_mx_decoder/mx_exp_valid_i
add wave sim:/tb_redmule_mx_decoder/mx_exp_ready_o

# DUT FSM + index
add wave -divider "FSM / control"
add wave sim:/tb_redmule_mx_decoder/dut/current_state
add wave sim:/tb_redmule_mx_decoder/dut/elem_idx_q

# Datapath inside DUT
add wave -divider "Datapath"
add wave sim:/tb_redmule_mx_decoder/dut/val_reg_q
add wave sim:/tb_redmule_mx_decoder/dut/scale_reg_q
add wave sim:/tb_redmule_mx_decoder/dut/elem_mx
add wave sim:/tb_redmule_mx_decoder/dut/elem_fp16_unscaled
add wave sim:/tb_redmule_mx_decoder/dut/elem_fp16_scaled

# Outputs
add wave -divider "FP16 output"
add wave sim:/tb_redmule_mx_decoder/fp16_valid_o
add wave sim:/tb_redmule_mx_decoder/fp16_data_o
add wave sim:/tb_redmule_mx_decoder/fp16_ready_i

# Test progress
add wave -divider "Test tracking"
add wave sim:/tb_redmule_mx_decoder/test_idx
add wave sim:/tb_redmule_mx_decoder/error_count

# Zoom to full simulation
wave zoom full

# Run simulation
run -all
