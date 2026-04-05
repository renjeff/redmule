// Y Bias Register Bank
// Shadow copy of Y bias data, separate from the Z buffer SCM.
// Y data persists even after z_avail fill overwrites the Z buffer,
// enabling y_push restart at M-tile boundaries.

module redmule_y_bias_reg
  import fpnew_pkg::*;
  import redmule_pkg::*;
#(
  parameter int unsigned           DW       = 288,
  parameter fpnew_pkg::fp_format_e FpFormat = fpnew_pkg::FP16,
  parameter int unsigned           Width    = ARRAY_WIDTH,
  localparam int unsigned          BITW     = fpnew_pkg::fp_width(FpFormat),
  localparam int unsigned          W        = Width,
  localparam int unsigned          D        = DW/BITW
)(
  input  logic                             clk_i,
  input  logic                             rst_ni,
  input  logic                             clear_i,

  // Write: column-by-column from Y stream
  input  logic                             write_en_i,
  input  logic [$clog2(W)-1:0]             write_addr_i,
  input  logic [DW-1:0]                    write_data_i,

  // Read: own counter driven by y_push_enable (ungated by y_reg_lock)
  input  logic                             read_en_i,       // y_push_en && ~stall_engine (full, ungated)
  input  logic [$clog2(D):0]               y_height_i,
  input  logic                             read_rst_i,      // Reset read counter (at y_push restart)

  output logic [W-1:0][BITW-1:0]           read_data_o
);

  logic [D-1:0][W-1:0][BITW-1:0] buffer_q;

  // Own read counter (independent of Z buffer's d_index)
  logic [$clog2(D)-1:0] d_index;
  logic                 rst_d;

  assign rst_d = (d_index == y_height_i[$clog2(D)-1:0] - 1) && read_en_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      d_index <= '0;
    else if (clear_i || read_rst_i)
      d_index <= '0;
    else if (rst_d)
      d_index <= '0;
    else if (read_en_i)
      d_index <= d_index + 1;
  end

  // Registered read address (matches Z buffer SCM timing)
  logic [$clog2(D)-1:0] d_index_read_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      d_index_read_q <= '0;
    else if (clear_i || read_rst_i)
      d_index_read_q <= '0;
    else if (read_en_i)
      d_index_read_q <= d_index;
  end

  // Read output
  for (genvar c = 0; c < W; c++) begin : gen_read_output
    assign read_data_o[c] = buffer_q[d_index_read_q][c];
  end

  // Write: column-by-column
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int r = 0; r < D; r++)
        for (int c = 0; c < W; c++)
          buffer_q[r][c] <= '0;
    end else if (clear_i) begin
      for (int r = 0; r < D; r++)
        for (int c = 0; c < W; c++)
          buffer_q[r][c] <= '0;
    end else if (write_en_i) begin
      for (int r = 0; r < D; r++)
        buffer_q[r][write_addr_i] <= write_data_i[r*BITW +: BITW];
    end
  end

endmodule : redmule_y_bias_reg
