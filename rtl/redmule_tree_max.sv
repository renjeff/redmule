module redmule_tree_max #(
  parameter int unsigned WIDTH = 5,
  parameter int unsigned N     = 8
)(
  input  logic [WIDTH-1:0] in [N],
  output logic [WIDTH-1:0] out
);

  generate
    if (N == 1) begin : gen_base
      assign out = in[0];
    end else if (N == 2) begin : gen_pair
      assign out = (in[0] > in[1]) ? in[0] : in[1];
    end else begin : gen_recurse
      localparam int unsigned HALF = N / 2;

      logic [WIDTH-1:0] left_in  [HALF];
      logic [WIDTH-1:0] right_in [N - HALF];
      logic [WIDTH-1:0] left_out, right_out;

      for (genvar i = 0; i < HALF; i++) begin : gen_left
        assign left_in[i] = in[i];
      end
      for (genvar i = 0; i < N - HALF; i++) begin : gen_right
        assign right_in[i] = in[HALF + i];
      end

      redmule_tree_max #(.WIDTH(WIDTH), .N(HALF)) i_left (
        .in  (left_in),
        .out (left_out)
      );

      redmule_tree_max #(.WIDTH(WIDTH), .N(N - HALF)) i_right (
        .in  (right_in),
        .out (right_out)
      );

      assign out = (left_out > right_out) ? left_out : right_out;
    end
  endgenerate

endmodule
