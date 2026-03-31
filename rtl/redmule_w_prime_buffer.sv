// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// W Prime Buffer: captures DEPTH decoded FIFO entries after an M-tile
// boundary and replays them so the W buffer SCM is fully loaded before
// the engine starts computing.  This eliminates stale-data errors caused
// by the dual-decoder's faster W pipeline.
//
// States:
//   IDLE       – transparent pass-through
//   CAPTURING  – passes FIFO data through AND saves copies (DEPTH entries)
//   REPLAYING  – provides saved entries; FIFO does not pop

module redmule_w_prime_buffer
  import redmule_pkg::*;
#(
  parameter int unsigned DW    = DATAW,
  parameter int unsigned DEPTH = ARRAY_HEIGHT   // 32 entries = one full SCM fill
)(
  input  logic           clk_i,
  input  logic           rst_ni,
  input  logic           clear_i,

  // Control
  input  logic           prime_start_i,    // pulse: begin capture
  output logic           capturing_o,      // high in CAPTURING state
  output logic           replaying_o,      // high in REPLAYING state

  // Upstream (from decoded FIFO)
  input  logic [DW-1:0]  fifo_data_i,
  input  logic           fifo_valid_i,
  output logic           fifo_ready_o,

  // Downstream (to W buffer)
  output logic [DW-1:0]  data_o,
  output logic           valid_o,
  input  logic           ready_i
);

  typedef enum logic [1:0] {
    IDLE,
    CAPTURING,
    REPLAYING
  } state_e;

  state_e state_q, state_d;

  logic [DW-1:0] buffer [0:DEPTH-1];
  logic [$clog2(DEPTH)-1:0] cnt_q, cnt_d;

  // State register
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      cnt_q   <= '0;
    end else if (clear_i) begin
      state_q <= IDLE;
      cnt_q   <= '0;
    end else begin
      state_q <= state_d;
      cnt_q   <= cnt_d;
    end
  end

  // Buffer write during CAPTURING
  always_ff @(posedge clk_i) begin
    if (state_q == CAPTURING && fifo_valid_i && ready_i) begin
      buffer[cnt_q] <= fifo_data_i;
    end
  end

  // Next-state logic
  always_comb begin
    state_d = state_q;
    cnt_d   = cnt_q;

    case (state_q)
      IDLE: begin
        if (prime_start_i) begin
          state_d = CAPTURING;
          cnt_d   = '0;
        end
      end

      CAPTURING: begin
        if (fifo_valid_i && ready_i) begin
          if (cnt_q == DEPTH - 1) begin
            state_d = REPLAYING;
            cnt_d   = '0;
          end else begin
            cnt_d = cnt_q + 1;
          end
        end
      end

      REPLAYING: begin
        if (ready_i) begin
          if (cnt_q == DEPTH - 1) begin
            state_d = IDLE;
            cnt_d   = '0;
          end else begin
            cnt_d = cnt_q + 1;
          end
        end
      end

      default: state_d = IDLE;
    endcase
  end

  // Output muxing
  always_comb begin
    case (state_q)
      IDLE: begin
        data_o       = fifo_data_i;
        valid_o      = fifo_valid_i;
        fifo_ready_o = ready_i && !prime_start_i;  // Don't pop FIFO on the prime_start cycle
      end

      CAPTURING: begin
        data_o       = fifo_data_i;
        valid_o      = fifo_valid_i;
        fifo_ready_o = ready_i;
      end

      REPLAYING: begin
        data_o       = buffer[cnt_q];
        valid_o      = 1'b1;
        fifo_ready_o = 1'b0;       // Don't pop FIFO during replay
      end

      default: begin
        data_o       = fifo_data_i;
        valid_o      = fifo_valid_i;
        fifo_ready_o = ready_i;
      end
    endcase
  end

  assign capturing_o = (state_q == CAPTURING);
  assign replaying_o = (state_q == REPLAYING);

`ifndef SYNTHESIS
  bit dbg_prime;
  initial dbg_prime = $test$plusargs("MX_DEBUG_DUMP");

  always @(posedge clk_i) begin
    if (dbg_prime) begin
      if (state_d != state_q)
        $display("[DBG][PRIME] t=%0t STATE %0d -> %0d (start=%0b ready=%0b valid=%0b cnt=%0d)",
                 $time, state_q, state_d, prime_start_i, ready_i, valid_o, cnt_q);
      if (prime_start_i && state_q == IDLE)
        $display("[DBG][PRIME] t=%0t START → CAPTURING", $time);
      if (state_q == CAPTURING && fifo_valid_i && ready_i)
        $display("[DBG][PRIME] t=%0t CAPTURE[%0d] state=%0d data[0:1]=0x%04h 0x%04h",
                 $time, cnt_q, state_q, fifo_data_i[15:0], fifo_data_i[31:16]);
      if (state_q == REPLAYING && ready_i)
        $display("[DBG][PRIME] t=%0t REPLAY[%0d] data[0:1]=0x%04h 0x%04h",
                 $time, cnt_q, buffer[cnt_q][15:0], buffer[cnt_q][31:16]);
      if (state_q == CAPTURING && fifo_valid_i && ready_i &&
          cnt_q == DEPTH - 1)
        $display("[DBG][PRIME] t=%0t CAPTURE done → REPLAYING", $time);
      if (state_q == REPLAYING && ready_i &&
          cnt_q == DEPTH - 1)
        $display("[DBG][PRIME] t=%0t REPLAY done → IDLE", $time);
    end
  end
`endif

endmodule : redmule_w_prime_buffer
