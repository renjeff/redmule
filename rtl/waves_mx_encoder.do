# waves_mx_encoder.do
# Clean wave window
delete wave *

# Add clock + reset
add wave -divider "Top-level"
add wave sim:/tb_redmule_mx_encoder/clk_i
add wave sim:/tb_redmule_mx_encoder/rst_ni

# Handshake signals
add wave -divider "FP16 input stream"
add wave sim:/tb_redmule_mx_encoder/fp16_valid_i
add wave sim:/tb_redmule_mx_encoder/fp16_ready_o
add wave sim:/tb_redmule_mx_encoder/fp16_data_i

# DUT FSM + index
add wave -divider "FSM / control"
add wave sim:/tb_redmule_mx_encoder/dut/current_state
add wave sim:/tb_redmule_mx_encoder/dut/group_idx_q
add wave sim:/tb_redmule_mx_encoder/dut/e16_max_q

# Internal buffers
add wave -divider "Buffers"
add wave sim:/tb_redmule_mx_encoder/dut/fp16_buf_q
add wave sim:/tb_redmule_mx_encoder/dut/scale_reg_q

# Datapath signals per lane
add wave -divider "Datapath (per-lane)"
add wave sim:/tb_redmule_mx_encoder/dut/e16_lane
add wave sim:/tb_redmule_mx_encoder/dut/fp16_lane

# Outputs
add wave -divider "MX output streams"
add wave sim:/tb_redmule_mx_encoder/mx_val_valid_o
add wave sim:/tb_redmule_mx_encoder/mx_val_ready_i
add wave sim:/tb_redmule_mx_encoder/mx_val_data_o
add wave sim:/tb_redmule_mx_encoder/mx_exp_valid_o
add wave sim:/tb_redmule_mx_encoder/mx_exp_ready_i
add wave sim:/tb_redmule_mx_encoder/mx_exp_data_o

# Test progress
add wave -divider "Test tracking"
add wave sim:/tb_redmule_mx_encoder/test_idx
add wave sim:/tb_redmule_mx_encoder/error_count

# Zoom to full simulation
wave zoom full

# Run simulation
run -all
