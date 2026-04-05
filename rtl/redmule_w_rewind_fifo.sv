// Rewindable FIFO wrapper for W buffer data path.
// Wraps hwpe_stream_fifo with a replay buffer that captures entries after
// each mark_i pulse.  On rewind_i, the module enters replay mode and
// re-emits all captured entries before returning to the inner FIFO.
//
// Usage (M-tile priming):
//   1. mark_i  – reset replay capture (start of M-tile transition)
//   2. Entries pass through and are captured in replay buffer
//   3. rewind_i – enter replay mode (after SCM is fully refreshed)
//   4. Captured entries are replayed (variable count)
//   5. Subsequent pops come from inner FIFO (normal mode)

module redmule_w_rewind_fifo
  import hwpe_stream_package::*;
#(
  parameter int unsigned DATA_WIDTH   = 32,
  parameter int unsigned FIFO_DEPTH   = 16,
  parameter int unsigned REPLAY_DEPTH = 64
)(
  input  logic          clk_i,
  input  logic          rst_ni,
  input  logic          clear_i,

  input  logic          mark_i,     // reset replay capture pointer, enable capture
  input  logic          rewind_i,   // enter replay mode

  output flags_fifo_t   flags_o,
  output logic          replaying_o, // high during REPLAYING state

  hwpe_stream_intf_stream.sink   push_i,
  hwpe_stream_intf_stream.source pop_o
);

  localparam int unsigned RADDR_W = $clog2(REPLAY_DEPTH);
  localparam int unsigned WORD_W  = DATA_WIDTH + DATA_WIDTH/8;  // data + strb

  // ---- Inner FIFO ----
  hwpe_stream_intf_stream #(.DATA_WIDTH(DATA_WIDTH)) fifo_pop (.clk(clk_i));
  flags_fifo_t fifo_flags;

  hwpe_stream_fifo #(
    .DATA_WIDTH ( DATA_WIDTH ),
    .FIFO_DEPTH ( FIFO_DEPTH )
  ) i_inner_fifo (
    .clk_i   ( clk_i      ),
    .rst_ni  ( rst_ni      ),
    .clear_i ( clear_i     ),
    .flags_o ( fifo_flags  ),
    .push_i  ( push_i      ),
    .pop_o   ( fifo_pop    )
  );

  // ---- Replay buffer ----
  logic [WORD_W-1:0] replay_mem [REPLAY_DEPTH];
  logic [RADDR_W-1:0] replay_wr_ptr_q;
  logic [RADDR_W-1:0] replay_rd_ptr_q;
  logic                capture_en_q;     // 1 = capturing into replay_mem

  // Track how many entries were actually captured (for variable-length replay)
  logic [RADDR_W-1:0] capture_count_q;   // number of captured entries - 1

  // ---- FSM ----
  typedef enum logic [1:0] { NORMAL, REPLAYING, DRAINING } state_e;
  state_e state_q, state_d;

  // ---- Replay write (capture) ----
  logic replay_wr_en;
  logic capture_full;

  assign capture_full = capture_en_q && (replay_wr_ptr_q == RADDR_W'(REPLAY_DEPTH - 1));

  // Capture when: in NORMAL mode, capture enabled, and an entry is being popped
  assign replay_wr_en = (state_q == NORMAL) && capture_en_q &&
                         fifo_pop.valid && fifo_pop.ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      replay_wr_ptr_q <= '0;
      capture_en_q    <= 1'b0;
    end else if (clear_i) begin
      replay_wr_ptr_q <= '0;
      capture_en_q    <= 1'b0;
    end else if (mark_i) begin
      replay_wr_ptr_q <= '0;
      capture_en_q    <= 1'b1;
    end else if (replay_wr_en) begin
      if (capture_full) begin
        capture_en_q <= 1'b0;  // stop after REPLAY_DEPTH entries
      end
      replay_wr_ptr_q <= replay_wr_ptr_q + 1;
    end
  end

  // Replay memory write
  always_ff @(posedge clk_i) begin
    if (replay_wr_en) begin
      replay_mem[replay_wr_ptr_q] <= {fifo_pop.strb, fifo_pop.data};
    end
  end

  // ---- Capture count: save the number of captured entries on rewind ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      capture_count_q <= '0;
    end else if (clear_i) begin
      capture_count_q <= '0;
    end else if (rewind_i) begin
      // Save count-1: replay_wr_ptr_q points to NEXT write position,
      // so the last valid entry is at replay_wr_ptr_q - 1.
      // If capture still active, use current wr_ptr - 1.
      // If capture done (en=0), wr_ptr already wrapped past last entry.
      capture_count_q <= replay_wr_ptr_q - 1;
    end
  end

  // ---- Replay read ----
  logic replay_rd_en;
  logic replay_last;

  // Variable-length replay: stop at the actual captured count
  assign replay_last = (replay_rd_ptr_q == capture_count_q);
  assign replay_rd_en = (state_q == REPLAYING) && pop_o.ready;

  // ---- Drain counter: skip capture_count+1 entries from inner FIFO after replay ----
  logic [RADDR_W-1:0] drain_cnt_q;
  logic drain_last;
  assign drain_last = (drain_cnt_q == capture_count_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      replay_rd_ptr_q <= '0;
    end else if (clear_i || rewind_i) begin
      replay_rd_ptr_q <= '0;
    end else if (replay_rd_en) begin
      replay_rd_ptr_q <= replay_rd_ptr_q + 1;
    end
  end

  // ---- Drain counter ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      drain_cnt_q <= '0;
    end else if (clear_i) begin
      drain_cnt_q <= '0;
    end else if (state_q == REPLAYING && state_d == DRAINING) begin
      drain_cnt_q <= '0;
    end else if (state_q == DRAINING && fifo_pop.valid && fifo_pop.ready) begin
      drain_cnt_q <= drain_cnt_q + 1;
    end
  end

  // ---- FSM transitions ----
  // Rewind transition is registered: rewind_i sets a pending flag,
  // state transitions on the next cycle.  This avoids mid-cycle data
  // changes on pop_o (HWPE stream protocol requires stable data while
  // valid is high and ready is low).
  logic rewind_pending_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      rewind_pending_q <= 1'b0;
    else if (clear_i)
      rewind_pending_q <= 1'b0;
    else if (rewind_i)
      rewind_pending_q <= 1'b1;
    else
      rewind_pending_q <= 1'b0;
  end

  always_comb begin
    state_d = state_q;
    case (state_q)
      NORMAL: begin
        if (rewind_pending_q) state_d = REPLAYING;
      end
      REPLAYING: begin
        if (replay_last && replay_rd_en) state_d = DRAINING;
      end
      DRAINING: begin
        // Skip capture_count+1 entries from inner FIFO (already replayed)
        if (drain_last && fifo_pop.valid) state_d = NORMAL;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      state_q <= NORMAL;
    else if (clear_i)
      state_q <= NORMAL;
    else
      state_q <= state_d;
  end

  // ---- Replaying output ----
  assign replaying_o = (state_q == REPLAYING);

  // ---- Output mux ----
  logic [DATA_WIDTH-1:0]   replay_data;
  logic [DATA_WIDTH/8-1:0] replay_strb;

  assign {replay_strb, replay_data} = replay_mem[replay_rd_ptr_q];

  always_comb begin
    if (state_q == REPLAYING) begin
      pop_o.valid = 1'b1;
      pop_o.data  = replay_data;
      pop_o.strb  = replay_strb;
      // Don't pop inner FIFO during replay
      fifo_pop.ready = 1'b0;
    end else if (state_q == DRAINING) begin
      // Discard entries from inner FIFO (already provided by replay).
      // Output invalid to scheduler — scheduler stalls on check_w_valid.
      pop_o.valid    = 1'b0;
      pop_o.data     = '0;
      pop_o.strb     = '0;
      // Pop inner FIFO to drain duplicates
      fifo_pop.ready = fifo_pop.valid;
    end else if (rewind_pending_q) begin
      // Transition cycle: deassert valid to avoid data glitch
      pop_o.valid    = 1'b0;
      pop_o.data     = '0;
      pop_o.strb     = '0;
      fifo_pop.ready = 1'b0;
    end else begin
      pop_o.valid    = fifo_pop.valid;
      pop_o.data     = fifo_pop.data;
      pop_o.strb     = fifo_pop.strb;
      fifo_pop.ready = pop_o.ready;
    end
  end

  // ---- Flags: pass through inner FIFO flags ----
  // During replay, report not-empty (replay has data)
  assign flags_o.empty        = (state_q == REPLAYING) ? 1'b0 : fifo_flags.empty;
  assign flags_o.full         = fifo_flags.full;
  assign flags_o.almost_empty = (state_q == REPLAYING) ? 1'b0 : fifo_flags.almost_empty;
  assign flags_o.almost_full  = fifo_flags.almost_full;
  assign flags_o.push_pointer = fifo_flags.push_pointer;
  assign flags_o.pop_pointer  = fifo_flags.pop_pointer;

`ifndef SYNTHESIS
  bit dbg_rwfifo;
  initial dbg_rwfifo = $test$plusargs("MX_DEBUG_DUMP");
  always @(posedge clk_i) begin
    if (dbg_rwfifo) begin
      if (mark_i)
        $display("[DBG][RWFIFO] t=%0t MARK  wr_ptr=%0d cap_en=%0d state=%s",
                 $time, replay_wr_ptr_q, capture_en_q,
                 state_q == NORMAL ? "NORMAL" : "REPLAYING");
      if (rewind_i)
        $display("[DBG][RWFIFO] t=%0t REWIND_REQ  cap_count=%0d wr_ptr=%0d state=%s",
                 $time, replay_wr_ptr_q, replay_wr_ptr_q,
                 state_q == NORMAL ? "NORMAL" : "REPLAYING");
      if (rewind_pending_q && state_q == NORMAL)
        $display("[DBG][RWFIFO] t=%0t REWIND->REPLAYING  cap_count=%0d",
                 $time, capture_count_q);
      if (state_q == REPLAYING && state_d == NORMAL)
        $display("[DBG][RWFIFO] t=%0t REPLAY_DONE->NORMAL  rd_ptr=%0d/%0d",
                 $time, replay_rd_ptr_q, capture_count_q);
      if (state_q == REPLAYING && replay_rd_en && (replay_rd_ptr_q[4:0] == 0 || replay_last))
        $display("[DBG][RWFIFO] t=%0t REPLAY_POP rd_ptr=%0d/%0d  ready=%b",
                 $time, replay_rd_ptr_q, capture_count_q, pop_o.ready);
      if (replay_wr_en && (replay_wr_ptr_q == 0 || capture_full))
        $display("[DBG][RWFIFO] t=%0t CAPTURE wr_ptr=%0d/%0d  cap_full=%b",
                 $time, replay_wr_ptr_q, REPLAY_DEPTH-1, capture_full);
    end
  end
`endif

endmodule : redmule_w_rewind_fifo
