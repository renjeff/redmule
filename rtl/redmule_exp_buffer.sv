// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Exponent prefetch buffer: Unpacks individual exponents from compact beats
// and stores them. Output is direct register access (NO streaming protocol).
//
// Purpose: Completely decouple exponent fetch from data processing by buffering
// all exponents upfront. No backpressure during computation.
//
// Mark/Rewind: Supports replaying exponents for multi-K-tile and multi-M-tile.
//   mark_i: save current read pointer (call at start of each replay group)
//   rewind_i: restore read pointer to saved mark (call to replay same exponents)
//
// Input format: Exponents packed tightly in beats (no padding)
//   X: 128 exponents per 1024-bit beat (8 bits each)
//   W: 32 exponent vectors per 1024-bit beat (32 bits each)

module redmule_exp_buffer #(
  parameter int unsigned EXP_WIDTH = 8,       // Width of each exponent (8 for X, 32 for W)
  parameter int unsigned BUFFER_DEPTH = 512,  // Number of exponents to buffer
  parameter int unsigned BEAT_WIDTH = 512     // Width of input beat from streamer
)(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,

  // Input: streaming interface from streamer (compact exponents in beats)
  hwpe_stream_intf_stream.sink stream_i,

  // Output: direct register access (NO streaming protocol)
  output logic [EXP_WIDTH-1:0] data_o,
  output logic                  valid_o,
  input  logic                  consume_i,

  // Mark/Rewind for multi-tile replay
  input  logic                  mark_i,    // Save current read_ptr
  input  logic                  rewind_i   // Restore read_ptr to saved mark
);

  localparam int unsigned PTR_WIDTH = $clog2(BUFFER_DEPTH);
  localparam int unsigned EXPS_PER_BEAT = BEAT_WIDTH / EXP_WIDTH;

  // Circular buffer storage for individual exponents
  logic [EXP_WIDTH-1:0] buffer [BUFFER_DEPTH-1:0];
  logic [PTR_WIDTH-1:0] write_ptr_q, read_ptr_q;
  logic [PTR_WIDTH:0]   occupancy_q;  // Extra bit to distinguish full/empty

  // Mark register for replay
  logic [PTR_WIDTH-1:0] mark_ptr_q;
  logic [PTR_WIDTH:0]   mark_occupancy_q;

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

    // Rewind takes priority over normal consume
    if (rewind_i) begin
      read_ptr_d  = mark_ptr_q;
      // Occupancy increases by the number of exponents we're "un-consuming"
      // New occupancy = write_ptr - mark_ptr (mod BUFFER_DEPTH)
      if (write_ptr_q >= mark_ptr_q)
        occupancy_d = write_ptr_q - mark_ptr_q;
      else
        occupancy_d = BUFFER_DEPTH - mark_ptr_q + write_ptr_q;

      // If also accepting input during rewind, add those
      if (input_accept) begin
        write_ptr_d = (write_ptr_q + EXPS_PER_BEAT >= BUFFER_DEPTH) ?
                      (write_ptr_q + EXPS_PER_BEAT - BUFFER_DEPTH) :
                      (write_ptr_q + EXPS_PER_BEAT);
        occupancy_d = occupancy_d + EXPS_PER_BEAT;
      end
    end else begin
      // Normal operation
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
        occupancy_d = occupancy_q + EXPS_PER_BEAT - 1;
      end else if (input_accept) begin
        occupancy_d = occupancy_q + EXPS_PER_BEAT;
      end else if (consume_i && !buffer_empty) begin
        occupancy_d = occupancy_q - 1;
      end
    end
  end

  // Ready signal: depends only on registered occupancy to prevent combinational glitches
  assign stream_i.ready = !buffer_full;

  // Sequential logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_ptr_q    <= '0;
      read_ptr_q     <= '0;
      occupancy_q    <= '0;
      mark_ptr_q     <= '0;
      mark_occupancy_q <= '0;
    end else if (clear_i) begin
      write_ptr_q    <= '0;
      read_ptr_q     <= '0;
      occupancy_q    <= '0;
      mark_ptr_q     <= '0;
      mark_occupancy_q <= '0;
    end else begin
      write_ptr_q <= write_ptr_d;
      read_ptr_q  <= read_ptr_d;
      occupancy_q <= occupancy_d;

      // Save mark position
      if (mark_i) begin
        mark_ptr_q       <= read_ptr_q;
        mark_occupancy_q <= occupancy_q;
`ifndef SYNTHESIS
        $display("[DBG][EXPBUF][%m] MARK at t=%0t  read_ptr=%0d  write_ptr=%0d  occ=%0d",
                 $time, read_ptr_q, write_ptr_q, occupancy_q);
`endif
      end
      if (rewind_i) begin
`ifndef SYNTHESIS
        $display("[DBG][EXPBUF][%m] REWIND at t=%0t  read_ptr %0d -> mark %0d  occ %0d -> %0d",
                 $time, read_ptr_q, mark_ptr_q, occupancy_q, occupancy_d);
`endif
      end

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
