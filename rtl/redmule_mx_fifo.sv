module redmule_mx_fifo #(
  parameter int unsigned DATA_WIDTH = 192,  // Total bit width
  parameter int unsigned FIFO_DEPTH = 4,
  parameter int unsigned BITW = 16,
  localparam int unsigned NUM_LANES = DATA_WIDTH / BITW
)(
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    clear_i,
  
  input  logic                    push_i,
  output logic                    grant_o,
  input  logic [NUM_LANES-1:0][BITW-1:0] data_i,
  
  input  logic                    pop_i,
  output logic                    valid_o,
  output logic [NUM_LANES-1:0][BITW-1:0]   data_o
);
  
  // Internal storage - 2D array
  logic [NUM_LANES-1:0][BITW-1:0] fifo_mem [FIFO_DEPTH];
  // read/write pointers
  logic [$clog2(FIFO_DEPTH):0] wr_ptr, rd_ptr;
  
  // Full/empty logic
  wire full  = (wr_ptr[$clog2(FIFO_DEPTH)] != rd_ptr[$clog2(FIFO_DEPTH)]) &&
               (wr_ptr[$clog2(FIFO_DEPTH)-1:0] == rd_ptr[$clog2(FIFO_DEPTH)-1:0]);
  wire empty = (wr_ptr == rd_ptr);
  
  // grant push when not full, valid pop when not empty
  assign grant_o = ~full;
  assign valid_o = ~empty;

  // Output data
  assign data_o  = fifo_mem[rd_ptr[$clog2(FIFO_DEPTH)-1:0]];
  
  // sequential logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else if (clear_i) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      // push
      if (push_i && grant_o) begin
        fifo_mem[wr_ptr[$clog2(FIFO_DEPTH)-1:0]] <= data_i;
        wr_ptr <= wr_ptr + 1;
      end
      // pop
      if (pop_i && valid_o) begin
        rd_ptr <= rd_ptr + 1;
      end
    end
  end
  // Assertions for debug builds
  `ifndef SYNTHESIS
    // Check for overflow
    property no_overflow;
      @(posedge clk_i) disable iff (!rst_ni)
      push_i |-> grant_o;
    endproperty
    assert property (no_overflow) else 
      $error("[MX_FIFO] Push attempted when FIFO full!");
    
    // Check for underflow
    property no_underflow;
      @(posedge clk_i) disable iff (!rst_ni)
      pop_i |-> valid_o;
    endproperty
    assert property (no_underflow) else 
      $error("[MX_FIFO] Pop attempted when FIFO empty!");
  `endif

endmodule
