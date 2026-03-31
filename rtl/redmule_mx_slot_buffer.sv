// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// MX Slot Buffer Module
// Handles FP8 unpacking and slot buffering for X/W streams with independent
// mantissa / exponent queues so prefetch can continue when one side stalls.

`include "hci_helpers.svh"

module redmule_mx_slot_buffer
  import redmule_pkg::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned DATAW_ALIGN     = 512,
  parameter int unsigned MX_DATA_W       = 256,
  parameter int unsigned MX_EXP_VECTOR_W = 32,
  parameter int unsigned MX_INPUT_ELEM_WIDTH  = 8,
  parameter int unsigned MX_INPUT_NUM_ELEMS   = MX_DATA_W / MX_INPUT_ELEM_WIDTH,
  // Number of 256-bit slots buffered per stream (must be >= two beats)
  parameter int unsigned SLOT_FIFO_DEPTH = 4
)(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  input  logic mx_enable_i,
  input  mx_format_e mx_format_i,

  // Data streams from streamer (streaming interfaces)
  hwpe_stream_intf_stream.sink x_data_i,
  hwpe_stream_intf_stream.sink w_data_i,

  // Exponent inputs: direct register access from prefetch buffers (NO streaming protocol)
  input  logic [7:0]                 x_exp_data_i,
  input  logic                      x_exp_valid_i,
  output logic                      x_exp_consume_o,
  input  logic [MX_EXP_VECTOR_W-1:0] w_exp_data_i,
  input  logic                      w_exp_valid_i,
  output logic                      w_exp_consume_o,

  // Slot outputs (data valid follows mantissa queue, exp valid follows exponent queue)
  output logic                      x_slot_valid_o,
  output logic                      x_slot_exp_valid_o,
  output logic                      w_slot_valid_o,
  output logic                      w_slot_exp_valid_o,
  output logic [MX_DATA_W-1:0]      x_slot_data_o,
  output logic [MX_DATA_W-1:0]      w_slot_data_o,
  output logic [7:0]                x_slot_exp_o,
  output logic [MX_EXP_VECTOR_W-1:0] w_slot_exp_o,

  // Control from arbiter
  input  logic consume_x_slot_i,
  input  logic consume_w_slot_i
);

// FP8 unpacking: extract 32 bytes from interleaved 16-bit layout
function automatic logic [MX_DATA_W-1:0] mx_unpack_fp8(input logic [MX_DATA_W-1:0] half_data);
  logic [MX_DATA_W-1:0] unpacked;
  for (int i = 0; i < MX_INPUT_NUM_ELEMS; i++) begin
    automatic int word_idx = i / 2;
    automatic int is_upper = i % 2;
    unpacked[i*8 +: 8] = is_upper ?
      half_data[word_idx*16 + 8 +: 8] :
      half_data[word_idx*16 +: 8];
  end
  return unpacked;
endfunction

// FP6 unpacking: extract 32 six-bit elements from 192-bit block into 256-bit slot
// Input: 192 bits = 32 tightly-packed 6-bit elements
// Output: 256 bits = 32 × 8-bit containers ({2'b0, 6-bit element})
function automatic logic [MX_DATA_W-1:0] mx_unpack_fp6(input logic [191:0] packed_data);
  logic [MX_DATA_W-1:0] unpacked;
  for (int i = 0; i < 32; i++) begin
    unpacked[i*8 +: 8] = {2'b0, packed_data[i*6 +: 6]};
  end
  return unpacked;
endfunction

// FP4 unpacking: extract 32 nibbles from 128-bit block into 256-bit slot
// Input: 128 bits = 32 tightly-packed 4-bit elements
// Output: 256 bits = 32 × 8-bit containers ({4'b0, nibble})
function automatic logic [MX_DATA_W-1:0] mx_unpack_fp4(input logic [127:0] packed_data);
  logic [MX_DATA_W-1:0] unpacked;
  for (int i = 0; i < 32; i++) begin
    unpacked[i*8 +: 8] = {4'b0, packed_data[i*4 +: 4]};
  end
  return unpacked;
endfunction

// Max slots per beat: FP4 has 8 blocks of 128b in 1024b beat
localparam int unsigned SLOTS_PER_BEAT_FP8 = DATAW_ALIGN / MX_DATA_W;  // 4
localparam int unsigned SLOTS_PER_BEAT     = DATAW_ALIGN / (MX_DATA_W / 2);  // 8 (max for FP4)
localparam int unsigned SLOT_BYTES     = MX_DATA_W / 8;
localparam int unsigned SLOT_PTR_W     = (SLOT_FIFO_DEPTH > 1) ? $clog2(SLOT_FIFO_DEPTH) : 1;
localparam int unsigned SLOT_CNT_W     = $clog2(SLOT_FIFO_DEPTH + 1);
// Runtime accept level based on format
localparam int unsigned SLOTS_PER_BEAT_FP6 = 5;  // 5 × 192 = 960 bits per beat
logic [SLOT_CNT_W-1:0] rt_slots_per_beat;
always_comb begin
  case (mx_format_i)
    MX_FMT_E2M1: rt_slots_per_beat = SLOT_CNT_W'(SLOTS_PER_BEAT);      // 8 for FP4
    MX_FMT_E3M2,
    MX_FMT_E2M3: rt_slots_per_beat = SLOT_CNT_W'(SLOTS_PER_BEAT_FP8);  // FP6 uses 8-bit containers (same as FP8)
    default:      rt_slots_per_beat = SLOT_CNT_W'(SLOTS_PER_BEAT_FP8);  // 4 for FP8
  endcase
end

localparam int unsigned X_EXP_FIFO_DEPTH = SLOT_FIFO_DEPTH + 2;  // room for pending beats
localparam int unsigned X_EXP_PTR_W      = (X_EXP_FIFO_DEPTH > 1) ? $clog2(X_EXP_FIFO_DEPTH) : 1;
localparam int unsigned X_EXP_CNT_W      = $clog2(X_EXP_FIFO_DEPTH + 1);
localparam logic [X_EXP_CNT_W-1:0] X_EXP_DEPTH_CONST = X_EXP_FIFO_DEPTH;

localparam int unsigned W_EXP_FIFO_DEPTH = SLOT_FIFO_DEPTH + 2;
localparam int unsigned W_EXP_PTR_W      = (W_EXP_FIFO_DEPTH > 1) ? $clog2(W_EXP_FIFO_DEPTH) : 1;
localparam int unsigned W_EXP_CNT_W      = $clog2(W_EXP_FIFO_DEPTH + 1);
localparam logic [W_EXP_CNT_W-1:0] W_EXP_DEPTH_CONST = W_EXP_FIFO_DEPTH;

initial begin
  if (SLOT_FIFO_DEPTH < 2*SLOTS_PER_BEAT) begin
    $fatal(1, "Slot buffer depth (%0d) must hold at least two max-beats (%0d)", SLOT_FIFO_DEPTH, 2*SLOTS_PER_BEAT);
  end
end

function automatic logic [SLOT_PTR_W-1:0] bump_slot_ptr(
  input logic [SLOT_PTR_W-1:0] ptr,
  input int unsigned inc
);
  logic [SLOT_PTR_W-1:0] tmp;
  logic [SLOT_PTR_W-1:0] last_slot;
  tmp = ptr;
  last_slot = SLOT_FIFO_DEPTH-1;
  for (int i = 0; i < inc; i++) begin
    if (tmp == last_slot) begin
      tmp = '0;
    end else begin
      tmp = tmp + 1'b1;
    end
  end
  return tmp;
endfunction

function automatic logic [X_EXP_PTR_W-1:0] bump_xexp_ptr(
  input logic [X_EXP_PTR_W-1:0] ptr,
  input int unsigned inc
);
  logic [X_EXP_PTR_W-1:0] tmp;
  logic [X_EXP_PTR_W-1:0] last_slot;
  tmp = ptr;
  last_slot = X_EXP_FIFO_DEPTH-1;
  for (int i = 0; i < inc; i++) begin
    if (tmp == last_slot) begin
      tmp = '0;
    end else begin
      tmp = tmp + 1'b1;
    end
  end
  return tmp;
endfunction

function automatic logic [W_EXP_PTR_W-1:0] bump_wexp_ptr(
  input logic [W_EXP_PTR_W-1:0] ptr,
  input int unsigned inc
);
  logic [W_EXP_PTR_W-1:0] tmp;
  logic [W_EXP_PTR_W-1:0] last_slot;
  tmp = ptr;
  last_slot = W_EXP_FIFO_DEPTH-1;
  for (int i = 0; i < inc; i++) begin
    if (tmp == last_slot) begin
      tmp = '0;
    end else begin
      tmp = tmp + 1'b1;
    end
  end
  return tmp;
endfunction

// Storage for mantissas
logic [MX_DATA_W-1:0] x_data_mem [SLOT_FIFO_DEPTH-1:0];
logic [MX_DATA_W-1:0] w_data_mem [SLOT_FIFO_DEPTH-1:0];

logic [SLOT_PTR_W-1:0] x_data_head_q, x_data_tail_q;
logic [SLOT_PTR_W-1:0] w_data_head_q, w_data_tail_q;
logic [SLOT_CNT_W-1:0] x_data_count_q, w_data_count_q;

// Storage for exponents
logic [7:0] x_exp_mem [X_EXP_FIFO_DEPTH-1:0];
logic [MX_EXP_VECTOR_W-1:0] w_exp_mem [W_EXP_FIFO_DEPTH-1:0];

logic [X_EXP_PTR_W-1:0] x_exp_head_q, x_exp_tail_q;
logic [W_EXP_PTR_W-1:0] w_exp_head_q, w_exp_tail_q;
logic [X_EXP_CNT_W-1:0] x_exp_count_q;
logic [W_EXP_CNT_W-1:0] w_exp_count_q;

// Unpacked data (one slot per 256b chunk of the beat)
logic [MX_DATA_W-1:0] x_unpacked [SLOTS_PER_BEAT];
logic [MX_DATA_W-1:0] w_unpacked [SLOTS_PER_BEAT];
logic [SLOTS_PER_BEAT-1:0] x_slot_has_data;
logic [SLOTS_PER_BEAT-1:0] w_slot_has_data;
logic [SLOT_CNT_W-1:0] x_slots_in_beat;
logic [SLOT_CNT_W-1:0] w_slots_in_beat;

// FP6 block size
localparam int unsigned FP6_BLOCK_W     = 192;  // 32 × 6 bits
localparam int unsigned FP6_BLOCK_BYTES = FP6_BLOCK_W / 8;  // 24 bytes

// FP4 block size
localparam int unsigned FP4_BLOCK_W     = 128;  // 32 × 4 bits
localparam int unsigned FP4_BLOCK_BYTES = FP4_BLOCK_W / 8;

always_comb begin
  x_slots_in_beat = '0;
  w_slots_in_beat = '0;

  // Default zero
  for (int s = 0; s < SLOTS_PER_BEAT; s++) begin
    x_unpacked[s] = '0;
    w_unpacked[s] = '0;
    x_slot_has_data[s] = 1'b0;
    w_slot_has_data[s] = 1'b0;
  end

  if (!mx_enable_i) begin
    // FP16 passthrough
    x_unpacked[0] = x_data_i.data[MX_DATA_W-1:0];
    w_unpacked[0] = w_data_i.data[MX_DATA_W-1:0];
    x_slot_has_data[0] = 1'b1;
    w_slot_has_data[0] = 1'b1;
    x_slots_in_beat = 1;
    w_slots_in_beat = 1;
  end else if (mx_format_i == MX_FMT_E2M1) begin
    // FP4 tight packed: 8 blocks of 128 bits per 1024-bit beat
    for (int s = 0; s < SLOTS_PER_BEAT; s++) begin
      x_unpacked[s] = mx_unpack_fp4(x_data_i.data[s*FP4_BLOCK_W +: FP4_BLOCK_W]);
      w_unpacked[s] = mx_unpack_fp4(w_data_i.data[s*FP4_BLOCK_W +: FP4_BLOCK_W]);
      x_slot_has_data[s] = |x_data_i.strb[s*FP4_BLOCK_BYTES +: FP4_BLOCK_BYTES];
      w_slot_has_data[s] = |w_data_i.strb[s*FP4_BLOCK_BYTES +: FP4_BLOCK_BYTES];
      if (x_slot_has_data[s]) x_slots_in_beat = x_slots_in_beat + 1'b1;
      if (w_slot_has_data[s]) w_slots_in_beat = w_slots_in_beat + 1'b1;
    end
  end else begin
    // FP8/FP6: 4 blocks of 256 bits per 1024-bit beat
    for (int s = 0; s < SLOTS_PER_BEAT_FP8; s++) begin
      x_unpacked[s] = mx_unpack_fp8(x_data_i.data[s*MX_DATA_W +: MX_DATA_W]);
      w_unpacked[s] = mx_unpack_fp8(w_data_i.data[s*MX_DATA_W +: MX_DATA_W]);
      x_slot_has_data[s] = |x_data_i.strb[s*SLOT_BYTES +: SLOT_BYTES];
      w_slot_has_data[s] = |w_data_i.strb[s*SLOT_BYTES +: SLOT_BYTES];
      if (x_slot_has_data[s]) x_slots_in_beat = x_slots_in_beat + 1'b1;
      if (w_slot_has_data[s]) w_slots_in_beat = w_slots_in_beat + 1'b1;
    end
  end
end

// Ready/accept logic for mantissas (runtime: room for actual slots per beat)
logic x_data_ready_for_beat, w_data_ready_for_beat;
logic [SLOT_CNT_W-1:0] rt_accept_level;
assign rt_accept_level = SLOT_CNT_W'(SLOT_FIFO_DEPTH) - rt_slots_per_beat;
assign x_data_ready_for_beat = (x_data_count_q <= rt_accept_level);
assign w_data_ready_for_beat = (w_data_count_q <= rt_accept_level);

assign x_data_i.ready = mx_enable_i ? x_data_ready_for_beat : 1'b1;
assign w_data_i.ready = mx_enable_i ? w_data_ready_for_beat : 1'b1;

logic x_data_accept, w_data_accept;
assign x_data_accept = mx_enable_i && x_data_i.valid && x_data_ready_for_beat;
assign w_data_accept = mx_enable_i && w_data_i.valid && w_data_ready_for_beat;

// Exponent acceptance: SYNCHRONIZED with data slots
// Only accept exponents when we have corresponding data slots available
// This prevents exp buffer from filling up while waiting for data
logic x_exp_fifo_has_space, w_exp_fifo_has_space;
assign x_exp_fifo_has_space = (x_exp_count_q < X_EXP_DEPTH_CONST);
assign w_exp_fifo_has_space = (w_exp_count_q < W_EXP_DEPTH_CONST);

// NEW: Only accept exps when data count >= exp count (keep them synchronized)
// Allow exp to catch up fully since data arrives in bursts of SLOTS_PER_BEAT
// and we want to maintain data_count - exp_count <= SLOTS_PER_BEAT
logic x_data_ahead_or_equal, w_data_ahead_or_equal;
assign x_data_ahead_or_equal = (x_data_count_q >= x_exp_count_q);
assign w_data_ahead_or_equal = (w_data_count_q >= w_exp_count_q);

logic x_exp_accept, w_exp_accept;
assign x_exp_accept = mx_enable_i && x_exp_valid_i && x_exp_fifo_has_space && x_data_ahead_or_equal;
assign w_exp_accept = mx_enable_i && w_exp_valid_i && w_exp_fifo_has_space && w_data_ahead_or_equal;
assign x_exp_consume_o = x_exp_accept;
assign w_exp_consume_o = w_exp_accept;

// Slot valid flags
assign x_slot_valid_o     = (x_data_count_q != '0);
assign w_slot_valid_o     = (w_data_count_q != '0);
assign x_slot_exp_valid_o = (x_exp_count_q != '0);
assign w_slot_exp_valid_o = (w_exp_count_q != '0);

assign x_slot_data_o = x_slot_valid_o ? x_data_mem[x_data_head_q] : '0;
assign w_slot_data_o = w_slot_valid_o ? w_data_mem[w_data_head_q] : '0;
assign x_slot_exp_o  = x_slot_exp_valid_o ? x_exp_mem[x_exp_head_q] : '0;
assign w_slot_exp_o  = w_slot_exp_valid_o ? w_exp_mem[w_exp_head_q] : '0;

logic x_slot_pair_ready, w_slot_pair_ready;
assign x_slot_pair_ready = x_slot_valid_o && x_slot_exp_valid_o;
assign w_slot_pair_ready = w_slot_valid_o && w_slot_exp_valid_o;

// Pop on every consume pulse (pipelined arbiter sends back-to-back consumes)
logic x_slot_pop, w_slot_pop;
assign x_slot_pop = consume_x_slot_i && x_slot_pair_ready;
assign w_slot_pop = consume_w_slot_i && w_slot_pair_ready;

// Next-state logic for pointers / counters
logic [SLOT_PTR_W-1:0] x_data_head_d, x_data_tail_d;
logic [SLOT_PTR_W-1:0] w_data_head_d, w_data_tail_d;
logic [SLOT_CNT_W-1:0] x_data_count_d, w_data_count_d;
logic [X_EXP_PTR_W-1:0] x_exp_head_d, x_exp_tail_d;
logic [W_EXP_PTR_W-1:0] w_exp_head_d, w_exp_tail_d;
logic [X_EXP_CNT_W-1:0] x_exp_count_d;
logic [W_EXP_CNT_W-1:0] w_exp_count_d;

always_comb begin
  // Mantissa FIFO next state
  x_data_head_d  = x_data_head_q;
  x_data_tail_d  = x_data_tail_q;
  x_data_count_d = x_data_count_q;
  w_data_head_d  = w_data_head_q;
  w_data_tail_d  = w_data_tail_q;
  w_data_count_d = w_data_count_q;

  if (x_data_accept) begin
    logic [SLOT_PTR_W-1:0] tail_tmp;
    tail_tmp = x_data_tail_d;
    for (int s = 0; s < SLOTS_PER_BEAT; s++) begin
      if (x_slot_has_data[s]) begin
        tail_tmp = bump_slot_ptr(tail_tmp, 1);
      end
    end
    x_data_tail_d  = tail_tmp;
    x_data_count_d = x_data_count_d + x_slots_in_beat;
  end
  if (w_data_accept) begin
    logic [SLOT_PTR_W-1:0] tail_tmp;
    tail_tmp = w_data_tail_d;
    for (int s = 0; s < SLOTS_PER_BEAT; s++) begin
      if (w_slot_has_data[s]) begin
        tail_tmp = bump_slot_ptr(tail_tmp, 1);
      end
    end
    w_data_tail_d  = tail_tmp;
    w_data_count_d = w_data_count_d + w_slots_in_beat;
  end
  if (x_slot_pop) begin
    x_data_head_d  = bump_slot_ptr(x_data_head_d, 1);
    x_data_count_d = x_data_count_d - 1'b1;
  end
  if (w_slot_pop) begin
    w_data_head_d  = bump_slot_ptr(w_data_head_d, 1);
    w_data_count_d = w_data_count_d - 1'b1;
  end

  // Exponent FIFO next state
  x_exp_head_d  = x_exp_head_q;
  x_exp_tail_d  = x_exp_tail_q;
  x_exp_count_d = x_exp_count_q;
  w_exp_head_d  = w_exp_head_q;
  w_exp_tail_d  = w_exp_tail_q;
  w_exp_count_d = w_exp_count_q;

  if (x_exp_accept) begin
    x_exp_tail_d  = bump_xexp_ptr(x_exp_tail_d, 1);
    x_exp_count_d = x_exp_count_d + 1'b1;
  end
  if (w_exp_accept) begin
    w_exp_tail_d  = bump_wexp_ptr(w_exp_tail_d, 1);
    w_exp_count_d = w_exp_count_d + 1'b1;
  end
  if (x_slot_pop) begin
    x_exp_head_d  = bump_xexp_ptr(x_exp_head_d, 1);
    x_exp_count_d = x_exp_count_d - 1'b1;
  end
  if (w_slot_pop) begin
    w_exp_head_d  = bump_wexp_ptr(w_exp_head_d, 1);
    w_exp_count_d = w_exp_count_d - 1'b1;
  end
end

// Sequential logic
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    x_data_head_q <= '0;
    x_data_tail_q <= '0;
    x_data_count_q <= '0;
    w_data_head_q <= '0;
    w_data_tail_q <= '0;
    w_data_count_q <= '0;
    x_exp_head_q <= '0;
    x_exp_tail_q <= '0;
    x_exp_count_q <= '0;
    w_exp_head_q <= '0;
    w_exp_tail_q <= '0;
    w_exp_count_q <= '0;
  end else if (clear_i) begin
    x_data_head_q <= '0;
    x_data_tail_q <= '0;
    x_data_count_q <= '0;
    w_data_head_q <= '0;
    w_data_tail_q <= '0;
    w_data_count_q <= '0;
    x_exp_head_q <= '0;
    x_exp_tail_q <= '0;
    x_exp_count_q <= '0;
    w_exp_head_q <= '0;
    w_exp_tail_q <= '0;
    w_exp_count_q <= '0;
  end else begin
    x_data_head_q <= x_data_head_d;
    x_data_tail_q <= x_data_tail_d;
    x_data_count_q <= x_data_count_d;
    w_data_head_q <= w_data_head_d;
    w_data_tail_q <= w_data_tail_d;
    w_data_count_q <= w_data_count_d;
    x_exp_head_q <= x_exp_head_d;
    x_exp_tail_q <= x_exp_tail_d;
    x_exp_count_q <= x_exp_count_d;
    w_exp_head_q <= w_exp_head_d;
    w_exp_tail_q <= w_exp_tail_d;
    w_exp_count_q <= w_exp_count_d;
  end
end

// Data memory writes
always_ff @(posedge clk_i) begin
    // Mantissa writes (use tail prior to update)
    if (x_data_accept) begin
      automatic logic [SLOT_PTR_W-1:0] tail_tmp;
      tail_tmp = x_data_tail_q;
      for (int s = 0; s < SLOTS_PER_BEAT; s++) begin
        if (x_slot_has_data[s]) begin
          x_data_mem[tail_tmp] <= x_unpacked[s];
          tail_tmp = bump_slot_ptr(tail_tmp, 1);
        end
      end
    end
    if (w_data_accept) begin
      automatic logic [SLOT_PTR_W-1:0] tail_tmp;
      tail_tmp = w_data_tail_q;
      for (int s = 0; s < SLOTS_PER_BEAT; s++) begin
        if (w_slot_has_data[s]) begin
          w_data_mem[tail_tmp] <= w_unpacked[s];
          tail_tmp = bump_slot_ptr(tail_tmp, 1);
        end
      end
    end

    // Exponent writes
    if (x_exp_accept) begin
      x_exp_mem[x_exp_tail_q] <= x_exp_data_i;
    end
    if (w_exp_accept) begin
      w_exp_mem[w_exp_tail_q] <= w_exp_data_i;
    end
  end

endmodule : redmule_mx_slot_buffer
