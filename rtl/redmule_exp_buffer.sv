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

  // Registered ready signal to avoid protocol violations
  // Ready can only change when transaction completes or valid is deasserted
  logic ready_q, ready_d;
  logic output_hold_q, output_hold_d;
  logic [BEAT_WIDTH-1:0] data_hold_q, data_hold_d;
  assign stream_i.ready = ready_q;

  // Output: provide current exponent at read pointer
  assign data_o  = output_hold_q ? data_hold_q : buffer[read_ptr_q];
  assign valid_o = output_hold_q | !buffer_empty;

  // Input acceptance
  logic input_accept;
  assign input_accept = stream_i.valid && ready_q;

  // Write and read logic
  logic [PTR_WIDTH-1:0] write_ptr_d, read_ptr_d;
  logic [PTR_WIDTH:0]   occupancy_d;

  always_comb begin
    write_ptr_d = write_ptr_q;
    read_ptr_d  = read_ptr_q;
    occupancy_d = occupancy_q;
    ready_d     = ready_q;
    output_hold_d = output_hold_q;
    data_hold_d   = data_hold_q;

    // Update pointers
    if (input_accept) begin
      write_ptr_d = (write_ptr_q + EXPS_PER_BEAT >= BUFFER_DEPTH) ?
                    (write_ptr_q + EXPS_PER_BEAT - BUFFER_DEPTH) :
                    (write_ptr_q + EXPS_PER_BEAT);
    end

    if (consume_i && !buffer_empty && !output_hold_q) begin
      read_ptr_d  = (read_ptr_q + 1 >= BUFFER_DEPTH) ? 0 : (read_ptr_q + 1);
    end

    if (!buffer_empty && !consume_i) begin
      output_hold_d = 1'b1;
      data_hold_d   = buffer[read_ptr_q];
    end else if (consume_i) begin
      output_hold_d = 1'b0;
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

    // Ready signal update: always update based on current/next occupancy
    // This must be done every cycle to avoid deadlock when waiting state gains space
    ready_d = (occupancy_d < (BUFFER_DEPTH - EXPS_PER_BEAT));
  end

  // Sequential logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_ptr_q <= '0;
      read_ptr_q  <= '0;
      occupancy_q <= '0;
      ready_q     <= 1'b1;  // Start ready (buffer empty)
    end else if (clear_i) begin
      write_ptr_q <= '0;
      read_ptr_q  <= '0;
      occupancy_q <= '0;
      ready_q     <= 1'b1;  // Ready after clear
    end else begin
      write_ptr_q <= write_ptr_d;
      read_ptr_q  <= read_ptr_d;
      occupancy_q <= occupancy_d;
      ready_q     <= ready_d;
      output_hold_q <= output_hold_d;
      data_hold_q   <= data_hold_d;

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
