// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Exponent prefetch buffer: Unpacks individual exponents from compact 512-bit beats
// and stores them. Output is direct register access (NO streaming protocol).
//
// Purpose: Completely decouple exponent fetch from data processing by buffering
// all exponents upfront. No backpressure during computation.
//
// Input format: Exponents packed tightly in 512-bit beats (no padding)
//   X: 64 exponents per beat (8 bits each)
//   W: 16 exponent vectors per beat (32 bits each)

module redmule_exp_buffer #(
  parameter int unsigned EXP_WIDTH = 8,       // Width of each exponent (8 for X, 32 for W)
  parameter int unsigned BUFFER_DEPTH = 512,  // Number of exponents to buffer
  parameter int unsigned BEAT_WIDTH = 512     // Width of input beat from streamer
)(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,

  // Input: streaming interface from streamer (compact exponents in 512-bit beats)
  hwpe_stream_intf_stream.sink stream_i,

  // Output: direct register access (NO streaming protocol)
  output logic [EXP_WIDTH-1:0] data_o,
  output logic                  valid_o,
  input  logic                  consume_i
);

  localparam int unsigned PTR_WIDTH = $clog2(BUFFER_DEPTH);
  localparam int unsigned EXPS_PER_BEAT = BEAT_WIDTH / EXP_WIDTH;

  // Circular buffer storage for individual exponents
  logic [EXP_WIDTH-1:0] buffer [BUFFER_DEPTH-1:0];
  logic [PTR_WIDTH-1:0] write_ptr_q, read_ptr_q;
  logic [PTR_WIDTH:0]   occupancy_q;  // Extra bit to distinguish full/empty

  // Buffer status
  logic buffer_full, buffer_empty;
  assign buffer_full  = (occupancy_q >= (BUFFER_DEPTH - EXPS_PER_BEAT));
  assign buffer_empty = (occupancy_q == 0);

  // Output: provide current exponent at read pointer (simple direct access)
  assign data_o  = buffer[read_ptr_q];
  assign valid_o = !buffer_empty;

  // Write and read logic
  logic [PTR_WIDTH-1:0] write_ptr_d, read_ptr_d;
  logic [PTR_WIDTH:0]   occupancy_d;

  // Input acceptance
  logic input_accept;
  assign input_accept = stream_i.valid && stream_i.ready;

  always_comb begin
    write_ptr_d = write_ptr_q;
    read_ptr_d  = read_ptr_q;
    occupancy_d = occupancy_q;

    // Update pointers
    if (input_accept) begin
      write_ptr_d = (write_ptr_q + EXPS_PER_BEAT >= BUFFER_DEPTH) ?
                    (write_ptr_q + EXPS_PER_BEAT - BUFFER_DEPTH) :
                    (write_ptr_q + EXPS_PER_BEAT);
    end

    if (consume_i && !buffer_empty) begin
      read_ptr_d  = (read_ptr_q + 1 >= BUFFER_DEPTH) ? 0 : (read_ptr_q + 1);
    end

    // Calculate occupancy based on simultaneous operations
    if (input_accept && (consume_i && !buffer_empty)) begin
      // Both write and read: net change is +EXPS_PER_BEAT -1
      occupancy_d = occupancy_q + EXPS_PER_BEAT - 1;
    end else if (input_accept) begin
      // Only write
      occupancy_d = occupancy_q + EXPS_PER_BEAT;
    end else if (consume_i && !buffer_empty) begin
      // Only read
      occupancy_d = occupancy_q - 1;
    end
  end

  // Ready signal: depends only on registered occupancy to prevent combinational glitches
  // The buffer can accept when current occupancy plus one beat fits within capacity
  // Use buffer_full signal which already has proper margin (BUFFER_DEPTH - EXPS_PER_BEAT)
  assign stream_i.ready = !buffer_full;

  // Sequential logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_ptr_q <= '0;
      read_ptr_q  <= '0;
      occupancy_q <= '0;
    end else if (clear_i) begin
      write_ptr_q <= '0;
      read_ptr_q  <= '0;
      occupancy_q <= '0;
    end else begin
      write_ptr_q <= write_ptr_d;
      read_ptr_q  <= read_ptr_d;
      occupancy_q <= occupancy_d;

      // Write all exponents from the beat into buffer
      if (input_accept) begin
        for (int i = 0; i < EXPS_PER_BEAT; i++) begin
          automatic int unsigned wr_idx = (write_ptr_q + i) % BUFFER_DEPTH;
          buffer[wr_idx] <= stream_i.data[i*EXP_WIDTH +: EXP_WIDTH];
        end
      end
    end
  end

endmodule : redmule_exp_buffer
