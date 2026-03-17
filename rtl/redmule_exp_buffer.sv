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
// Segment gating: When segment_size_i != 0, limits consumption to at most
//   segment_size_i exponents per segment. Rewind and mark both reset the
//   segment counter. This prevents the decoder from reading ahead into
//   future M-tile exponents.
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

  // Total number of valid exponents across all beats.  When the last beat
  // has fewer valid exponents than EXPS_PER_BEAT (e.g. 64 valid in a
  // 128-slot beat), this prevents junk padding from being stored.
  // Set to 0 to disable the cap (store all EXPS_PER_BEAT per beat).
  input  logic [15:0]           total_count_i,

  // Segment size: max exponents consumed per segment (between rewind/mark).
  // Prevents decoder from reading ahead into future M-tile exponents.
  // Set to 0 to disable segment gating.
  input  logic [15:0]           segment_size_i,

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
  localparam int unsigned EPB_WIDTH = $clog2(EXPS_PER_BEAT + 1);

  // Circular buffer storage for individual exponents
  logic [EXP_WIDTH-1:0] buffer [BUFFER_DEPTH-1:0];
  logic [PTR_WIDTH-1:0] write_ptr_q, read_ptr_q;
  logic [PTR_WIDTH:0]   occupancy_q;  // Extra bit to distinguish full/empty

  // Track total exponents written to cap at total_count_i
  logic [15:0] total_written_q;
  logic [EPB_WIDTH-1:0] valid_in_beat;
  logic cap_active;

  assign cap_active = (total_count_i != '0);

  always_comb begin
    if (!cap_active) begin
      valid_in_beat = EPB_WIDTH'(EXPS_PER_BEAT);
    end else begin
      automatic logic [16:0] remaining;
      remaining = {1'b0, total_count_i} - {1'b0, total_written_q};
      if (remaining[16] || remaining == '0) begin
        // total_count <= total_written: nothing left to write
        valid_in_beat = '0;
      end else if (remaining >= EXPS_PER_BEAT) begin
        valid_in_beat = EPB_WIDTH'(EXPS_PER_BEAT);
      end else begin
        valid_in_beat = remaining[EPB_WIDTH-1:0];
      end
    end
  end

  // Mark register for replay
  logic [PTR_WIDTH-1:0] mark_ptr_q;
  logic [PTR_WIDTH:0]   mark_occupancy_q;

  // Segment gating: track consumed exponents within current segment
  logic [15:0] seg_consumed_q;
  logic        seg_gate_active;
  logic        seg_exhausted;

  assign seg_gate_active = (segment_size_i != '0);
  assign seg_exhausted   = seg_gate_active && (seg_consumed_q >= segment_size_i);

  // Buffer status
  logic buffer_full, buffer_empty;
  assign buffer_full  = (occupancy_q >= (BUFFER_DEPTH - EXPS_PER_BEAT));
  assign buffer_empty = (occupancy_q == 0);

  // Output: provide current exponent at read pointer (simple direct access)
  // Gated by segment exhaustion: once segment_size consumed, output invalid
  assign data_o  = buffer[read_ptr_q];
  assign valid_o = !buffer_empty && !seg_exhausted;

  // Write and read logic
  logic [PTR_WIDTH-1:0] write_ptr_d, read_ptr_d;
  logic [PTR_WIDTH:0]   occupancy_d;

  // Effective consume: only if valid_o is high
  logic effective_consume;
  assign effective_consume = consume_i && valid_o;

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
      if (input_accept && valid_in_beat != '0) begin
        write_ptr_d = (write_ptr_q + valid_in_beat >= BUFFER_DEPTH) ?
                      (write_ptr_q + valid_in_beat - BUFFER_DEPTH) :
                      (write_ptr_q + valid_in_beat);
        occupancy_d = occupancy_d + valid_in_beat;
      end
    end else begin
      // Normal operation
      if (input_accept && valid_in_beat != '0) begin
        write_ptr_d = (write_ptr_q + valid_in_beat >= BUFFER_DEPTH) ?
                      (write_ptr_q + valid_in_beat - BUFFER_DEPTH) :
                      (write_ptr_q + valid_in_beat);
      end

      if (effective_consume) begin
        read_ptr_d  = (read_ptr_q + 1 >= BUFFER_DEPTH) ? 0 : (read_ptr_q + 1);
      end

      // Calculate occupancy based on simultaneous operations
      if (input_accept && valid_in_beat != '0 && effective_consume) begin
        occupancy_d = occupancy_q + valid_in_beat - 1;
      end else if (input_accept && valid_in_beat != '0) begin
        occupancy_d = occupancy_q + valid_in_beat;
      end else if (effective_consume) begin
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
      total_written_q <= '0;
      seg_consumed_q <= '0;
    end else if (clear_i) begin
      write_ptr_q    <= '0;
      read_ptr_q     <= '0;
      occupancy_q    <= '0;
      mark_ptr_q     <= '0;
      mark_occupancy_q <= '0;
      total_written_q <= '0;
      seg_consumed_q <= '0;
    end else begin
      write_ptr_q <= write_ptr_d;
      read_ptr_q  <= read_ptr_d;
      occupancy_q <= occupancy_d;

      // Segment counter: reset on rewind or mark, increment on consume
      if (rewind_i || mark_i) begin
        seg_consumed_q <= '0;
      end else if (effective_consume) begin
        seg_consumed_q <= seg_consumed_q + 1;
      end

      // Save mark position
      if (mark_i) begin
        mark_ptr_q       <= read_ptr_q;
        mark_occupancy_q <= occupancy_q;
`ifndef SYNTHESIS
        $display("[DBG][EXPBUF][%m] MARK at t=%0t  read_ptr=%0d  write_ptr=%0d  occ=%0d  total_written=%0d  total_count=%0d  seg_consumed=%0d",
                 $time, read_ptr_q, write_ptr_q, occupancy_q, total_written_q, total_count_i, seg_consumed_q);
`endif
      end
      if (rewind_i) begin
`ifndef SYNTHESIS
        $display("[DBG][EXPBUF][%m] REWIND at t=%0t  read_ptr %0d -> mark %0d  occ %0d -> %0d  seg_consumed %0d -> 0",
                 $time, read_ptr_q, mark_ptr_q, occupancy_q, occupancy_d, seg_consumed_q);
`endif
      end

      // Write only valid exponents from the beat into buffer (skip padding)
      if (input_accept && valid_in_beat != '0) begin
        for (int i = 0; i < EXPS_PER_BEAT; i++) begin
          if (i < valid_in_beat) begin
            automatic int unsigned wr_idx = (write_ptr_q + i) % BUFFER_DEPTH;
            buffer[wr_idx] <= stream_i.data[i*EXP_WIDTH +: EXP_WIDTH];
          end
        end
        total_written_q <= total_written_q + valid_in_beat;
      end
    end
  end

endmodule : redmule_exp_buffer
