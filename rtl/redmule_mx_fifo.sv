module redmule_mx_fifo #(
  parameter int unsigned DATA_WIDTH = 256,
  parameter int unsigned FIFO_DEPTH = 8
)(
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    clear_i,
  
  input  logic                    push_i,
  output logic                    grant_o,
  input  logic [DATA_WIDTH-1:0]   data_i,
  
  input  logic                    pop_i,
  output logic                    valid_o,
  output logic [DATA_WIDTH-1:0]   data_o
);

  logic [FIFO_DEPTH-1:0][DATA_WIDTH-1:0] mem;
  logic [$clog2(FIFO_DEPTH):0] wr_ptr, rd_ptr;
  
  wire full  = (wr_ptr[$clog2(FIFO_DEPTH)] != rd_ptr[$clog2(FIFO_DEPTH)]) &&
               (wr_ptr[$clog2(FIFO_DEPTH)-1:0] == rd_ptr[$clog2(FIFO_DEPTH)-1:0]);
  wire empty = (wr_ptr == rd_ptr);
  
  assign grant_o = ~full;
  assign valid_o = ~empty;
  assign data_o  = mem[rd_ptr[$clog2(FIFO_DEPTH)-1:0]];
  
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else if (clear_i) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      if (push_i && grant_o) begin
        mem[wr_ptr[$clog2(FIFO_DEPTH)-1:0]] <= data_i;
        wr_ptr <= wr_ptr + 1;
      end
      if (pop_i && valid_o) begin
        rd_ptr <= rd_ptr + 1;
      end
    end
  end

endmodule