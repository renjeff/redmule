// MX Beat Unpack Module
// Expands packed MX-decoded beats into legacy one-row-per-beat semantics.

`include "hci_helpers.svh"

module redmule_mx_beat_unpack
  import redmule_pkg::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned DATAW_ALIGN  = 512,
  parameter int unsigned BITW         = 16,
  parameter int unsigned MX_NUM_LANES = 32
)(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  input  logic mx_enable_i,

  hwpe_stream_intf_stream.sink   in_i,
  hwpe_stream_intf_stream.source out_o,

  output logic                   pending_o
);

localparam int unsigned CHUNK_WIDTH = MX_NUM_LANES * BITW;
localparam int unsigned CHUNK_BYTES = CHUNK_WIDTH / 8;
localparam int unsigned PACK_RATIO  = DATAW_ALIGN / CHUNK_WIDTH;
localparam int unsigned STRB_WIDTH  = DATAW_ALIGN / 8;
localparam int unsigned CHUNK_CNT_W = (PACK_RATIO > 1) ? $clog2(PACK_RATIO + 1) : 1;
localparam int unsigned CHUNK_IDX_W = (PACK_RATIO > 1) ? $clog2(PACK_RATIO) : 1;

initial begin
  if (DATAW_ALIGN % CHUNK_WIDTH != 0) begin
    $fatal(1, "MX beat unpack: DATAW_ALIGN (%0d) must be a multiple of chunk width (%0d)",
           DATAW_ALIGN, CHUNK_WIDTH);
  end
end

function automatic logic [CHUNK_CNT_W-1:0] count_chunks(input logic [STRB_WIDTH-1:0] strb);
  logic [CHUNK_CNT_W-1:0] cnt;
  cnt = '0;
  for (int c = 0; c < PACK_RATIO; c++) begin
    if (|strb[c*CHUNK_BYTES +: CHUNK_BYTES]) begin
      cnt = cnt + 1'b1;
    end
  end
  if (cnt == '0) begin
    cnt = CHUNK_CNT_W'(1);
  end
  return cnt;
endfunction

logic [DATAW_ALIGN-1:0] beat_q;
logic [STRB_WIDTH-1:0] strb_q;
logic [CHUNK_CNT_W-1:0] chunk_count_q;
logic [CHUNK_IDX_W-1:0] chunk_idx_q;
logic pending_q;

logic [DATAW_ALIGN-1:0] mx_out_data;
logic [STRB_WIDTH-1:0] mx_out_strb;
logic out_fire;
logic in_fire;
logic emit_last;
logic can_accept_new;

always_comb begin
  mx_out_data = '0;
  mx_out_strb = '0;
  if (pending_q) begin
    // Pass the full beat through; the upstream input_mux already packed all
    // PACK_RATIO chunks side-by-side into DATAW_ALIGN bits, and the downstream
    // x/w buffers (DW=DATAW_ALIGN) consume the whole beat in one load.
    mx_out_data = beat_q;
    mx_out_strb = strb_q;
  end
end

assign out_o.valid = mx_enable_i ? pending_q : in_i.valid;
assign out_o.data  = mx_enable_i ? mx_out_data : in_i.data;
assign out_o.strb  = mx_enable_i ? mx_out_strb : in_i.strb;

assign out_fire = mx_enable_i && out_o.valid && out_o.ready;
assign emit_last = pending_q && (chunk_idx_q == (chunk_count_q - 1'b1));
assign can_accept_new = !pending_q || (out_fire && emit_last);

assign in_i.ready = mx_enable_i ? can_accept_new : out_o.ready;
assign in_fire = mx_enable_i && in_i.valid && in_i.ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    beat_q <= '0;
    strb_q <= '0;
    chunk_count_q <= '0;
    chunk_idx_q <= '0;
    pending_q <= 1'b0;
  end else if (clear_i || !mx_enable_i) begin
    beat_q <= '0;
    strb_q <= '0;
    chunk_count_q <= '0;
    chunk_idx_q <= '0;
    pending_q <= 1'b0;
  end else begin
    if (pending_q) begin
      if (out_fire) begin
        if (emit_last) begin
          if (in_fire) begin
            beat_q <= in_i.data;
            strb_q <= in_i.strb;
            chunk_count_q <= CHUNK_CNT_W'(1);
            chunk_idx_q <= '0;
            pending_q <= 1'b1;
          end else begin
            pending_q <= 1'b0;
            chunk_count_q <= '0;
            chunk_idx_q <= '0;
          end
        end else begin
          chunk_idx_q <= chunk_idx_q + 1'b1;
        end
      end
    end else if (in_fire) begin
      beat_q <= in_i.data;
      strb_q <= in_i.strb;
      chunk_count_q <= CHUNK_CNT_W'(1);
      chunk_idx_q <= '0;
      pending_q <= 1'b1;
    end
  end
end

assign pending_o = mx_enable_i & pending_q;

endmodule : redmule_mx_beat_unpack
